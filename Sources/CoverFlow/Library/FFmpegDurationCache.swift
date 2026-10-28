#if canImport(CFFmpegAudio)
import Darwin
import Foundation

/// Session-only, bounded probe reuse. Never trust a track's display duration as
/// a decode limit: only results measured for the same file revision are reused.
final class FFmpegDurationCache: @unchecked Sendable {
    static let shared = FFmpegDurationCache()
    struct Revision: Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        static func read(_ url: URL) -> Revision? {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return fstatat(AT_FDCWD, path, &info, 0)
            }
            guard result == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return Revision(path: url.standardizedFileURL.path, device: info.st_dev,
                inode: info.st_ino, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
        }
    }
    struct Info { let frames: Int64; let rate: Int32 }
    private let lock = NSLock()
    private let capacity: Int
    private var values: [Revision: Info] = [:]
    private var recent: [Revision] = []
    init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    func value(for revision: Revision?) -> Info? {
        guard let revision else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let info = values[revision] else { return nil }
        recent.removeAll { $0 == revision }; recent.append(revision)
        return info
    }

    func insert(_ info: Info, for revision: Revision?) {
        guard let revision, info.frames > 0, info.rate > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for old in recent where old.path == revision.path { values.removeValue(forKey: old) }
        recent.removeAll { $0.path == revision.path }
        values[revision] = info; recent.append(revision)
        while recent.count > capacity { values.removeValue(forKey: recent.removeFirst()) }
    }
}
#endif
