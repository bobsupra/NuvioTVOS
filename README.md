<div align="center">

  <img src="https://github.com/tapframe/NuvioTV/blob/main/assets/brand/app_logo_wordmark.png" alt="Nuvio" width="300" />
  <br />
  <br />

  <h1>Nuvio TV for tvOS</h1>

  <p>
    A modern Apple TV media player for browsing catalogs and playing user-configured sources.
    <br />
    SwiftUI tvOS shell - catalog browsing - AetherEngine / MPVKit playback
  </p>

  <p>
    <a href="https://github.com/bobsupra/NuvioTVOS/releases/latest">
      <img src="https://img.shields.io/github/v/release/bobsupra/NuvioTVOS?include_prereleases&sort=date&label=Download%20.ipa&logo=apple&logoColor=white&color=0A84FF&style=for-the-badge" alt="Download the latest tvOS .ipa" />
    </a>
  </p>

  <p>
    <a href="https://github.com/bobsupra/NuvioTVOS/graphs/contributors">
      <img src="https://img.shields.io/github/contributors/bobsupra/NuvioTVOS?style=for-the-badge&color=44CC11" alt="Contributors" />
    </a>
    <a href="https://github.com/bobsupra/NuvioTVOS/forks">
      <img src="https://img.shields.io/github/forks/bobsupra/NuvioTVOS?style=for-the-badge&color=0A84FF" alt="Forks" />
    </a>
    <a href="https://github.com/bobsupra/NuvioTVOS/stargazers">
      <img src="https://img.shields.io/github/stars/bobsupra/NuvioTVOS?style=for-the-badge&color=0A84FF" alt="Stars" />
    </a>
    <a href="https://github.com/bobsupra/NuvioTVOS/issues">
      <img src="https://img.shields.io/github/issues/bobsupra/NuvioTVOS?style=for-the-badge&color=E5C100" alt="Open issues" />
    </a>
    <a href="https://github.com/bobsupra/NuvioTVOS/releases">
      <img src="https://img.shields.io/github/downloads/bobsupra/NuvioTVOS/total?style=for-the-badge&label=Total%20downloads&color=F47732" alt="Total downloads" />
    </a>
  </p>

</div>


