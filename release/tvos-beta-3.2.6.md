## tvOS Beta 3.2.6

> **Recommended install:** [NuvioTV-3.2.6-57-pyksel-signed.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.2.6/NuvioTV-3.2.6-57-pyksel-signed.ipa) is signed for bundle identifier `com.pyksel.nuviotvos`. Install this already-signed IPA with a normal IPA install workflow; do not re-sign it with a different identifier.

The companion `NuvioTV-3.2.6-unsigned-release.ipa` is provided for users who need their own signing workflow.

### Cheaper AI subtitle translation

- Reworks subtitle translation around a small adaptive look-ahead buffer: it translates the active cue plus a limited nearby window instead of continuously translating far ahead.
- Batches completed translation-cache writes, which avoids rewriting the cache once per subtitle cue.
- Uses minimal Gemini thinking and disables OpenRouter reasoning, lowering token use and request cost while preserving cue-ID validation, retry behavior, and original-subtitle fallback.
- Adds provider-aware handling for Gemma 4 responses, including thought-channel filtering and markdown-fenced batch output.

### Playback, subtitles, and streams

- Updates the built-in AetherEngine stack to 6.7.0 with its current playback, subtitle, HLS, seek, live-stream, diagnostics, frame-timing, and display-criteria fixes.
- Adds a short startup hold when an active AI subtitle cue is still resolving, so playback can begin with translated text instead of immediately racing ahead.
- Improves Top Shelf integration, stream metadata, player wake handling, and playback settings including selectable next-episode countdowns.

### App identity and profiles

- Signs the recommended installation IPA for `com.pyksel.nuviotvos`, with matching app-group entitlements for the app and Top Shelf extension.
- Adds an option to require a profile selection whenever the app returns from the background.

### Tests

- Extends playback-policy coverage for low-cost AI subtitle requests, adaptive buffering, batch cache persistence, retry jitter, and Gemini/Gemma/OpenRouter request configuration.
- Extends stream quality and playback coverage alongside the AetherEngine update.

### Known issues

- Horizontal scrolling can stutter slightly in some Home and catalog rows, especially while artwork or video-preview resources are loading.
- Trailer availability and playback depend on YouTube metadata and upstream stream resolution; previews may be unavailable for some titles.
- Catalogs, streams, provider logos, and metadata depend on configured add-ons and upstream services.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
