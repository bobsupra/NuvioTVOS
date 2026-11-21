import SwiftUI
import UIKit

extension SettingsKey {
    static let aniListFindInMenu = "nuvio.tv.settings.integrations.aniListFindInMenu"
    static let malFindInMenu = "nuvio.tv.settings.integrations.malFindInMenu"
}

/// "Find on AniList", "Find on MyAnimeList" and "Find on Kitsu" in a card's long-press menu: an anime from
/// Cinemeta or TMDB that the offline tables know opens as the AniList or MyAnimeList title it
/// maps to (a series by its first season, whole with One Title), an AniList title as its
/// MyAnimeList one and a MyAnimeList title as its AniList one. Each source offers it while it is
/// on (MyAnimeList with MAL Titles) and its own setting is on; a title the offline tables don't
/// map offers nothing (the menu asks nothing online).
enum AnimeFind {
    static let openNotification = Notification.Name("nuvio.animeFind.open")

    struct Targets: Equatable, Sendable {
        var aniList: String?
        var mal: String?
        var kitsu: String?

        var isEmpty: Bool { aniList == nil && mal == nil && kitsu == nil }
    }

    static var offersAniList: Bool {
        AniListSettings.isEnabled && flag(SettingsKey.aniListFindInMenu)
    }

    static var offersMAL: Bool {
        MALSettings.opensTitles && flag(SettingsKey.malFindInMenu)
    }

    static var offersKitsu: Bool {
        KitsuSettings.findsInMenu
    }

    /// What the menu offers for this card; nil for nothing. Kept for the session.
    static func targets(for meta: NuvioMeta) async -> Targets? {
        let aniListOn = offersAniList
        let malOn = offersMAL
        let kitsuOn = offersKitsu
        guard aniListOn || malOn || kitsuOn else { return nil }
        let key = "\(meta.id.lowercased())|\(aniListOn)|\(malOn)|\(kitsuOn)"
        if let kept = Kept.value(key) { return kept.isEmpty ? nil : kept }

        // The AniList entry everything maps through, and the card's own source (not offered).
        let maps = AniListOfflineMaps.shared
        let own = AnimeSource.entry(from: meta.id)
        let entry: Int?
        switch own?.source {
        case .anilist?: entry = own?.id
        case .mal?: entry = await maps.aniListID(mal: own?.id ?? 0)
        case .kitsu?: entry = await maps.aniListID(kitsu: own?.id ?? 0)
        case nil: entry = await AniListService.mappedEntry(for: meta)
        }
        var targets = Targets()
        if let entry {
            let offline = await maps.entry(aniListID: entry)
            if aniListOn, own?.source != .anilist {
                targets.aniList = AnimeSource.anilist.prefix + String(entry)
            }
            if malOn, own?.source != .mal, let mal = offline?.mal, mal > 0 {
                targets.mal = AnimeSource.mal.prefix + String(mal)
            }
            if kitsuOn, own?.source != .kitsu, let kitsu = offline?.kitsu, kitsu > 0 {
                targets.kitsu = AnimeSource.kitsu.prefix + String(kitsu)
            }
        }
        Kept.store(key, targets)
        return targets.isEmpty ? nil : targets
    }

    /// AniList's own icon (the one the cards' AniList mark shows), loaded once for the menu.
    static var aniListIcon: UIImage? {
        iconLock.lock()
        defer { iconLock.unlock() }
        return loadedIcon
    }

    private static let iconLock = NSLock()
    private static var loadedIcon: UIImage?

    static func loadAniListIcon() async {
        guard aniListIcon == nil, let url = URL(string: AniListMetaBuilder.ratingIcon) else { return }
        let reply = try? await URLSession.shared.data(from: url)
        guard let data = reply?.0, let image = UIImage(data: data) else { return }
        let size = CGSize(width: 48, height: 48)
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        iconLock.lock()
        loadedIcon = small
        iconLock.unlock()
    }

    /// Opens the title's details (NuvioTVApp listens).
    static func open(_ id: String, type: String) {
        NotificationCenter.default.post(name: openNotification, object: nil, userInfo: ["id": id, "type": type])
    }

    private static func flag(_ key: String) -> Bool {
        let store = ProfileSettings.current
        return store.object(forKey: key) == nil || store.bool(forKey: key)
    }

    private enum Kept {
        private static let lock = NSLock()
        private static var values: [String: Targets] = [:]

        static func value(_ key: String) -> Targets? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        static func store(_ key: String, _ targets: Targets) {
            lock.lock()
            defer { lock.unlock() }
            if values.count > 2000 { values.removeAll() }
            values[key] = targets
        }
    }
}

/// NuvioTVApp's root view: deep links (`onOpenURL`) and what `AnimeFind.open` asks for.
struct AnimeFindOpening: ViewModifier {
    let openURL: (URL) -> Void
    let open: (String, String) -> Void

    func body(content: Content) -> some View {
        content
            .onOpenURL(perform: openURL)
            .onReceive(NotificationCenter.default.publisher(for: AnimeFind.openNotification).receive(on: RunLoop.main)) { note in
                guard let id = note.userInfo?["id"] as? String, let type = note.userInfo?["type"] as? String else { return }
                open(id, type)
            }
    }
}
