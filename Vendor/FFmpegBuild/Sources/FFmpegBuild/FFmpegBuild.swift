// FFmpegBuild: Minimal FFmpeg for Apple platforms.
//
// This is a thin wrapper target that links the prebuilt xcframeworks
// (AetherLibavcodec, AetherLibavformat, AetherLibavutil, AetherLibswresample) together with
// the required system frameworks (VideoToolbox, AudioToolbox, etc).
//
// The xcframeworks are built by build.sh from FFmpeg source with a
// minimal configuration: only demuxing + decoding, no network/TLS,
// no encoders, no filters, no programs.
//
// Usage: import FFmpegBuild (or the individual AetherLib* modules)
import Foundation
