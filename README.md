<div align="center">

  <img src="https://github.com/tapframe/NuvioTV/blob/main/assets/brand/app_logo_wordmark.png" alt="Nuvio" width="300" />
  <br />
  <br />

  <h1>NuvioTVOS × IPTV</h1>

  <p>
    Nuvio for Apple TV with Live TV / IPTV built in.
    <br />
    A fork of <a href="https://github.com/bobsupra/NuvioTVOS">NuvioTVOS</a> that ports the Live TV features of
    <a href="https://github.com/homelessbrian/NuvioPlusIPTV">Nuvio + IPTV</a> (Android TV) to tvOS.
  </p>

  <p>
    <a href="https://github.com/Arrgh106/NuvioTVOSxIPTV/releases/latest">
      <img src="https://img.shields.io/github/v/release/Arrgh106/NuvioTVOSxIPTV?include_prereleases&sort=date&label=Download%20.ipa&logo=apple&logoColor=white&color=0A84FF&style=for-the-badge" alt="Download the latest tvOS .ipa" />
    </a>
    <a href="https://github.com/Arrgh106/NuvioTVOSxIPTV/actions/workflows/build-ipa.yml">
      <img src="https://img.shields.io/github/actions/workflow/status/Arrgh106/NuvioTVOSxIPTV/build-ipa.yml?style=for-the-badge&label=IPA%20build" alt="IPA build status" />
    </a>
    <a href="./LICENSE">
      <img src="https://img.shields.io/github/license/Arrgh106/NuvioTVOSxIPTV?style=for-the-badge&color=44CC11" alt="License: GPL-3.0" />
    </a>
  </p>

</div>

## What this is

