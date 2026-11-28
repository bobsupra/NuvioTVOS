import Foundation

/// Removes the compiled copies of the face models that earlier installs left behind.
///
/// The first time YuNet and SFace load after an install, Core ML compiles them into
/// `Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`. The entries are keyed by the
/// app's path, which changes with every install, and the system never removes the old ones:
/// each update leaves another ~37 MB pair behind. Copies made by an earlier install can't be
/// used by this one, so the folder is cleared once per install, just before the models load.
enum SceneModelCacheCleanup {
    static let folderName = "com.apple.e5rt.e5bundlecache"
    /// The install is told apart by the app's path: a new folder for every install. The
    /// bundle's own file dates come from the build machine, so they can't be used.
    static let installPathKey = "nuvio.scene.modelCacheCleanup.installPath"

    /// Returns the number of bytes removed.
    @discardableResult
    static func removeCopiesFromEarlierInstalls(
        caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "", isDirectory: true),
        installPath: String = Bundle.main.bundlePath,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard defaults.string(forKey: installPathKey) != installPath else { return 0 }
        let root = caches.appendingPathComponent(folderName, isDirectory: true)
        var removed = 0
        if FileManager.default.fileExists(atPath: root.path) {
            let size = folderSize(root)
            if (try? FileManager.default.removeItem(at: root)) != nil { removed = size }
        }
        defaults.set(installPath, forKey: installPathKey)
        return removed
    }

    private static func folderSize(_ folder: URL) -> Int {
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total = 0
        for case let file as URL in files {
            total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
        }
        return total
    }
}
