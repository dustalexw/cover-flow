import AppKit
import SwiftUI

/// Keeps compact players one line tall while revealing the entire title.
struct ScrollingTrackTitle: View {
    let title: String
    var alignment: Alignment = .leading

    init(_ title: String, alignment: Alignment = .leading) {
        self.title = title; self.alignment = alignment
    }

    var body: some View {
        let line = title.components(separatedBy: .newlines).joined(separator: " ")
        ZStack {
            Text(line).lineLimit(1).hidden()
                .frame(maxWidth: .infinity, alignment: alignment)
        }
            .overlay {
                GeometryReader { viewport in
                    ScrollingTitleLine(title: line, size: viewport.size, alignment: alignment)
                        .id(TitleViewport(title: line, width: viewport.size.width))
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .help(title)
    }
}

private struct TitleViewport: Hashable {
    let title: String
    let width: CGFloat
}

private struct ScrollingTitleLine: View {
    let title: String
    let size: CGSize
    let alignment: Alignment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @State private var textWidth: CGFloat = 0
    @State private var started = Date()

    private var distance: CGFloat { max(0, textWidth - size.width) }

    var body: some View {
        Group {
            if reduceMotion {
                Text(title).lineLimit(1).frame(width: size.width, height: size.height, alignment: alignment)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: distance <= 1)) { context in
                    let offset = TrackTitleScroll.offset(distance: distance, elapsed: context.date.timeIntervalSince(started))
                    Text(title).lineLimit(1).fixedSize()
                        .background {
                            GeometryReader { text in
                                Color.clear.preference(key: TitleWidthKey.self, value: text.size.width)
                            }
                        }
                        .offset(x: direction == .rightToLeft ? offset : -offset)
                        .frame(width: size.width, height: size.height, alignment: distance > 1 ? .leading : alignment)
                        .clipped()
                }
            }
        }
        .onPreferenceChange(TitleWidthKey.self) { width in
            if textWidth != width { textWidth = width; started = Date() }
        }
    }
}

private struct TitleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum TrackTitleScroll {
    static let speed: Double = 28
    static let pause: Double = 2

    /// Pause at both ends and travel at a readable, constant speed in either direction.
    static func offset(distance: CGFloat, elapsed: TimeInterval) -> CGFloat {
        guard distance.isFinite, distance > 1, elapsed.isFinite else { return 0 }
        let travel = Double(distance) / speed
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 2 * (travel + pause))
        if phase < pause { return 0 }
        if phase < pause + travel { return CGFloat((phase - pause) * speed) }
        if phase < 2 * pause + travel { return distance }
        return max(0, distance - CGFloat((phase - 2 * pause - travel) * speed))
    }
}

enum TrackTitleLayout {
    static func needsWideColumn(_ title: String) -> Bool {
        // A two-column album panel leaves 221 points for each title after the
        // track number, duration and spacing. Long names get the full list width.
        let font = NSFont(name: "Helvetica Neue", size: 13) ?? .systemFont(ofSize: 13)
        return title.rangeOfCharacter(from: .newlines) != nil
            || (title as NSString).size(withAttributes: [.font: font]).width > 221
    }
}
