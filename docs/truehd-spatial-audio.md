# Optional TrueHD Atmos and DTS:X spatial audio

In **Settings → Playback → Player**, enable **Atmos & DTS:X Spatial Audio (Beta)**.
The preference is off by default, belongs to the current profile, and applies to
subsequent playback loads. It uses AetherEngine; MPVKit and external players retain
their existing behavior. The switch is disabled below tvOS 26, and playback also
ignores an enabled preference synced from a newer device.

For supported 48 kHz TrueHD Atmos and DTS:X video-on-demand sources, the engine decodes the
object presentation and timed metadata, renders to a fixed 9.1.6 (16-channel) bed,
delivers it according to route capability (lossless 24-bit PCM for HDMI and AirPods spatial audio,
or APAC for AirPlay), and plays through the native HLS/AVPlayer path. The upstream bitrate
default for APAC is 320 kbps per output channel (5.12 Mbps for this layout).

APAC is lossy. This is not TrueHD or DTS-HD bitstream passthrough and does not send the
original dynamic objects to the receiver for independent rendering. Other source
formats, unsupported routes, and failures to start the spatial path retain the
engine's existing audio bridge behavior. A fixed 9.1.6 render is not a claim of
perfect reproduction on every speaker layout. The option remains experimental.

## Dependencies and compatibility

- AetherEngine 7.36.0, preserving Nuvio's local integrations and APAC failure handling.
- FFmpegBuild 3.7.1 with the existing AetherLib module names for MPVKit coexistence.
- LibTrueHD 2.3.0 and LibDTSX 1.0.1, pinned exactly, with their licenses/notices in app resources.
- Minimum app deployment target: tvOS 18, required by the decoder dependency.
- The decoder dependencies' tvOS simulator binaries support arm64 only; Intel/x86_64 tvOS simulator builds are unsupported.
- APAC encoding requires tvOS 26 or later, independently of the app minimum.

The existing preference storage key is retained, including enabled preferences synced between
profiles/devices. Its visible wording now covers both formats, with English fallback text in
all supported locales. DTS-HD MA without a DTS:X presentation keeps the ordinary audio bridge.

On tvOS, the upstream `AtmosOutputActivator` plays a bundled digital-silence E-AC-3 Atmos
stream alongside APAC to activate Atmos output on sinks that require it. Upstream verified
this on a Samsung HW-Q990C. This does not establish playback or audible improvement on
every Samsung TV or soundbar, including an S95B using only its built-in speakers.

## Listening report

The contributor reports that an earlier personal Nuvio 3.4.2 build using these
AetherEngine 7.34.x versions and the same fixed 9.1.6 configuration worked “amazingly well”
with locally streamed TrueHD Atmos movies on an Apple TV 4K (3rd generation),
tvOS 27, and a Sonos surround system. That was a personal build with the option
always enabled, not the new settings UI. This is a subjective listening report,
not a measurement of object accuracy, losslessness, or universal compatibility.

Credit for the renderer/encoder implementation belongs to AetherEngine and its
upstream contributors, including the Silo implementation credited in AetherEngine's
7.34.0 release notes. LibTrueHD packages the TrueHD Rust decoder; LibDTSX packages the
`dca` decoder. This contribution
updates Nuvio's integration and adds its persisted opt-in control.
