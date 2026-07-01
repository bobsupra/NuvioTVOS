<div align="center">

  <img src="https://github.com/tapframe/NuvioTV/blob/main/assets/brand/app_logo_wordmark.png" alt="Nuvio" width="300" />
  <br />
  <br />

  <h1>Nuvio TV for tvOS</h1>

  <p>
    A native Apple TV port of Nuvio, forked from the mobile app so the living-room experience can be developed independently.
    <br />
    SwiftUI tvOS shell - Stremio-compatible catalogs - MPVKit playback
  </p>

  <p>
    <a href="https://github.com/bobsupra/NuvioTVOS/releases/latest">
      <img src="https://img.shields.io/github/v/release/bobsupra/NuvioTVOS?include_prereleases&sort=date&label=Download%20.ipa&logo=apple&logoColor=white&color=0A84FF&style=for-the-badge" alt="Download the latest tvOS .ipa" />
    </a>
  </p>

</div>

## Download

**[⬇️ Download `TVOS beta 1.ipa` (Apple TV)](https://github.com/bobsupra/NuvioTVOS/releases/tag/tvos-beta-1)** &nbsp;·&nbsp; [all releases](https://github.com/bobsupra/NuvioTVOS/releases)

The Apple TV build is published as a `.ipa` on the [Releases page](https://github.com/bobsupra/NuvioTVOS/releases). Sideload it onto an Apple TV with your preferred tool (for example a Mac with Xcode, Apple Configurator, or a sideloading utility). This is a beta build — see the release notes for what works and what still needs testing.

## About

This repository started as a fork of the Nuvio mobile app. The focus of this fork is now the tvOS version: a native SwiftUI Apple TV app under [tvosApp](./tvosApp) with Apple TV navigation, focus handling, profile selection, catalog browsing, details screens, search, library/watchlist surfaces, and playback controls designed for the Siri Remote.

The original shared mobile code is still present in [composeApp](./composeApp), with the inherited iOS app under [iosApp](./iosApp). The active tvOS development surface is [tvosApp/NuvioTV](./tvosApp/NuvioTV).

## Current tvOS App

- Native SwiftUI entry point in [NuvioTVApp.swift](./tvosApp/NuvioTV/Sources/NuvioTVApp.swift).
- Apple TV tab navigation for Profile, Home, Search, Library, and Settings.
- Cinemeta-backed catalog and metadata repository with Stremio-compatible stream/subtitle addon hooks.
- User-configurable Stremio stream addon manifest URL in Settings → Integrations → Add-ons.
- QR-code and email login flow backed by Supabase configuration in [AuthConfig.swift](./tvosApp/NuvioTV/Sources/Core/Auth/AuthConfig.swift).
- Local Swift profile/session stubs while the full shared/Rust-backed account surface is being ported.
- MPVKit-based player surface with tvOS remote input, skip controls, subtitle handling, and resume support.
- tvOS app assets, splash screen, top shelf images, and Apple TV app icon stack in [Images.xcassets](./tvosApp/NuvioTV/Images.xcassets).

## Contributor Notes

This tvOS app is still early and needs real device/simulator testing. The list below is not complete; contributors should run the app, compare it with the Android TV version, and call out anything that feels broken, rough, or missing.

Current tvOS status:

- Library basics now work, including adding/removing titles, watched-state persistence, consistent poster sizing, and watched checkmark badges on cards.
- Search has received initial polish and bug fixes, including consistent poster sizing and watched checkmark badges.
- Trailer playback now opens in the player, resolves YouTube trailer streams at 1080p or better when available, supports adaptive video/audio streams, and returns to the title details page afterward.
- Home focus/hero behavior has been improved with smoother card focus, cached hero logo loading, and crossfaded hero/backdrop transitions.

Known areas that still need work:

- Nuvio addon UI flows have not been fully tested on tvOS yet.
- Video playback is currently choppy/laggy during movies. This may be frame pacing, FPS, rendering, buffering, MPVKit configuration, or something else that needs profiling.
- Search still needs more real-world testing and bug fixing.
- Library still needs more sorting/grouping validation and real-world testing.
- Vertical and horizontal scrolling still need more tuning on real devices.
- The current layout is using the modern view only. Grid view and the other layout settings from Android TV still need to be brought over.
- IntroDB integration is needed.
- Trakt is not implemented yet.

The Android TV version is the main UX reference for this port. Before changing navigation, focus behavior, scrolling, player controls, layout settings, or core interaction patterns, run the Android TV app in an emulator and feel how that version behaves. The tvOS version does not need to be a pixel-for-pixel clone, but it should preserve the things that make the Android TV app work well on a couch/remote interface.

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

The catalog prototype currently uses Cinemeta plus Stremio-compatible stream and subtitle addon endpoints from [CatalogRepository.swift](./tvosApp/NuvioTV/Sources/Data/Repository/CatalogRepository.swift).

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
