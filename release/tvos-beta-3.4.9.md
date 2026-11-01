## tvOS Beta 3.4.9

> **Install:** [NuvioTV-3.4.9-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.9/NuvioTV-3.4.9-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 300+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 300+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Lossless Audio Bridge & Metal Video Upscaling

- **Lossless Audio Bridge (eARC / AVR):** Added **Settings → Playback → Lossless Audio Bridge (eARC / AVR)**. In AetherEngine, non-streamable surround audio (TrueHD, DTS-HD MA, Opus) transcodes directly to uncompressed 24-bit 7.1 LPCM for AVRs and eARC soundbars. When toggled off, streams use 5.1 Dolby Digital Plus for universal ARC compatibility.
- **Metal-Accelerated Video Upscaling:** Added real-time Metal frame upscaling (`FrameUpscaler`) for low-resolution and SD streams on 4K Apple TV displays (**Settings → Playback → Low-Res Upscaling**).
- **Audio Shaping & Dialogue Lift:** Dynamic audio shaping graph with centre/mid dialogue boost (+12 dB), dynamic range night mode compression, and a -1 dBFS peak limiter to prevent clipping without server re-transcoding.

### File Chapters & Piece-by-Piece Timeline

- **Native MKV/MP4 Chapters:** Reads container chapters across both AetherEngine and MPVKit players.
- **InSight Chapters Shelf:** Press **Down** during playback to access a dedicated Chapters shelf in the InSight menu, focusing directly on the playing chapter card with background-loaded storyboard stills.
- **Piece-by-Piece Timeline Scrubber:** The playback scrubber bar is cut into individual segments at chapter boundaries and opening/ending marks. The active chapter segment dynamically elevates, accompanied by a red playhead, high-contrast seek needle, and riding chapter title.
- **Intro/Outro Skip Fallback:** Seamlessly falls back to file opening and ending chapters when IntroDB metadata is unavailable.
- **Seek Snapping:** Smooth swipe gestures briefly snap to chapter starts and opening/ending boundaries for effortless navigation.

### Seek Previews & Seekr Integration

- **Seekr (seekr.tv) Integration:** Added support for external trickplay storyboards via Seekr API keys (**Settings → Playback → Seekr**), complete with in-app QR codes for sign-up and support, plus real-time key validation.
- **Out-of-Buffer Scrub Previews:** Seek previews now render beyond the buffered window using Seekr or a dedicated background NNTP preview connection.
- **Preview Stabilization:** Eliminates jitter and double previews; displays exact buffered stills rather than nearest keyframes, and dims settled previews once remote touch rests.

### Redesigned Apple TV Top Shelf & 4K Carousel

- **Interactive 4K Carousel:** Configurable Top Shelf style (**Settings → Layout → Top Shelf**) featuring full-bleed 4K backdrop artwork, title logos, metadata, and ratings.
- **In-Carousel Trailer Playback & Direct Resume:** Top Shelf carousel plays trailers automatically and provides an instant one-click Play button to resume playback directly from the Apple TV home screen.
- **Customizable Shelf Sources:** Mix Continue Watching, Up Next, Library, and Home catalogs.
- **App Group Preservation:** Unsigned IPA builds retain App Group entitlements so sideloaded installations reliably populate the tvOS Top Shelf.

### In-Player Subtitle Vertical Position Adjustment

- **Live Subtitle Height Tuning:** Adjust subtitle vertical placement on screen directly from the in-player subtitle menu in fine 4 pt increments.
- **Smooth Text Subtitle Outlines:** Enhanced text outline rendering and baseline placement across various video aspect ratios.

### Usenet Account Cloud Sync & Provider Resilience

- **Usenet Account Backup:** **Settings → Usenet → Save to Nuvio Account** optionally backs up configured NNTP servers, credentials, and connection caps to your Nuvio account profile.
- **Graceful Connection Recovery:** Dropped server connections are recovered cleanly without falsely marking articles as missing.

### Jellyfin Auto-Sync & Library Caching

- **Automatic Library Refresh:** Background sync for connected Jellyfin servers to detect new media additions automatically.
- **Remote Provider Caching:** Caches remote library structures to accelerate folder and catalog browsing.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.