Download the latest Apple TV `.ipa` from [Releases](https://github.com/bobsupra/NuvioTVOS/releases), then sideload it with Xcode, Apple Configurator, or your preferred tool. See the release notes for known issues.

> **AltStore / SideStore / Feather Source:** Add `https://raw.githubusercontent.com/bobsupra/NuvioTVOS/main/apps.json` · [Add to AltStore](altstore://source?url=https://raw.githubusercontent.com/bobsupra/NuvioTVOS/main/apps.json) · [Add to SideStore](sidestore://source?url=https://raw.githubusercontent.com/bobsupra/NuvioTVOS/main/apps.json)

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases**.

## Latest tvOS Beta

<!-- BEGIN LATEST_BETA -->
**Beta 3.4.8** is the latest tvOS release.

[Quick download (.ipa)](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.8/NuvioTV-3.4.8-unsigned-release.ipa) · [Read the release notes](https://github.com/bobsupra/NuvioTVOS/releases/tag/tvos-beta-3.4.8) · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)
<!-- END LATEST_BETA -->

> 🎉 **Thank you for 300+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping us reach 300+ stars!

The IPA requires a compatible tvOS development or sideloading signing workflow before installation.

### New in Beta 3.4.8

- **Native Usenet & NNTP Streaming Playback:** Stream video directly from NZB URLs (`nzbUrl`) from Stremio addons with up to 100 parallel connections, a decoupled 4-second read-ahead buffer unaffected by speed caps, and non-thrashing seeks.
- **Dedicated Calendar Tab & Follows:** New **Calendar** tab (`TVTab.calendar`) displaying upcoming episodes and releases with merged manual and automatic follows, plus a dynamic **Today** shelf row on Home.
- **Smart Credit Skipping & Enhanced Player Controls:** Automatically skip closing credits while preserving mid-credit and post-credit scenes, expanded on-screen player controls, smooth outline subtitle rendering, and prewarmed stream handoffs from Details.
- **Home, Details & Top Shelf Polish:** Configurable Details section ordering and visibility, unified "All" hero rating source, redesigned Apple TV Top Shelf with four 16:9 rows, fast addon search with linear keyboard sizing, and MDBList request caching.
- **AetherEngine 7.51.0 & Audio Shaping:** Upgraded core playback engine to version 7.51.0 with dynamic audio shaping (channel fold-down, night mode compression, +12 dB dialogue lift with peak limiting), Apple required-reason privacy manifests (`PrivacyInfo.xcprivacy`), packetized streaming drainage for sidecar bitmap subtitles (`.sup`), and HLS session lifecycle cleanup.

### Built-in Player

Nuvio ships with **AetherEngine** — a free, built-in player with native tvOS controls, subtitle support, resume, audio delay adjustment, and frame-rate matching. **MPVKit** stays as a fallback for edge cases AetherEngine doesn't cover yet (including audio amplification, separate video/audio streams, and full ASS typesetting).

For TrueHD Atmos and DTS:X movies, **Settings → Playback → Player → Atmos & DTS:X Spatial Audio (Beta)**
opts into a fixed 9.1.6 render through APAC on tvOS 26+. It is off by default and uses lossy
encoding. See [the spatial audio notes](docs/truehd-spatial-audio.md) for supported sources,
fallback behavior, and the distinction from TrueHD passthrough.

#### AetherEngine vs Infuse

| Feature | AetherEngine (Nuvio) | Infuse |
|---|---|---|
| **Price** | ✅ 100% Free & built-in | ❌ Subscription / paid Pro unlock |
| **Open source** | ✅ Open source (ships with Nuvio) | ❌ Proprietary / closed source |
| **Native tvOS controls** | ✅ Siri Remote, swipe seek | ✅ Yes |
| **Resume & watch progress** | ✅ Precise resume | ✅ Yes |
| **Text subtitles (SRT/VTT)** | ✅ Styled, embedded & external | ✅ Yes |
| **PGS bitmap subtitles** | ✅ Yes | ✅ Yes |
| **ASS/SSA subtitles** | ⚠️ Styled (no typesetting) | ✅ Full typesetting |
| **Audio & subtitle selection** | ✅ Saved per item | ✅ Yes |
| **Frame-rate & dynamic range matching** | ✅ Automatic | ✅ Automatic |
| **HDR10, HDR10+ & HLG** | ✅ Native support | ✅ Supported |
| **Dolby Vision (P5/P8)** | ✅ Built-in | 🔒 Requires paid Infuse Pro |
| **Dolby Atmos** | ✅ Built-in passthrough (EAC3+JOC) | 🔒 Requires paid Infuse Pro |
| **High-end audio codecs (DTS-HD, TrueHD)** | ✅ Included free (stream-copy / EAC3 bridge) | 🔒 Requires paid Infuse Pro |
| **In-player audio delay (lip-sync)** | ✅ Live ±ms offset stepper | ❌ No in-player delay (system/AVR only) |
| **Audio amplification (boost)** | ⚠️ MPVKit fallback | ✅ Built-in volume boost |
| **Custom HTTP headers (Referer/User-Agent)** | ✅ Built-in relay & custom headers | ❌ Standard URLs only |
| **Trakt & Simkl scrobbling** | ✅ Built-in (custom API apps) | 🔌 Trakt only (Simkl not supported) |
| **Separate video+audio URLs** | ⚠️ MPVKit fallback | ❌ Not supported |

### Trakt sign-in with your own API app

Nuvio supports Trakt device login with user-provided API credentials. This is useful when you want to use your own Trakt application instead of relying on shared app credentials.

1. Create an application at [trakt.tv/oauth/applications](https://trakt.tv/oauth/applications).
2. Set its redirect URI to `http://localhost:5173/callback`.
3. On Apple TV, go to **Settings → Integrations → Trakt**, then enter the Trakt Client ID and Client Secret.
4. Choose **Connect with Trakt**, scan the QR code or enter its code at `trakt.tv/activate`, and approve the connection.

New profiles default to `http://localhost:5173/callback`. Existing profiles with a Trakt Client ID and no saved redirect setting keep the legacy `urn:ietf:wg:oauth:2.0:oob` value. You can keep an app's registered URI or change it in **Settings → Integrations → Trakt**; the value must exactly match the URI registered with Trakt because token refresh uses it.

The Client ID and Client Secret are stored only on that Apple TV; they are deliberately excluded from Nuvio account/profile sync. Changing either credential disconnects the old Trakt session so it cannot be reused with a different application.

### Simkl sign-in with your own API app

Nuvio supports Simkl TV PIN login with a user-provided Client ID.

1. Create an application in [Simkl developer settings](https://simkl.com/settings/developer/).
2. Use `urn:ietf:wg:oauth:2.0:oob` as the redirect URI when configuring the application.
3. On Apple TV, go to **Settings → Integrations → Simkl** and enter its Client ID.
4. Choose **Connect with Simkl**, scan the QR code, and enter the displayed PIN at `simkl.com/pin`.

Simkl's PIN flow does not need a Client Secret. The Client ID stays on that Apple TV and is excluded from Nuvio sync; the access token is stored in the current profile's Keychain.

### Notes

- Content availability depends on your configured sources and their upstream services.
- The Apple TV Simulator cannot play AV1. ASS/SSA positioning and typesetting use the app subtitle style.

## About

This repository started as a fork of the Nuvio mobile app. The focus of this fork is now the tvOS version: a native SwiftUI Apple TV app under [tvosApp](./tvosApp) with Apple TV navigation, focus handling, profile selection, catalog browsing, details screens, search, library/watchlist surfaces, and playback controls designed for the Siri Remote.

The original shared mobile code is still present in [composeApp](./composeApp), with the inherited iOS app under [iosApp](./iosApp). The active tvOS development surface is [tvosApp/NuvioTV](./tvosApp/NuvioTV).

## Current tvOS App

- Native SwiftUI entry point in [NuvioTVApp.swift](./tvosApp/NuvioTV/Sources/NuvioTVApp.swift).
- Apple TV tab navigation for Profile, Home, Search, Library, and Settings.
- Home rows for synced Nuvio collections and configured catalog lists.
- Catalog and metadata repository with configurable catalog, playback, and subtitle integrations.
- User-configurable source integrations in Settings → Integrations → Add-ons.
- Cloud library playback through supported connected services.
- Apple TV Top Shelf extension backed by the active Continue Watching row.
- Long-press quick actions for poster cards, including details, library toggle, and watched toggle.
- QR-code and email login flow backed by Supabase configuration in [AuthConfig.swift](./tvosApp/NuvioTV/Sources/Core/Auth/AuthConfig.swift).
- tvOS profile/account sync for profiles, add-ons, settings, library, watched state, and progress. Settings follow the selected profile across Apple TVs; device-only app credentials stay local.
- Trakt device-code login using a user-provided Client ID and Client Secret, stored locally on the Apple TV.
- Simkl PIN login, watched-history sync, Plan to Watch library sync, playback progress, and scrobbling.
- New AetherEngine-first player with Siri Remote controls, precise seeking and resume, embedded/add-on subtitle support, saved track selections, frame-rate matching, and a one-way MPVKit compatibility fallback.
- Pure Swift app core (no Nuvio Rust / FFI dependency).
- tvOS app assets, splash screen, top shelf images, and Apple TV app icon stack in [Images.xcassets](./tvosApp/NuvioTV/Images.xcassets).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution rules, testing notes, and issue-reporting guidance.

## Requirements

- macOS with Xcode installed.
- Apple TV simulator runtime installed in Xcode.
- [Tuist](https://tuist.dev) to generate the Xcode project. Install it with [mise](https://mise.jdx.dev): `mise install` picks up the pinned version from [mise.toml](./mise.toml).
- Network access for catalog metadata, source lookups, and Swift Package resolution.

The Xcode project is **generated by Tuist and is not tracked in git**. Edit [tvosApp/Project.swift](./tvosApp/Project.swift) rather than the `.xcodeproj`, then re-run `tuist generate`. Source files are picked up by glob, so adding a file needs no project edit at all.

The app targets Apple TV (`SDKROOT = appletvos`) with bundle id `com.pyksel.nuviotvos` and a tvOS 18 deployment target, all declared in `Project.swift`.

## Setup

```bash
git clone --recurse-submodules <your-fork-url> NuvioTVOS
cd NuvioTVOS
```

> **Note:** If you already cloned without `--recurse-submodules`, initialize the submodules before generating the project:
> ```bash
> git submodule update --init --recursive
> ```

Install the pinned toolchain and generate the Xcode project:

```bash
mise install
cd tvosApp
tuist generate
```

`tuist generate` opens the workspace in Xcode. Use `--no-open` to only write it.


Use the `NuvioTV` scheme and an Apple TV simulator.

## Running

The helper script builds the native tvOS app, installs it on the first booted Apple TV simulator, and launches it:

```bash
./scripts/run-mobile.sh tvos s
```

If no Apple TV simulator is booted, open Simulator or Xcode first and start one, then rerun the command.

You can also build directly with Xcode:

```bash
(cd tvosApp && tuist generate --no-open)
xcodebuild \
  -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV \
  -configuration Debug \
  -destination 'generic/platform=tvOS Simulator' \
  build
```

## Configuration

Account login is optional during development. The login screen supports "Continue without account" so the tvOS UI can be tested without backend credentials.

To enable QR login and email auth, fill in the Supabase values in:

```text
tvosApp/NuvioTV/Sources/Core/Auth/AuthConfig.swift
```

Catalogs and metadata use configurable catalog, playback, and subtitle endpoints from [CatalogRepository.swift](./tvosApp/NuvioTV/Sources/Data/Repository/CatalogRepository.swift).

## Tests

Unit tests live in [tvosApp/NuvioTVTests](./tvosApp/NuvioTVTests).

[tvosApp/NuvioTVUITests](./tvosApp/NuvioTVUITests) belongs to the `NuvioTVUITests` target and the shared `NuvioTV-UI` scheme. The `NuvioTV` scheme and `scripts/test-tvos.sh` continue to select unit tests; UI tests are an explicit developer run.

Run tests from Xcode, or with:

```bash
xcodebuild test \
  -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV'
```

After regenerating the workspace, first verify the UI bundle compiles:

```bash
xcodebuild build-for-testing \
  -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV-UI \
  -destination 'platform=tvOS Simulator,name=Apple TV' \
  CODE_SIGNING_ALLOWED=NO
```

Choose an installed simulator destination if the example name differs. Then select `NuvioTV-UI` in Xcode to review/run the UI suite, or use:

```bash
xcodebuild test \
  -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV-UI \
  -destination 'platform=tvOS Simulator,name=Apple TV' \
  CODE_SIGNING_ALLOWED=NO
```

Review the UI suite's selectors and tvOS interactions for the installed SDK, and configure its required catalog, Continue Watching and watchlist data before using it as a regression gate. A declared target is not evidence of passing UI coverage. The existing CI unit-test job does not automatically run this scheme.

See [UI suite validation notes](./tvosApp/NuvioTVUITests/README.md) for remote-focus helpers, explicit skips and outstanding fixture limitations. Maintainer build-for-testing and runtime validation are required before merging the UI-target change.

Some older verification scripts in `tvosApp/` still carry inherited iOS wording. Prefer the Xcode build/test commands above as the source of truth for the tvOS target.

## Project Structure

- `tvosApp/NuvioTV/` contains the native SwiftUI tvOS app.
- `tvosApp/NuvioTV/Sources/UI/` contains the Apple TV screens and reusable components.
- `tvosApp/NuvioTV/Sources/ViewModels/` contains the Swift view models for tvOS flows.
- `tvosApp/NuvioTV/Sources/Data/Repository/` contains catalog, metadata, source, and subtitle fetching.
- `tvosApp/NuvioTV/Sources/Core/Auth/` contains Supabase email and TV QR-login support.
- `MPVKit/` is the local Swift Package used for playback.
- `composeApp/` and `iosApp/` are inherited from the mobile fork and remain useful references while tvOS functionality is ported.

## Built With

- SwiftUI and UIKit focus/input bridging for tvOS
- AetherEngine and MPVKit playback engines
- Configurable catalog, source, and subtitle APIs
- Kotlin Multiplatform / Compose Multiplatform code inherited from the mobile fork

## Legal & DMCA

Nuvio functions solely as a client-side interface for browsing metadata and playing media provided by user-configured sources. It is intended for content the user owns or is otherwise authorized to access.

Nuvio is not affiliated with any third-party extensions, catalogs, sources, or content providers. It does not host, store, or distribute any media content.

For comprehensive legal information, including the full disclaimer, third-party extension policy, and DMCA/Copyright information, visit the [Legal & Disclaimer Page](https://nuvioapp.space/legal).
