import ProjectDescription

// Repository root for Tuist. It lives here rather than in tvosApp/ because the
// tvOS project references sibling Swift packages (../Vendor/AetherEngine and
// ../MPVKit), which must sit inside the Tuist root to be resolvable.
let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .all,
        generationOptions: .options(
            // The app still relies on transitively-visible symbols from the
            // vendored packages. Revisit once the module split lands.
            enforceExplicitDependencies: false
        )
    )
)