[NuvioTVOS](https://github.com/bobsupra/NuvioTVOS) is a native SwiftUI media player for Apple TV: catalogs, add-ons, profiles, library, calendar, Watch Party, and the AetherEngine / MPVKit players.

[Nuvio + IPTV](https://github.com/homelessbrian/NuvioPlusIPTV) adds a full Live TV side to Nuvio on Android TV (Xtream / M3U, EPG, TiviMate-style guide, catch-up, recordings, sports hub and more), but it's Android only.

**This fork brings those Live TV features to the Apple TV.** Everything from NuvioTVOS stays as it is. Live TV is added as its own sidebar tab and uses the app's built-in player in live mode.

## Install

1. Download the newest `.ipa`:
   - from [Releases](https://github.com/Arrgh106/NuvioTVOSxIPTV/releases), or
   - from the latest successful [IPA build](https://github.com/Arrgh106/NuvioTVOSxIPTV/actions/workflows/build-ipa.yml) (**Artifacts** at the bottom of the run, GitHub login required).
2. Sideload it to your Apple TV with Sideloadly, AltStore/SideStore, atvloadly, Xcode or Apple Configurator. The IPA is unsigned and gets signed with your own Apple ID when you install it.

> **AltStore / SideStore / Feather source:** `https://raw.githubusercontent.com/Arrgh106/NuvioTVOSxIPTV/main/apps.json`

> **Note:** This build uses the same bundle ID as NuvioTVOS (`com.pyksel.nuviotvos`), so it **replaces** an installed NuvioTVOS instead of installing next to it.

<!-- BEGIN LATEST_BETA -->
No release has been published yet. Grab the IPA from the latest [IPA build](https://github.com/Arrgh106/NuvioTVOSxIPTV/actions/workflows/build-ipa.yml).
<!-- END LATEST_BETA -->

## Live TV setup (Xtream Codes)

1. Open **Live TV** in the sidebar.
2. Enter the **server** your provider gave you (e.g. `http://example.com:8080`), your **username** and your **password**.
3. Pick a **stream format**:
   - **Auto** (default): HLS if your account allows it, otherwise TS.
   - **TS** / **HLS**: force one format if channels don't start.
4. **Sign in.** The login is checked against the provider before anything is saved.

The password is stored in the Apple TV Keychain. Each Nuvio profile has its own Live TV login. The channel list is cached on the device and refreshes every 12 hours, or when you press **Refresh**.

## Feature status

What is done and what is planned, compared with Nuvio + IPTV:

| Feature | Status |
| --- | --- |
| Xtream Codes login, account expiry & connections | ✅ Done |
| Channel groups, channel list with numbers & logos | ✅ Done |
| Live playback in the built-in player (live mode) | ✅ Done |
| Channel zapping in the player (up/down, channel list overlay) | 🚧 Next |
| EPG from the provider (`xmltv.php`) + extra XMLTV guides, merging, "Assign EPG" | 🗓 Planned |
| TiviMate-style TV guide grid, info panel, overlay mode | 🗓 Planned |
| Favorites, hide / reorder / rename channels, custom groups, name cleaner | 🗓 Planned |
| Parental controls (PIN lock for groups) | 🗓 Planned |
| Catch-up, restart live shows, time-shift | 🗓 Planned |
| On Demand (provider movies & series, matched to Nuvio details) | 🗓 Planned |
| M3U playlists (link / Dispatcharr) | 🗓 Planned |
| Live TV in search, "Find & stream" through your add-ons | 🗓 Planned |
| Sports hub (scores, schedules, channels showing a game) | 🗓 Planned |
| Calendar extensions | 🗓 Planned |
| Setup sync between devices | 🗓 Planned |
| Recordings | ⚠️ Limited by tvOS, see below |
| Built-in VPN (WireGuard / OpenVPN) | ⚠️ Limited by tvOS, see below |

### tvOS limits

- **Recordings:** tvOS doesn't let apps record in the background or in standby, and the Apple TV has no USB storage. At most, recording would work while the app is open, saving to an SMB network share.
- **VPN:** A VPN tunnel needs Apple's Network Extension entitlement, which a free Apple ID can't sign when sideloading. It may be possible with a paid developer account later. Until then, use a VPN on your router.

## Building

You don't need a Mac. Every push runs [`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml) on a GitHub-hosted macOS runner and uploads an unsigned IPA as an artifact. Pushing a tag like `v0.1.0` also publishes a GitHub Release with the IPA.

The upstream code targets the tvOS 27 SDK (Xcode 27), but GitHub's runners currently ship Xcode 26. The few tvOS 27-only sidebar APIs are wrapped in `#if compiler(>=6.4)`. Built with Xcode 26, the profile button appears as a sidebar tab instead of in the tvOS 27 sidebar header. Everything else is unchanged.

To build locally on a Mac you need Xcode (26 or 27), [mise](https://mise.jdx.dev) and [Tuist](https://tuist.dev) (version pinned in `mise.toml`):

```bash
git clone https://github.com/Arrgh106/NuvioTVOSxIPTV.git
cd NuvioTVOSxIPTV
mise install
(cd tvosApp && tuist generate)
./scripts/build-ipa.sh        # unsigned IPA in ./build-ipa
```

### Where the Live TV code lives

| Path | Contents |
| --- | --- |
| [`tvosApp/NuvioTV/Sources/Core/LiveTV/`](tvosApp/NuvioTV/Sources/Core/LiveTV) | Xtream API client, models, account and Keychain storage, channel cache, `LiveTVStore` |
| [`tvosApp/NuvioTV/Sources/UI/LiveTV/`](tvosApp/NuvioTV/Sources/UI/LiveTV) | Live TV tab: login form, groups, channel list |
| [`tvosApp/NuvioTV/Sources/NuvioTVApp.swift`](tvosApp/NuvioTV/Sources/NuvioTVApp.swift) | `TVTab.liveTV` and the hand-off to the built-in player |

Channels are passed to the player with an `iptv:` id and the `channel` type, which switches the player into its live mode (fast zapping start, no resume or scrobbling).

## Credits

- [NuvioTVOS](https://github.com/bobsupra/NuvioTVOS) by bobsupra and contributors: the tvOS app this fork is based on.
- [Nuvio + IPTV](https://github.com/homelessbrian/NuvioPlusIPTV) by homelessbrian: the Live TV design and behaviour being ported.
- [Nuvio](https://github.com/tapframe/NuvioTV) by tapframe: the original app.

For everything the upstream app does (player, HDR / Dolby Vision, audio, subtitles, Usenet, torrents, tracking services), see the [NuvioTVOS README](https://github.com/bobsupra/NuvioTVOS#readme).

## License

GPL-3.0, like both upstream projects. See [LICENSE](./LICENSE).

## Legal

This app only plays content from sources you configure yourself, such as add-ons or your own IPTV subscription. It does not host, store or distribute any media and doesn't come with any channels or playlists. Only use it with content you are allowed to access.

See also the upstream [Legal & Disclaimer page](https://nuvioapp.space/legal).
