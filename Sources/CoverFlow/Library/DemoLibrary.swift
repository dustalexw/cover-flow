import AppKit
import Foundation

/// Generates a small, clearly labelled demonstration collection: original synthesized music
/// and procedurally drawn covers, created on this Mac so there are no licensing questions.
enum DemoLibrary {
    struct GeneratedAlbum {
        var album: Album
        var tracks: [Track]
    }

    enum Style { case horizon, cityGrid, grooves, stripes, glass }

    struct Spec {
        let title: String
        let artist: String
        let year: Int
        let style: Style
        let colors: [(Double, Double, Double)]
        let root: Double          // root frequency (Hz)
        let tempo: Double         // beats per minute
        let progression: [[Int]]  // chords as semitone offsets from root
        let tracks: [String]
    }

    static let specs: [Spec] = [
        Spec(title: "Low Tide Hours", artist: "Halcyon Tapes", year: 2019, style: .horizon,
             colors: [(0.98, 0.62, 0.38), (0.80, 0.30, 0.38), (0.20, 0.12, 0.28)],
             root: 220, tempo: 84, progression: [[0, 4, 7, 11], [9, 12, 16, 19], [5, 9, 12, 16], [7, 11, 14, 17]],
             tracks: ["Salt Air", "Harbour Lights", "The Long Shallows"]),
        Spec(title: "Paper Cities", artist: "Marlow & The Quiet Rooms", year: 2021, style: .cityGrid,
             colors: [(0.86, 0.88, 0.90), (0.36, 0.48, 0.62), (0.13, 0.17, 0.24)],
             root: 196, tempo: 96, progression: [[0, 3, 7, 10], [5, 8, 12, 15], [10, 14, 17, 21], [3, 7, 10, 14]],
             tracks: ["Blueprint", "Elevator Song", "Rooftops at Six"]),
        Spec(title: "Night Orchard", artist: "Orchard Line", year: 2016, style: .grooves,
             colors: [(0.10, 0.20, 0.16), (0.82, 0.66, 0.34), (0.05, 0.08, 0.07)],
             root: 174.6, tempo: 72, progression: [[0, 7, 12, 16], [5, 12, 16, 21], [-3, 4, 9, 12], [7, 11, 14, 19]],
             tracks: ["Lanterns", "Under the Pear Trees", "Moth Waltz"]),
        Spec(title: "Signal & Noise", artist: "Tessellate", year: 2023, style: .stripes,
             colors: [(0.96, 0.45, 0.16), (0.10, 0.10, 0.11), (0.95, 0.92, 0.86)],
             root: 233, tempo: 112, progression: [[0, 3, 7], [8, 12, 15], [3, 7, 10], [10, 14, 17]],
             tracks: ["Carrier Wave", "Static Bloom", "Hand Signals"]),
        Spec(title: "Glass Garden", artist: "Vera Lune", year: 2020, style: .glass,
             colors: [(0.93, 0.80, 0.86), (0.62, 0.78, 0.86), (0.78, 0.88, 0.72)],
             root: 261.6, tempo: 90, progression: [[0, 4, 7, 14], [-3, 4, 9, 12], [5, 9, 12, 16], [7, 11, 14, 17]],
             tracks: ["Conservatory", "Fern Light", "Rain on the Roof"])
    ]

