## tvOS Beta 3.2.3

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

Beta 3.2.3 focuses on live-TV playback, subtitle-provider flexibility, stream-picker performance, and Home navigation. Test it with your own add-ons, streams, API credentials, displays, and Apple TV hardware.

### Live playback and player controls

- Detects live/channel content and presents a dedicated LIVE status bar instead of a misleading finite scrubber.
- Keeps live playback out of VOD resume, skip-marker, and end-of-media paths, while delaying the buffering indicator during healthy HLS refreshes.
- Routes Siri Remote transport focus deterministically between the timeline, Play, Episodes, Sources, and Settings without intermediate focus flashes.

### AI subtitles

- Adds OpenRouter as a selectable provider alongside Gemini, with provider-specific model settings and profile-scoped Keychain credentials.
- Prioritizes the next subtitle cues, then translates in bounded batches with cue-ID-preserving responses, retry handling, and rate-limit backoff.
- Keeps the original subtitle visible until a translation succeeds and isolates translation cache entries by profile, language, model, and cleaning settings.

### Streams and playback selection

- Caches stream badge settings, compiled regular expressions, and stream-card presentation work so focus updates do not repeat expensive filtering on the main thread.
- Keeps stream-list revisions coherent in Details and presents Sources in an isolated full-screen focus hierarchy with stable filter/panel geometry.
- Filters clearly unsupported AV1/HDR/4K sources for the detected Apple TV capability and distinguishes HDR transfer markers from ordinary `HDRip` labels.
- Keeps badge presentation deterministic while reducing duplicate work during progressive stream updates.

### Home, Details, and navigation

- Makes Home Up/Down focus routing immediate and animation-consistent with Left/Right navigation.
- Retains stable Home row containers, limits card-level materialization to the useful horizontal window, and keeps the complete visible card page available on larger profiles such as GG.
- Prevents focus dead ends on empty person/production results and improves restoration when returning to Home or leaving Details.

### Tests

- Adds Apple TV capability and HDR/HDRip playback-selection regression coverage.
- Extends AI subtitle tests for OpenRouter authorization, batch cue IDs, cache isolation, and subtitle cleaning.
- Retains playback backend, stream parsing, and navigation regression coverage from the preceding betas.

### Known issues

- The IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- AI subtitle quality, latency, quotas, and privacy depend on the selected provider and model; subtitle text is sent to that provider only while translation is enabled.
- Catalogs, streams, badges, and metadata depend on configured add-ons and upstream services.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV hardware paths still need real-device validation; the Apple TV Simulator cannot play AV1.
