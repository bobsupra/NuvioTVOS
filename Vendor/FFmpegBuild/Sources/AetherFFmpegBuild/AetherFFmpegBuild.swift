// AetherFFmpegBuild: Minimal FFmpeg for Apple platforms.
//
// This is a thin wrapper target that links the prebuilt xcframeworks
// (AetherLibavcodec, AetherLibavformat, AetherLibavutil, AetherLibswresample)
// together with the required system frameworks (VideoToolbox, AudioToolbox, etc).
//
// The xcframeworks are built by build.sh from FFmpeg source with a
// minimal configuration: only demuxing + decoding, no network/TLS,
// no encoders, no filters, no programs.
//
// The Aether prefix is what lets this build coexist with another FFmpeg in
// the same app (FFmpegKit, MobileVLCKit, mpv): SwiftPM target names and
// framework install names are both graph-wide unique.
//
// Usage: import AetherFFmpegBuild (or the individual AetherLibav* modules)
import Foundation
