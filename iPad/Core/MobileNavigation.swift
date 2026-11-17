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
    // Wide displays (iPhone Duo's inner display, iPad) get large covers that fill the stage.
    let wide = w >= 600
    coverSide = max(80, min(wide ? 560 : 340, w * (wide ? 0.5 : 0.72), max(80, h - 150)))
    stageHeight = max(h, coverSide + 142)
  }
  static func snapOffset(predicted: Double, step: Double, count: Int) -> Double {
    guard predicted.isFinite, step.isFinite, step > 0, count > 1 else { return 0 }
    let index = min(Double(count - 1), max(0, (predicted / step).rounded()))
    return index * step
  }

}

/// Which shell the app shows. Size classes, never device idiom or interface
/// orientation: iPhone Duo's outer display is compact like other iPhones, while
/// its inner display reports regular width and height in every pose.
enum MobileLayoutClass: Equatable {
  case compact, expanded
  init(regularWidth: Bool, regularHeight: Bool = true) {
    self = regularWidth && regularHeight ? .expanded : .compact
  }
}

/// How a foldable display is posed, derived from its division (fold) region.
/// A division only exists while the device is partially folded.
enum FoldPosture: String, Equatable {
  /// Fully open, folded shut, or a device without a hinge.
  case flat
  /// Partially open with a vertical fold: two pages side by side.
  case book
  /// Partially open with a horizontal fold: viewing half above, controls below.
  case tabletop
}

/// Fold geometry in the coordinate space of the view that queried it.
struct FoldGeometry: Equatable {
  var size: CGSizeValue
  /// The fold's frame, or nil when no active division crosses this view.
  var division: RectValue?
  /// Hinge angle in degrees while partially open, when the system reports it.
  var hingeDegrees: Double?

  struct CGSizeValue: Equatable { var width: Double; var height: Double }
  struct RectValue: Equatable {
    var x: Double, y: Double, width: Double, height: Double
    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
  }

  static let flat = FoldGeometry(size: .init(width: 0, height: 0), division: nil, hingeDegrees: nil)

  init(size: CGSizeValue, division: RectValue?, hingeDegrees: Double? = nil) {
    self.size = size
    self.hingeDegrees = hingeDegrees?.isFinite == true ? hingeDegrees : nil
    // Ignore regions that don't actually cross this view, such as a fold
    // reported in a sidebar's coordinate space while we lay out the detail.
    if let d = division, d.x.isFinite, d.y.isFinite, d.width.isFinite, d.height.isFinite,
      d.maxX > 0, d.minX < size.width, d.maxY > 0, d.minY < size.height,
      max(d.width, d.height) > 0
    {
      self.division = d
    } else {
      self.division = nil
    }
  }

  var posture: FoldPosture {
    guard let division else { return .flat }
    // A fold spanning the height divides left and right pages (book); one
    // spanning the width divides top and bottom (tabletop).
    let vertical = division.height >= division.width
    if vertical {
      return division.height >= size.height * 0.5 ? .book : .flat
    }
    return division.width >= size.width * 0.5 ? .tabletop : .flat
  }

  /// Width of the leading pane in a two-pane layout. In book posture the pane
  /// boundary sits on the fold so no cover or control straddles it; otherwise
  /// the panes share the width by `ratio`.
  func leadingPaneWidth(ratio: Double = 0.55, minimumPane: Double = 240) -> Double {
    let width = max(0, size.width.isFinite ? size.width : 0)
    if posture == .book, let division, division.minX >= minimumPane,
      width - division.maxX >= minimumPane
    {
      return division.minX
    }
    let r = ratio.isFinite ? min(0.8, max(0.2, ratio)) : 0.55
    return (width * r).rounded()
  }
  /// The gap to leave between the two panes: the fold's width in book posture.
  var paneGap: Double {
    guard posture == .book, let division else { return 0 }
    let width = size.width.isFinite ? size.width : 0
    return division.minX >= 240 && width - division.maxX >= 240 ? division.width : 0
  }
  /// Height of the upper (viewing) half in tabletop posture, or nil otherwise.
  var tabletopUpperHeight: Double? {
    guard posture == .tabletop, let division, division.minY > 120 else { return nil }
    return division.minY
  }
  /// Whether the detail area is wide enough, or posed, for album tracks beside
  /// the browser instead of in a sheet.
  var prefersTwoPanes: Bool { posture == .book || size.width >= 640 }

  /// Grid columns that avoid a column straddling the fold: even counts in book posture.
  func gridColumns(minimumWidth: Double = 150) -> Int {
    let width = size.width.isFinite ? max(0, size.width) : 0
    let fit = max(1, Int(width / max(1, minimumWidth)))
    guard posture == .book else { return fit }
    return max(2, fit - fit % 2)
  }
}
