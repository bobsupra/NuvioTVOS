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
**Beta 3.5.0** is the latest tvOS release.

[Quick download (.ipa)](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.5.0/NuvioTV-3.5.0-unsigned-release.ipa) · [Read the release notes](https://github.com/bobsupra/NuvioTVOS/releases/tag/tvos-beta-3.5.0) · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)
<!-- END LATEST_BETA -->

The IPA requires a compatible tvOS development or sideloading signing workflow before installation.

### New in Beta 3.5.0

- **AutoSubSync & Sync by Audio:** Lines add-on subtitles up with the video automatically using embedded MKV Cues index range requests. When no embedded subtitle reference exists, Sync by Audio listens to speech patterns through AetherEngine's shared audio tap to dynamically line lines up and track delay.
- **Siri Remote Custom Gestures & Expert Mode:** Gesture recognition in the player (enabled in the player's **•••** settings panel under **Gestures**) with 8 ready-made shortcuts (chapter skips, intro/outro jump, -30s rewind, subtitle toggle, audio track switch, and next episode), plus an Expert Mode to record custom gestures and draw touchpad shapes for 11 actions.
- **Watch Party Sidebar Toggle:** Customizable setting in **Settings → General** to show or hide the Watch Party tab in the sidebar navigation.
- **MDBList Integration & Filters:** Direct MDBList catalog sources and dynamic filtering support across Collections.
- **Profile Cloud Sync:** Synchronizes custom profile background art and add-on names to your cloud account.
- **Native IMDb Trailer Streams:** Directly resolves high-definition trailer playback sources from IMDb on Details screens.
- **Top Shelf & Focus Hardening:** Remote library items on Apple TV Top Shelf, focus-safe Back routing in Calendar, day panel scroll stabilization, and clamped episode guide index on long series.

### Built-in Player

Nuvio's free built-in **AetherEngine** is the default in Auto mode. **MPVKit** is the one-way fallback, and either engine can be selected in Settings.

- **Playback:** Native tvOS and Siri Remote controls, precise seeking and resume, saved audio and subtitle tracks, audio delay, frame-rate and dynamic-range matching, direct HTTPS and HLS streams, and custom HTTP headers.
- **Video:** HDR10, HDR10+, HLG, Dolby Vision P5/P8, experimental full Dolby Vision P7 FEL, and optional MetalFX upscaling of sub-1080p SDR toward the display's resolution, with VideoToolbox/Neural Engine super-resolution when supported on compatible devices running tvOS 27.1+.
- **Audio:** Dolby Atmos passthrough (E-AC3+JOC), channel fold-down, night-mode compression, and up to +12 dB dialogue lift with peak limiting. The optional lossless audio bridge converts supported non-streamable surround audio (TrueHD, DTS-HD MA, Opus) to up to 7.1-channel LPCM (24-bit for lossless sources; lossy inputs may be 16-bit) for compatible AVRs and eARC soundbars. When disabled, multichannel audio is bridged to Dolby Digital Plus with up to 5.1 channels for ARC compatibility.
- **Subtitles and seeking:** Embedded and add-on text/PGS subtitles, authored ASS/SSA through AetherEngine's custom renderer, and thumbnail previews while scrubbing. Optional Seekr storyboards provide extra preview frames when configured. MPVKit handles separate audio/video URLs, audio amplification, and complex ASS/SSA typesetting.

For supported 48 kHz TrueHD Atmos and DTS:X VOD, **Settings → Playback → Player → Atmos & DTS:X Spatial Audio (Beta)** opts into a fixed 9.1.6 render on tvOS 26+. It is off by default. The engine delivers 24-bit PCM to the system for HDMI and AirPods Spatial Audio, or lossy APAC for AirPlay; this is not TrueHD or DTS-HD bitstream passthrough. See [the spatial audio notes](docs/truehd-spatial-audio.md) for supported sources and fallback behavior.

### Supported Tracking Services

[Trakt](https://trakt.tv) · [Simkl](https://simkl.com) · [WeTrakr](https://wetrakr.com) · [MDBList](https://mdblist.com)

### Notes

- Content availability depends on your configured sources and their upstream services.
- The Apple TV Simulator cannot play AV1.

## About

This project began with the Nuvio mobile app as its foundation. Since then, the tvOS version has grown into one of the best user-configured media players for Apple TV: a native SwiftUI app with catalog browsing, profiles, search, library and watchlist features, and playback controls designed for the Siri Remote.

The shared mobile code remains in [composeApp](./composeApp), alongside the iOS app in [iosApp](./iosApp). Active tvOS development happens in [tvosApp/NuvioTV](./tvosApp/NuvioTV).

## Current tvOS App

Native SwiftUI Apple TV app with configurable catalogs; profile-scoped Nuvio libraries, Jellyfin libraries, and SMB shares; Calendar and follows; and Watch Party. Top Shelf supports configurable content in carousel, landscape, and poster layouts. Optional Seekr seek previews show frames near the playhead. Playback uses AetherEngine, with MPVKit for demanding cases; the app also supports native Usenet/NNTP playback and opt-in P2P torrent streaming. See the [tvOS source](./tvosApp/NuvioTV) and [Tuist project](./tvosApp/Project.swift).

## Contributing

Contributions are welcome; see [CONTRIBUTING.md](./CONTRIBUTING.md).

## Development

Requires macOS, Xcode with an Apple TV simulator runtime, tvOS 18 or later, [mise](https://mise.jdx.dev) (tool version pinned in `mise.toml`), [Tuist](https://tuist.dev), and network access. The Xcode project is generated from [tvosApp/Project.swift](./tvosApp/Project.swift).

Clone with submodules and generate the workspace:

```bash
git clone --recurse-submodules <repository-url> NuvioTVOS
cd NuvioTVOS
mise install
(cd tvosApp && tuist generate)
```

With an Apple TV simulator booted, run `./scripts/run-mobile.sh tvos s` or build the `NuvioTV` scheme in Xcode.

## Configuration & Tests

Login is optional during development; the default Nuvio backend is configured for QR and email login. Unit tests are in [NuvioTVTests](./tvosApp/NuvioTVTests) and run with `scripts/test-tvos.sh`; UI tests use the separate `NuvioTV-UI` scheme. See the [UI validation notes](./tvosApp/NuvioTVUITests/README.md).

## Built With

- SwiftUI and UIKit focus/input bridging for tvOS
- AetherEngine and MPVKit playback engines
- Configurable catalog, source, and subtitle APIs
- Kotlin Multiplatform / Compose Multiplatform code from the original mobile app

## Legal & DMCA

Nuvio functions solely as a client-side interface for browsing metadata and playing media provided by user-configured sources. It is intended for content the user owns or is otherwise authorized to access.

Nuvio is not affiliated with any third-party extensions, catalogs, sources, or content providers. It does not host, store, or distribute any media content.

For comprehensive legal information, including the full disclaimer, third-party extension policy, and DMCA/Copyright information, visit the [Legal & Disclaimer Page](https://nuvioapp.space/legal).
