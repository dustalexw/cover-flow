#if canImport(CFFmpegAudio)
import CFFmpegAudio
import Foundation

/// Audio that macOS can't decode, read through the bundled decoder-only FFmpeg build
/// (`scripts/build-ffmpeg.sh`). Output is deinterleaved Float32 at the file's own rate,
/// with surround downmixed to stereo.
final class FFmpegAudioFile {
    /// Ogg Vorbis, Speex, FLAC in Ogg, Monkey's Audio, WavPack, Windows Media Audio, DSD,
    /// Matroska/WebM audio, Musepack, TTA, TAK, Shorten, DTS and Wave64.
    static let extensions: Set<String> = [
        "ogg", "oga", "spx", "ape", "wv", "wma", "asf", "dsf", "dff", "mka", "webm", "weba",
        "mpc", "mpp", "mp+", "tta", "tak", "shn", "dts", "w64"
    ]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let cancellation: PlaybackCancellation?
    private let handle: OpaquePointer
    let channels: Int
    let sampleRate: Double
    /// Frames, from the container; decoding may end slightly sooner.
    let length: Int64
    let scannedDuration: Bool

    init(url: URL, cancellation: PlaybackCancellation? = nil, readMetadata: Bool = true,
         durationCache: FFmpegDurationCache = .shared) throws {
        self.cancellation = cancellation
        try cancellation?.check()
        var message = [CChar](repeating: 0, count: 512)
        let revision = FFmpegDurationCache.Revision.read(url)
        let cached = durationCache.value(for: revision)
        func open(_ info: FFmpegDurationCache.Info?) -> OpaquePointer? {
            withExtendedLifetime(cancellation) {
                cf_audio_open_cached(url.path, info?.frames ?? -1, info?.rate ?? 0, readMetadata, { context in
                    guard let context else { return false }
                    return Unmanaged<PlaybackCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled
                }, cancellation.map { Unmanaged.passUnretained($0).toOpaque() }, &message, message.count)
            }
        }
        var opened = open(cached)
        // A file replaced during probing must not use a cached length.
        if cached != nil, let candidate = opened, FFmpegDurationCache.Revision.read(url) != revision {
            cf_audio_close(candidate); opened = open(nil)
        }
        guard let handle = opened else {
            try cancellation?.check()
            throw Failure(message: String(cString: message))
        }
        self.handle = handle
        channels = Int(cf_audio_channels(handle))
        sampleRate = cf_audio_sample_rate(handle)
        length = cf_audio_length(handle)
        scannedDuration = cf_audio_scanned_duration(handle)
        if FFmpegDurationCache.Revision.read(url) == revision {
            durationCache.insert(.init(frames: length, rate: Int32(sampleRate)), for: revision)
        }
    }

    deinit { cf_audio_close(handle) }

    var duration: Double { sampleRate > 0 ? Double(max(0, length)) / sampleRate : 0 }

    /// Fills up to `frames` frames of each channel; fewer only at the end of the stream.
    func read(into data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) throws -> Int {
        var message = [CChar](repeating: 0, count: 512)
        let channels = UnsafeRawPointer(data).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
        let count = cf_audio_read(handle, channels, frames, &message, message.count)
        try cancellation?.check()
        guard count >= 0 else { throw Failure(message: String(cString: message)) }
        return count
    }

    func seek(to frame: Int64) throws {
        var message = [CChar](repeating: 0, count: 512)
        let succeeded = cf_audio_seek(handle, frame, &message, message.count)
        try cancellation?.check()
        guard succeeded else {
            throw Failure(message: String(cString: message))
        }
    }

    /// The first non-empty value among `keys`; keys match case-insensitively.
    func tag(_ keys: String...) -> String? {
        for key in keys {
            if let value = cf_audio_tag(handle, key).map({ String(cString: $0) })?.nonEmpty { return value }
        }
        return nil
    }

    var picture: Data? {
        var size = 0
        guard let bytes = cf_audio_picture(handle, &size), size > 0 else { return nil }
        return Data(bytes: bytes, count: size)
    }
}
#endif