    static func generate(into dir: URL, artwork: ArtworkStore) throws -> [GeneratedAlbum] {
        var out: [GeneratedAlbum] = []
        let now = Date()
        for (ai, spec) in specs.enumerated() {
            let albumID = UUID()
            var tracks: [Track] = []
            let folder = dir.appendingPathComponent(spec.title, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (ti, name) in spec.tracks.enumerated() {
                let url = folder.appendingPathComponent(String(format: "%02d %@.wav", ti + 1, name))
                let seconds = 26.0 + Double((ai * 3 + ti) % 4) * 3
                let samples = synthesize(spec: spec, variation: ti, seconds: seconds)
                try writeWAV(samples: samples, sampleRate: sampleRate, to: url)
                let track = Track(
                    id: UUID(), fileURL: url, title: name, artist: spec.artist, albumTitle: spec.title,
                    albumArtist: spec.artist, trackNumber: ti + 1, discNumber: 1, duration: seconds,
                    year: spec.year, genre: "Demo", dateAdded: now.addingTimeInterval(Double(-ai * 86_400)),
                    isDemo: true, missingMetadata: false,
                    fingerprint: "demo|\(spec.title)|\(name)")
                tracks.append(track)
            }
            var album = Album(
                id: albumID, groupKey: "demo:" + spec.title.normalizedKey, title: spec.title, artist: spec.artist,
                year: spec.year, genre: "Demo", trackIDs: tracks.map(\.id), artworkFile: nil,
                artworkPixelWidth: nil, artworkPixelHeight: nil, artworkVersion: 1, tintHex: nil,
                dateAdded: now.addingTimeInterval(Double(-ai * 86_400)), lastPlayed: nil, isDemo: true,
                missingMetadata: false, userEdited: false)
            if let png = drawCover(spec), let saved = try? artwork.save(data: png, albumID: albumID) {
                album.artworkFile = saved.file
                album.artworkPixelWidth = saved.pixelWidth
                album.artworkPixelHeight = saved.pixelHeight
                album.tintHex = saved.tintHex
            }
            out.append(GeneratedAlbum(album: album, tracks: tracks))
        }
        return out
    }

    // MARK: Synthesis

    static let sampleRate = 22_050.0

    private static func synthesize(spec: Spec, variation: Int, seconds: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        let beat = 60.0 / spec.tempo
        let barLength = beat * 4
        let prog = spec.progression
        let shift = variation % prog.count
        let octaveLift = variation == 2 ? 2.0 : 1.0
        func freq(_ semis: Int) -> Double { spec.root * pow(2, Double(semis) / 12) }

        // Pad: soft chords with slow attack.
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let bar = Int(t / barLength)
            let chord = prog[(bar + shift) % prog.count]
            let inBar = t - Double(bar) * barLength
            let env = min(1, inBar / 0.6) * (0.75 + 0.25 * cos(.pi * inBar / barLength))
            var v = 0.0
            for (k, s) in chord.enumerated() {
                let f = freq(s - 12)
                v += sin(2 * .pi * f * t + Double(k)) * 0.5 + sin(2 * .pi * f * 2.003 * t) * 0.12
            }
            out[i] = Float(v * env * 0.06)
        }

        // Arpeggio: plucked notes on eighths.
        let step = beat / 2
        var noteIndex = 0
        var start = 0.0
        while start < seconds - 0.05 {
            let bar = Int(start / barLength)
            let chord = prog[(bar + shift) % prog.count]
            let pattern = [0, 2, 1, 3, 2, 1, 3, 2]
            let s = chord[pattern[noteIndex % pattern.count] % chord.count]
            let f = freq(s) * octaveLift
            let first = Int(start * sampleRate)
            let length = Int(min(1.4, seconds - start) * sampleRate)
            let accent = noteIndex % 4 == 0 ? 1.0 : 0.7
            for j in 0..<length where first + j < n {
                let tt = Double(j) / sampleRate
                let env = exp(-tt * 4.2) * min(1, tt / 0.004)
                let v = (sin(2 * .pi * f * tt) + 0.3 * sin(4 * .pi * f * tt) + 0.1 * sin(6 * .pi * f * tt)) * env
                out[first + j] += Float(v * 0.11 * accent)
            }
            noteIndex += 1
            start += step
        }

        // Soft kick on beats 1 and 3 for a gentle pulse.
        var k = 0.0
        while k < seconds {
            let first = Int(k * sampleRate)
            for j in 0..<Int(0.25 * sampleRate) where first + j < n {
                let tt = Double(j) / sampleRate
                let f = 55 + 70 * exp(-tt * 30)
                out[first + j] += Float(sin(2 * .pi * f * tt) * exp(-tt * 12) * 0.16)
            }
            k += beat * 2
        }

        // Fade in/out and normalise.
        let fade = Int(1.5 * sampleRate)
        for i in 0..<min(fade, n) {
            let g = Float(i) / Float(fade)
            out[i] *= g
            out[n - 1 - i] *= g
        }
        let peak = out.reduce(0) { max($0, abs($1)) }
        if peak > 0 {
            let gain = 0.85 / peak
            for i in 0..<n { out[i] *= gain }
        }
        return out
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let rate = UInt32(sampleRate)
        let byteCount = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!)
        u32(36 + byteCount)
        data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append("data".data(using: .ascii)!)
        u32(byteCount)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count { pcm[i] = Int16((samples[i].clamped(-1, 1) * 32_000).rounded()) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Cover art

    private static func drawCover(_ spec: Spec) -> Data? {
        let px = 1400
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let s = CGFloat(px)
        let rect = NSRect(x: 0, y: 0, width: s, height: s)
        let c = spec.colors.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        var textColor = NSColor.white

        switch spec.style {
        case .horizon:
            NSGradient(colors: [c[2], c[1], c[0]])?.draw(in: rect, angle: 90)
            let sun = NSRect(x: s * 0.28, y: s * 0.36, width: s * 0.44, height: s * 0.44)
            NSGradient(colors: [NSColor(srgbRed: 1, green: 0.88, blue: 0.62, alpha: 1), c[0]])?.draw(in: NSBezierPath(ovalIn: sun), angle: 90)
            c[2].withAlphaComponent(0.92).setFill()
            NSRect(x: 0, y: 0, width: s, height: s * 0.42).fill()
            for i in 0..<9 {
                let y = s * 0.40 - CGFloat(i) * s * 0.035
                NSColor(srgbRed: 1, green: 0.78, blue: 0.55, alpha: 0.35 - CGFloat(i) * 0.035).setFill()
                let w = s * (0.36 - CGFloat(i) * 0.03)
                NSBezierPath(roundedRect: NSRect(x: s / 2 - w / 2, y: y, width: w, height: s * 0.008), xRadius: 4, yRadius: 4).fill()
            }
        case .cityGrid:
            c[2].setFill(); rect.fill()
            var seed: UInt64 = 7
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
            for col in 0..<11 {
                let w = s / 11
                let h = s * (0.25 + rnd() * 0.5)
                let x = CGFloat(col) * w
                c[1].withAlphaComponent(0.55 + rnd() * 0.4).setFill()
                NSRect(x: x + 3, y: s * 0.12, width: w - 6, height: h).fill()
                for r in 0..<Int(h / 34) {
                    for k in 0..<3 where rnd() > 0.55 {
                        c[0].withAlphaComponent(0.7).setFill()
                        NSRect(x: x + 12 + CGFloat(k) * (w - 24) / 3, y: s * 0.12 + 18 + CGFloat(r) * 34, width: 10, height: 14).fill()
                    }
                }
            }
            c[0].setFill()
            NSRect(x: 0, y: s * 0.12 - 4, width: s, height: 4).fill()
        case .grooves:
            c[2].setFill(); rect.fill()
            let center = NSPoint(x: s / 2, y: s / 2 + s * 0.04)
            for i in 0..<34 {
                let r = s * 0.44 - CGFloat(i) * s * 0.0105
                let path = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                (i % 2 == 0 ? c[0] : c[0].blended(withFraction: 0.25, of: .black) ?? c[0]).setFill()
                path.fill()
            }
            let label = s * 0.13
            c[1].setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - label, y: center.y - label, width: label * 2, height: label * 2)).fill()
            c[2].setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)).fill()
            textColor = c[1]
        case .stripes:
            c[2].setFill(); rect.fill()
            let ctx = gc.cgContext
            ctx.saveGState()
            ctx.translateBy(x: s / 2, y: s / 2)
            ctx.rotate(by: -.pi / 4)
            for i in -12...12 {
                (i % 3 == 0 ? c[0] : c[1]).setFill()
                NSRect(x: CGFloat(i) * s * 0.075, y: -s, width: s * 0.034, height: s * 2).fill()
            }
            ctx.restoreGState()
            c[1].setFill()
            NSRect(x: 0, y: 0, width: s, height: s * 0.2).fill()
        case .glass:
            NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill(); rect.fill()
            let circles: [(CGFloat, CGFloat, CGFloat, Int)] = [(0.32, 0.6, 0.30, 0), (0.62, 0.62, 0.26, 1), (0.48, 0.38, 0.28, 2), (0.72, 0.36, 0.16, 0), (0.24, 0.32, 0.12, 1)]
            for (x, y, r, ci) in circles {
                c[ci].withAlphaComponent(0.62).setFill()
                NSBezierPath(ovalIn: NSRect(x: s * (x - r), y: s * (y - r), width: s * r * 2, height: s * r * 2)).fill()
            }
            textColor = NSColor(srgbRed: 0.22, green: 0.2, blue: 0.24, alpha: 1)
        }

        let para = NSMutableParagraphStyle()
        para.alignment = .left
        let titleFont = NSFont(name: "Didot", size: s * 0.072) ?? NSFont.systemFont(ofSize: s * 0.07, weight: .semibold)
        let title = NSAttributedString(string: spec.title, attributes: [.font: titleFont, .foregroundColor: textColor, .paragraphStyle: para])
        title.draw(in: NSRect(x: s * 0.07, y: s * 0.05, width: s * 0.86, height: s * 0.1))
        let artistAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: s * 0.026, weight: .medium),
            .foregroundColor: textColor.withAlphaComponent(0.85),
            .kern: s * 0.004
        ]
        NSAttributedString(string: spec.artist.uppercased(), attributes: artistAttrs).draw(at: NSPoint(x: s * 0.072, y: s * 0.145))
        let demoAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: s * 0.018, weight: .bold),
            .foregroundColor: textColor.withAlphaComponent(0.7),
            .kern: s * 0.004
        ]
        NSAttributedString(string: "DEMO", attributes: demoAttrs).draw(at: NSPoint(x: s * 0.86, y: s * 0.94))

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
