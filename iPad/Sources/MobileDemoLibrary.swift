import AVFoundation
import Foundation
import UIKit

extension LibraryStore {
  func addDemoCollection() async {
    guard !importing, !albums.contains(where: { $0.isDemo }) else { return }
    let existing = Set(tracks.keys)
    let root = AppPaths.demo.appendingPathComponent(
      "iPad Demo-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      let specs: [(String, Double, UIColor)] = [
        ("Golden Hour", 220, .systemOrange), ("Blue Current", 261.63, .systemTeal),
        ("Night Transit", 174.61, .systemIndigo),
      ]
      for (name, frequency, color) in specs {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let art = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800)).image { context in
          color.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
          UIColor.black.withAlphaComponent(0.18).setFill()
          for index in 0..<10 {
            context.cgContext.fillEllipse(
              in: CGRect(x: index * 43 - 150, y: index * 35 + 200, width: 700, height: 700))
          }
          let paragraph = NSMutableParagraphStyle()
          paragraph.alignment = .left
          (name as NSString).draw(
            in: CGRect(x: 65, y: 70, width: 670, height: 260),
            withAttributes: [
              .font: UIFont.systemFont(ofSize: 86, weight: .bold), .foregroundColor: UIColor.white,
              .paragraphStyle: paragraph,
            ])
          ("COVER FLOW · DEMO" as NSString).draw(
            at: CGPoint(x: 65, y: 700),
            withAttributes: [
              .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .medium),
              .foregroundColor: UIColor.white,
            ])
        }
        try art.jpegData(compressionQuality: 0.92)!.write(
          to: folder.appendingPathComponent("cover.jpg"))
        try await Task.detached(priority: .utility) {
          let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
          let file = try AVAudioFile(
            forWriting: folder.appendingPathComponent("01 - \(name).wav"), settings: format.settings
          )
          for part in 0..<12 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            for index in 0..<44100 {
              let time = Double(part) + Double(index) / 44100
              let envelope = min(1, time / 0.25, (12 - time) / 0.4)
              let value = Float(
                (sin(2 * Double.pi * frequency * time) + 0.4
                  * sin(2 * Double.pi * frequency * 1.5 * time)) * 0.12 * max(0, envelope))
              buffer.floatChannelData![0][index] = value
              buffer.floatChannelData![1][index] = value * 0.94
            }
            try file.write(from: buffer)
          }
          try
            "[00:00.00]Welcome to Cover Flow\n[00:03.00]Browse your music by its covers\n[00:06.00]Tap a lyric line to seek\n[00:09.00]Your music stays on this iPad"
            .write(
              to: folder.appendingPathComponent("01 - \(name).lrc"), atomically: true,
              encoding: .utf8)
        }.value
      }
      await importURLs([root])
      markDemo(Set(tracks.keys).subtracting(existing))
    } catch { notice = error.localizedDescription }
  }
  private func markDemo(_ ids: Set<UUID>) {
    // Use the same editing methods as imported music, then mark these original
    // generated examples to keep them out of Last.fm listening history.
    flagDemo(ids)
  }
}
