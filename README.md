<div align="center">

  <img src="https://github.com/tapframe/NuvioTV/blob/main/assets/brand/app_logo_wordmark.png" alt="Nuvio" width="300" />
  <br />
  <br />

  <h1>Nuvio TV for tvOS</h1>

  <p>
    A native Apple TV port of Nuvio, forked from the mobile app so the living-room experience can be developed independently.
    <br />
    SwiftUI tvOS shell - Stremio-compatible catalogs - AetherEngine / MPVKit playback
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


The Apple TV build is published as a `.ipa` on the [Releases page](https://github.com/bobsupra/NuvioTVOS/releases). Sideload it onto an Apple TV with your preferred tool (for example a Mac with Xcode, Apple Configurator, or a sideloading utility). This is a beta build - see the release notes for what works and what still needs testing.

## Latest tvOS Beta

The tree currently targets **version 3.2 (build 51)** (`tvosApp/NuvioTV/Info.plist`).

[Beta 3.2](https://github.com/bobsupra/NuvioTVOS/releases/tag/tvos-beta-3.2) is the latest tvOS release. Download the unsigned IPA here:

[NuvioTV-3.2-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.2/NuvioTV-3.2-unsigned-release.ipa)

Important: release IPAs are often unsigned because no tvOS signing identity is configured on the build machine.

### New in Beta 3.2

- Reworks Home loading, profile switching, row visibility, poster caching, grid focus, and add-on management for a faster and more stable browsing experience.
- Fixes non-Cinemeta hero cards so focused titles can recover missing runtime and ongoing-status metadata without replacing the add-on's artwork or description.
- Strengthens Continue Watching and provider synchronization with file-backed progress storage, remote-deletion reconciliation, profile isolation, queued refreshes, season-wide watched actions, and improved New Episode/New Season handling.
- Adds Simkl ratings and recommendations, nested More Like This navigation, better episode focus restoration, and faster stream-picker feedback.
- Upgrades AetherEngine with major fixes for HEVC startup, slow seeking, live/HLS playback, Atmos and audio teardown, bitmap subtitles, AirPlay, prebuffering, and playback recovery.
- Accepts Stremio cast, director, and writer fields as either arrays or comma-separated strings so malformed optional metadata no longer drops an entire catalog page.
- This beta needs broad testing, especially on physical Apple TV hardware. If something does not work, please message the maintainer with the provider, stream, and steps needed to reproduce it.

### The new player

Nuvio now uses **AetherEngine** as its primary built-in player instead of the legacy AVPlayer implementation. It supports tvOS-native playback controls, precise seeking and resume, embedded and add-on subtitles, styled text and PGS bitmap subtitles, saved audio/subtitle selections, and automatic frame-rate matching. **MPVKit** remains available as a one-way compatibility fallback for streams or controls that AetherEngine cannot currently handle, including separate video/audio URLs, audio delay, audio amplification, and ASS Scale mode.

### Trakt sign-in with your own API app

Nuvio supports Trakt device login with user-provided API credentials. This is useful when you want to use your own Trakt application instead of relying on shared app credentials.

1. Create an application at [trakt.tv/oauth/applications](https://trakt.tv/oauth/applications).
2. Set its redirect URI to `urn:ietf:wg:oauth:2.0:oob`.
3. On Apple TV, go to **Settings → Integrations → Trakt**, then enter the Trakt Client ID and Client Secret.
4. Choose **Connect with Trakt**, scan the QR code or enter its code at `trakt.tv/activate`, and approve the connection.

The Client ID and Client Secret are stored only on that Apple TV; they are deliberately excluded from Nuvio account/profile sync. Changing either credential disconnects the old Trakt session so it cannot be reused with a different application.

### Simkl sign-in with your own API app

Nuvio also supports Simkl's TV PIN flow with a user-provided Client ID.

1. Create an application in [Simkl developer settings](https://simkl.com/settings/developer/).
2. Use `urn:ietf:wg:oauth:2.0:oob` as the redirect URI when configuring the application.
3. On Apple TV, go to **Settings → Integrations → Simkl** and enter its Client ID.
4. Choose **Connect with Simkl**, scan the QR code, and enter the displayed PIN at `simkl.com/pin`.

Simkl's PIN exchange does not require a Client Secret and does not send the redirect URI. The Client ID stays on the Apple TV and is excluded from Nuvio account/profile sync; the long-lived access token is stored in the device Keychain for the current profile.

Once connected, Simkl can be selected independently as the Library and Watch Progress source. Nuvio imports Simkl watched history, uses Plan to Watch for the library, loads paused playback into Continue Watching, and sends start, pause, and stop scrobbles from the player.

The connected Simkl screen can also transfer watched history from the active Nuvio Sync profile or a connected Trakt account. Transfers are additive, preserve watched dates and episode numbers, and display live completion progress.

### Notes

The release IPA is unsigned and must be signed by a compatible tvOS development or sideloading workflow before installation. Stream availability still depends on configured add-ons and their upstream servers. Premiumize uses manual API-key entry unless a private OAuth client ID is configured. The Apple TV Simulator cannot play AV1. ASS/SSA custom positioning/typesetting is flattened to the app subtitle style.

## About

This repository started as a fork of the Nuvio mobile app. The focus of this fork is now the tvOS version: a native SwiftUI Apple TV app under [tvosApp](./tvosApp) with Apple TV navigation, focus handling, profile selection, catalog browsing, details screens, search, library/watchlist surfaces, and playback controls designed for the Siri Remote.

The original shared mobile code is still present in [composeApp](./composeApp), with the inherited iOS app under [iosApp](./iosApp). The active tvOS development surface is [tvosApp/NuvioTV](./tvosApp/NuvioTV).

## Current tvOS App

- Native SwiftUI entry point in [NuvioTVApp.swift](./tvosApp/NuvioTV/Sources/NuvioTVApp.swift).
- Apple TV tab navigation for Profile, Home, Search, Library, and Settings.
- Home rows for synced Nuvio collections and add-on catalog lists.
- Cinemeta-backed catalog and metadata repository with Stremio-compatible stream/subtitle addon hooks.
- User-configurable Stremio stream add-ons in Settings → Integrations → Add-ons.
- Debrid account linking for Real-Debrid, TorBox, and Premiumize (Settings → Integrations → Debrid). AllDebrid and Debrid-Link are not wired.
- Premiumize and TorBox Cloud Library playback through the built-in player.
- Apple TV Top Shelf extension backed by the active Continue Watching row.
- Long-press quick actions for poster cards, including details, library toggle, and watched toggle.
- QR-code and email login flow backed by Supabase configuration in [AuthConfig.swift](./tvosApp/NuvioTV/Sources/Core/Auth/AuthConfig.swift).
- tvOS profile/account sync for profiles, add-ons, library, watched state, and progress.
- Trakt device-code login using a user-provided Client ID and Client Secret, stored locally on the Apple TV.
- Simkl PIN login, watched-history sync, Plan to Watch library sync, playback progress, and scrobbling.
- New AetherEngine-first player with Siri Remote controls, precise seeking and resume, embedded/add-on subtitle support, saved track selections, frame-rate matching, and a one-way MPVKit compatibility fallback.
- Pure Swift app core (no Nuvio Rust / FFI dependency).
- tvOS app assets, splash screen, top shelf images, and Apple TV app icon stack in [Images.xcassets](./tvosApp/NuvioTV/Images.xcassets).

## Contributor Notes

This tvOS app is still early and needs real device/simulator testing. The list below is not complete; contributors should run the app, compare it with the Android TV version, and call out anything that feels broken, rough, or missing.

Current tvOS status:

- Library basics now work, including adding/removing titles, watched-state persistence, consistent poster sizing, and watched checkmark badges on cards.
- Search has received initial polish and bug fixes, including consistent poster sizing and watched checkmark badges.
- Trailer playback now opens in the player, resolves YouTube trailer streams at 1080p or better when available, supports adaptive video/audio streams, and returns to the title details page afterward.
- Home focus/hero behavior has been improved with smoother card focus, cached hero logo loading, and crossfaded hero/backdrop transitions.
- Player polish now covers saved audio/subtitle selections, screensaver prevention during playback, and steadier Play/Pause focus.
- Movie stutter is resolved with **Frame Rate Matching** (Settings → Playback) when the Apple TV system setting **Match Content** is also enabled.

Known areas that still need work:

- Nuvio addon UI flows have not been fully tested on tvOS yet.
- Search still needs more real-world testing and bug fixing.
- Library still needs more sorting/grouping validation and real-world testing.
- Vertical and horizontal scrolling still need more tuning on real devices.
- Home layout supports Modern and Compact sizing; Classic was removed because it was never distinct. Full Android grid/layout modes are not ported yet.
- AllDebrid and Debrid-Link have no resolvers and are not offered in the account-link UI.
- Cloud Library currently supports Premiumize and TorBox only.
- Top Shelf, debrid resolving, and Cloud Library still need more real-device validation across accounts/providers.
- If login still returns to the Apple TV Home screen on a real device, please send the device console or crash log.

The tvOS app is developed independently around Apple TV conventions, Siri Remote navigation, and real-device feedback. The optional local `NuvioTVandroid/` reference checkout is intentionally excluded from this repository and is not required to build or contribute to the tvOS app.

Useful new features are welcome. For large UI redesigns or major experience changes, please open a discussion or vote first so contributors can agree on direction before the app moves away from the current TV design.

## Requirements

- macOS with Xcode installed.
- Apple TV simulator runtime installed in Xcode.
- CocoaPods if `tvosApp/Pods` needs to be regenerated.
- Network access for catalog metadata, stream addon lookups, and Swift Package resolution.

The Xcode project targets Apple TV (`SDKROOT = appletvos`) with bundle id `com.nuvio.app.tv`. The tvOS deployment target is configured in [project.pbxproj](./tvosApp/NuvioTV.xcodeproj/project.pbxproj).

## Setup

```bash
git clone <your-fork-url> NuvioTVOS
cd NuvioTVOS
```

Install pods if the CocoaPods workspace has not been generated:

```bash
cd tvosApp
pod install
cd ..
```

Open the tvOS workspace:

```bash
open tvosApp/NuvioTV.xcworkspace
```

Use the `NuvioTV` scheme and an Apple TV simulator.

## Running

The helper script builds the native tvOS app, installs it on the first booted Apple TV simulator, and launches it:

```bash
./scripts/run-mobile.sh tvos s
```

If no Apple TV simulator is booted, open Simulator or Xcode first and start one, then rerun the command.

You can also build directly with Xcode:

```bash
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

Catalogs and metadata use Cinemeta plus Stremio-compatible stream and subtitle add-on endpoints from [CatalogRepository.swift](./tvosApp/NuvioTV/Sources/Data/Repository/CatalogRepository.swift).

For Real-Debrid and TorBox, open Settings → Integrations → Debrid and link with the TV QR code. Premiumize has no public open-source device OAuth — paste the API key from [premiumize.me/account](https://www.premiumize.me/account) (QR only if you set a private `PREMIUMIZE_CLIENT_ID` in `Info.plist`). TorBox/Premiumize credentials also power Cloud Library in Library.

Debrid API keys sync with the Nuvio account on the shared **tv** settings blob (`features.debrid_settings`), matching Android TV, so linking on one TV fills the other after account sync.

## Tests

Unit and UI test targets live in:

- [tvosApp/NuvioTVTests](./tvosApp/NuvioTVTests)
- [tvosApp/NuvioTVUITests](./tvosApp/NuvioTVUITests)

Run tests from Xcode, or with:

```bash
xcodebuild test \
  -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV'
```

Some older verification scripts in `tvosApp/` still carry inherited iOS wording. Prefer the Xcode build/test commands above as the source of truth for the tvOS target.

## Project Structure

- `tvosApp/NuvioTV/` contains the native SwiftUI tvOS app.
- `tvosApp/NuvioTV/Sources/UI/` contains the Apple TV screens and reusable components.
- `tvosApp/NuvioTV/Sources/ViewModels/` contains the Swift view models for tvOS flows.
- `tvosApp/NuvioTV/Sources/Data/Repository/` contains catalog, metadata, stream, and subtitle fetching.
- `tvosApp/NuvioTV/Sources/Core/Auth/` contains Supabase email and TV QR-login support.
- `MPVKit/` is the local Swift Package used for playback.
- `composeApp/` and `iosApp/` are inherited from the mobile fork and remain useful references while tvOS functionality is ported.

## Built With

- SwiftUI and UIKit focus/input bridging for tvOS
- MPVKit / libmpv for playback
- Stremio-compatible catalog, stream, and subtitle APIs
- Kotlin Multiplatform / Compose Multiplatform code inherited from the mobile fork

## Legal & DMCA

Nuvio functions solely as a client-side interface for browsing metadata and playing media provided by user-installed extensions and/or user-provided sources. It is intended for content the user owns or is otherwise authorized to access.

Nuvio is not affiliated with any third-party extensions, catalogs, sources, or content providers. It does not host, store, or distribute any media content.

For comprehensive legal information, including the full disclaimer, third-party extension policy, and DMCA/Copyright information, visit the [Legal & Disclaimer Page](https://nuvioapp.space/legal).
