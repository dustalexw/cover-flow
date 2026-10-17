import AVKit
import SwiftUI
import UIKit

extension String {
  var nonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
  var normalizedKey: String {
    folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).filter
    { !$0.isEmpty }.joined(separator: " ")
  }
  var stableHash: UInt64 { utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) } }
}
extension Comparable {
  func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}
extension Collection {
  subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
func formatTime(_ seconds: Double) -> String {
  guard seconds.isFinite, seconds >= 0 else { return "0:00" }
  let count = Int(seconds)
  return count >= 3600
    ? String(format: "%d:%02d:%02d", count / 3600, count / 60 % 60, count % 60)
    : String(format: "%d:%02d", count / 60, count % 60)
}
func formatLongDuration(_ seconds: Double) -> String {
  let minutes = Int(max(0, seconds) / 60)
  return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
}
enum Announcer {
  static func announce(_ text: String) {
    UIAccessibility.post(notification: .announcement, argument: text)
  }
}
extension Color {
  init(hex: String?, fallback: Color = .accentColor) {
    guard let hex, let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else {
      self = fallback
      return
    }
    self.init(
      red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255)
  }
}
enum MobilePalette {
  static let navy = Color(red: 0.045, green: 0.065, blue: 0.11)
  static let brass = Color(red: 0.79, green: 0.64, blue: 0.36)
  static let cream = Color(red: 0.96, green: 0.94, blue: 0.89)
}
struct RoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.tintColor = .label
    view.activeTintColor = .systemOrange
    return view
  }
  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
