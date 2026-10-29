import Foundation

/// Shared routes keep playback shortcuts and phone/tablet navigation in sync.
enum MobileTab: String, CaseIterable, Identifiable, Hashable {
  case library, queue, lyrics, karaoke, visualizer, settings, more
  static let sidebarTabs: [Self] = [.library, .queue, .lyrics, .karaoke, .visualizer, .settings]
  static let compactTabs: [Self] = [.library, .queue, .lyrics, .karaoke, .more]
  var id: String { rawValue }
  var isSecondaryDestination: Bool { self == .visualizer || self == .settings }
  var compactSelection: Self { isSecondaryDestination ? .more : self }
  var title: String {
    switch self {
    case .library: return "Collection"
    case .queue: return "Up Next"
    case .lyrics: return "Lyrics"
    case .karaoke: return "Karaoke"
    case .visualizer: return "Visualizer"
    case .settings: return "Settings"
    case .more: return "More"
    }
  }
  var icon: String {
    switch self {
    case .library: return "square.stack.fill"
    case .queue: return "text.line.first.and.arrowtriangle.forward"
    case .lyrics: return "quote.bubble"
    case .karaoke: return "mic.fill"
    case .visualizer: return "waveform"
    case .settings: return "gearshape"
    case .more: return "ellipsis.circle"
    }
  }
}

/// A short landscape viewport scrolls vertically instead of clipping the covers
/// or their captions. Portrait phones use larger, easy-to-swipe artwork.
struct MobileCoverLayout {
  let coverSide: Double
  let stageHeight: Double
  init(width: Double, height: Double) {
    let w = width.isFinite && width > 0 ? width : 320
    let h = height.isFinite && height > 0 ? height : 300
    coverSide = max(80, min(340, w * 0.72, max(80, h - 150)))
    stageHeight = max(h, coverSide + 142)
  }
  static func snapOffset(predicted: Double, step: Double, count: Int) -> Double {
    guard predicted.isFinite, step.isFinite, step > 0, count > 1 else { return 0 }
    let index = min(Double(count - 1), max(0, (predicted / step).rounded()))
    return index * step
  }

}
