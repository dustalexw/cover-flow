import SwiftUI

// iPhone Duo support.
//
// Layout follows size classes (see `MobileLayoutClass`). On top of that, views that
// lay content out edge to edge read the display's fold through `FoldReader`, so that
// covers and controls sit beside the fold (book posture) or above and below it
// (tabletop posture) instead of straddling it.
//
// The fold APIs (`GeometryProxy.reservedRegions(kind:)` and `onHingeChange`) exist only
// in the iOS 27.1 SDK and later. The project generator defines COVERFLOW_DUO_SDK for
// those SDKs; with older SDKs every view is treated as flat, which is also exactly what
// the iPhone Duo reports when fully open or closed.

extension FoldGeometry {
  @MainActor init(_ proxy: GeometryProxy, hingeDegrees: Double? = nil) {
    var division: RectValue?
    #if COVERFLOW_DUO_SDK
      // Active regions only: the division is active while partially folded and
      // inactive (zero width) when the display is flat.
      if #available(iOS 27.1, *),
        let region = proxy.reservedRegions(kind: .division).first(where: { $0.isActive })
      {
        let frame = region.frame
        division = RectValue(
          x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width),
          height: Double(frame.height))
      }
    #endif
    self.init(
      size: CGSizeValue(width: Double(proxy.size.width), height: Double(proxy.size.height)),
      division: division, hingeDegrees: hingeDegrees)
  }
}

private struct HingeDegreesKey: EnvironmentKey {
  static let defaultValue: Double? = nil
}
extension EnvironmentValues {
  /// The hinge angle while partially open. Used only for effects, never for layout.
  var hingeDegrees: Double? {
    get { self[HingeDegreesKey.self] }
    set { self[HingeDegreesKey.self] = newValue }
  }
}

/// Reads the fold in this view's own coordinate space.
struct FoldReader<Content: View>: View {
  @ViewBuilder var content: (FoldGeometry) -> Content
  @Environment(\.hingeDegrees) private var hinge
  var body: some View {
    GeometryReader { proxy in
      content(FoldGeometry(proxy, hingeDegrees: hinge))
    }
  }
}

/// Publishes the hinge angle to the view hierarchy on devices with a hinge.
struct HingeObserver: ViewModifier {
  @State private var degrees: Double?
  func body(content: Content) -> some View {
    #if COVERFLOW_DUO_SDK
      if #available(iOS 27.1, *) {
        content
          .environment(\.hingeDegrees, degrees)
          .onHingeChange { _, context in
            if let hinge = context.hinge, hinge.status == .partiallyOpen {
              degrees = hinge.angle.degrees
            } else {
              degrees = nil
            }
          }
      } else {
        content.environment(\.hingeDegrees, degrees)
      }
    #else
      content.environment(\.hingeDegrees, degrees)
    #endif
  }
}

extension View {
  func observesHinge() -> some View { modifier(HingeObserver()) }
}

/// Two panes that meet at the fold in book posture and share the width otherwise.
struct FoldSplit<Leading: View, Trailing: View>: View {
  var ratio = 0.55
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing
  var body: some View {
    FoldReader { fold in
      let width = CGFloat(fold.leadingPaneWidth(ratio: ratio))
      let gap = CGFloat(fold.paneGap)
      HStack(spacing: 0) {
        leading.frame(width: width)
        if gap > 0 {
          Color.clear.frame(width: gap).accessibilityHidden(true)
        } else {
          Divider()
        }
        trailing.frame(maxWidth: .infinity)
      }
    }
  }
}

private struct FoldGeometryKey: EnvironmentKey {
  static let defaultValue = FoldGeometry.flat
}
extension EnvironmentValues {
  /// The window-level fold, published by the expanded shell.
  var foldGeometry: FoldGeometry {
    get { self[FoldGeometryKey.self] }
    set { self[FoldGeometryKey.self] = newValue }
  }
}
