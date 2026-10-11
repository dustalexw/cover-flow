import Foundation

struct AlbumSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    private(set) var anchor: UUID?

    mutating func select(_ id: UUID, ordered: [UUID], extend: Bool = false, toggle: Bool = false) {
        guard let end = ordered.firstIndex(of: id) else { return }
        if extend, let anchor, let start = ordered.firstIndex(of: anchor) {
            let range = Set(ordered[min(start, end)...max(start, end)])
            ids = toggle ? ids.union(range) : range
        } else if toggle {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }

    mutating func marquee(intersecting hits: Set<UUID>, addingTo base: Set<UUID>) { ids = base.union(hits) }
    mutating func finishMarquee(ordered: [UUID]) { anchor = ordered.first { ids.contains($0) } }
    mutating func selectAll(_ ordered: [UUID]) { ids = Set(ordered); anchor = ordered.first }
    mutating func clear() { ids = []; anchor = nil }
    mutating func retainVisible(_ ordered: [UUID]) {
        ids.formIntersection(ordered)
        if let anchor, !ordered.contains(anchor) { self.anchor = nil }
    }
}
