# Contributing to AetherEngine

Thanks for your interest. AetherEngine is the video playback engine behind [Sodalite](https://github.com/superuser404notfound/Sodalite) (tvOS) and [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer) (macOS). Most of the interesting work here is format- and platform-specific, so a good bug report or a focused PR with a clear test plan is worth a lot.

## Reporting bugs and requesting capabilities

Open an issue using one of the [templates](.github/ISSUE_TEMPLATE). For playback bugs, the source media details (container, video codec and profile, audio codec, HDR / Dolby Vision profile) and any AVPlayer / CoreMedia / VideoToolbox error codes are the single most useful thing you can provide. `ffprobe` output and a sample file make triage dramatically faster.

If the problem is in a host app's UI rather than the engine, report it on that app's tracker instead (the issue chooser links both).

## Building and testing

AetherEngine is a Swift package. It builds for iOS 16+, tvOS 16+, and macOS 14+.

```bash
swift build
swift test
```

For iterative work, open `Package.swift` in Xcode 26+ and pick the `AetherEngine` scheme. `FFmpegBuild` is a transitive dependency that supplies the bundled FFmpeg / dav1d binaries; you do not build it yourself.

The `aetherctl` command-line target is macOS-only (it uses `Foundation.Process`) and is excluded from the iOS / tvOS library build.

## Where playback bugs get fixed

A bug that reproduces in a host app but traces back to decoding, demuxing, the audio bridge, or display routing gets fixed **in the engine**, not worked around in the host. If a change starts adding host-side compensation for engine behavior, that is a signal the fix belongs here instead. PRs that move logic in the right direction are very welcome.

## Pull requests

- Keep each PR focused on one change.
- Fill in the test plan: the device, OS, and exact media you tested against. Engine behavior varies by all three, so "tested on Apple TV 4K, tvOS 26, DV Profile 8.1 MKV" tells a reviewer far more than "works for me."
- Update `CHANGELOG.md`.
- Follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat(audio):`, `fix(muxer):`, `chore(deps):`, and so on).
- Treat `internal` types and properties as private; they are not part of the public contract and can change in any release.

## Releases and host pins

Maintainers cut releases as annotated tags plus a GitHub Release with notes. Host apps pin AetherEngine by commit SHA, so after a change merges the host repos bump their pins to the new commit. You do not need to touch the host repos in your PR.

## License

AetherEngine is [LGPL-3.0 with an Apple Store / DRM exception](LICENSE). By contributing you agree your contributions are licensed under the same terms. Modifications to the engine itself remain under LGPL; the exception clause only covers distribution of unmodified builds through application stores.
