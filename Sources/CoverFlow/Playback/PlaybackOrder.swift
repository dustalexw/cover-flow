import Foundation

enum PlaybackOrder {
    static func successor(after index: Int, count: Int, repeatMode: RepeatMode, automatic: Bool = true) -> Int? {
        guard index >= 0, index < count else { return nil }
        if automatic && repeatMode == .one { return index }
        if index + 1 < count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }
}
