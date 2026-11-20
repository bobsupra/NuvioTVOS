import SwiftUI

/// A card kept as it was while what it shows (its key) stays the same, so its screen can redraw
/// (focus moving, a lock switching) without rebuilding it. The card still follows its own
/// state, focus and settings; closures it was given are those of when it was last built, so
/// they must read current state when they run.
struct CardSnapshot<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    let content: Content

    var body: some View { content }

    static func == (lhs: CardSnapshot, rhs: CardSnapshot) -> Bool {
        lhs.key == rhs.key
    }
}

extension View {
    func cardSnapshot<Key: Equatable>(_ key: Key) -> some View {
        CardSnapshot(key: key, content: self).equatable()
    }
}

/// What a grid card shows and where: the title, its place, the grid's column count and mode,
/// and whether it keeps its focused look while focus is put back on it.
struct GridCardSnapshotKey: Equatable {
    let meta: NuvioMeta
    let index: Int
    let columns: Int
    let mode: Int
    let retainsFocusAppearance: Bool
    var width: CGFloat = 0
}

/// Titles without the unreleased ones, worked out once per list: filtered in a computed
/// property, every title's release date was checked several times on every redraw, which
/// Search and Discover do on every focus move.
final class ReleasedTitlesMemo {
    private var revision = -1
    private var hidesUnreleased = false
    private(set) var titles: [NuvioMeta] = []
    private(set) var ids: [String] = []

    func update(_ source: [NuvioMeta], revision: Int, hideUnreleased: Bool) {
        guard revision != self.revision || hideUnreleased != hidesUnreleased else { return }
        self.revision = revision
        hidesUnreleased = hideUnreleased
        titles = hideUnreleased ? source.filter { !ContentReleasePolicy.isUnreleased($0) } : source
        ids = titles.map(\.id)
    }
}
