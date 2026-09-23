//
//  PlaybackErrorDiagnostic.swift
//  NuvioTV
//
//  Intelligent diagnostics and classification for stream playback failures.
//  Distinguishes upstream hosting/Debrid issues from local network or app issues.
//

import Foundation
import SwiftUI

/// Origin category for a playback failure.
enum PlaybackErrorOrigin: String, CaseIterable, Equatable {
    case hostingProvider = "Stream Provider / Host"
    case network = "Network Connection"
    case compatibility = "Format Compatibility"
    case playerEngine = "Player Engine"
}

/// Structured diagnostic analysis of a playback failure.
struct PlaybackErrorDiagnostic: Equatable {
    let origin: PlaybackErrorOrigin
    let badgeText: String
    let badgeIconName: String
    let title: String
    let message: String
    let suggestedAction: String
    let technicalDetails: String?
    let host: String?

    var isHostingIssue: Bool {
        origin == .hostingProvider
    }

    var isNetworkIssue: Bool {
        origin == .network
    }

    /// Analyzes an error message, stream URL, and metadata to produce a user-friendly diagnostic.
    static func analyze(
        errorMessage: String?,
        streamURL: URL? = nil,
        addonName: String? = nil,
        provider: String? = nil
    ) -> PlaybackErrorDiagnostic {
        let rawError = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = rawError.lowercased()
        let host = extractHost(from: streamURL, rawError: rawError)
        let isRemote = streamURL.map { PlaybackBackendPolicy.isRemoteHTTP($0.absoluteString) } ?? (host != nil)

        // 1. Local Network Disconnection (-1009, ENETDOWN, etc.)
        if lower.contains("connection appears to be offline")
            || lower.contains("not connected to internet")
            || lower.contains("error code: -1009")
            || lower.contains("code=-1009")
            || lower.contains("network connection was lost")
            || lower.contains("code=-1005") {
            return PlaybackErrorDiagnostic(
                origin: .network,
                badgeText: "NO INTERNET CONNECTION",
                badgeIconName: "wifi.slash",
                title: L10n.string("error_network_offline_title", fallback: "Internet Connection Offline"),
                message: L10n.string("error_network_offline_msg", fallback: "Your Apple TV is not connected to the internet. Please check your network settings."),
                suggestedAction: L10n.string("error_network_offline_action", fallback: "Verify your network connection and try again."),
                technicalDetails: rawError.isEmpty ? "Error -1009: Offline" : rawError,
                host: host
            )
        }

        // 2. Remote Host Connection Refused / Server Unreachable (-1004, ECONNREFUSED 61)
        if lower.contains("could not connect to the server")
            || lower.contains("error code: -1004")
            || lower.contains("code=-1004")
            || lower.contains("failed to connect 1:61")
            || lower.contains("econnrefused")
            || lower.contains("connection refused")
            || lower.contains("socket is not connected") {
            let hostLabel = host.map { " (\($0))" } ?? ""
            return PlaybackErrorDiagnostic(
                origin: .hostingProvider,
                badgeText: "STREAM HOST OFFLINE",
                badgeIconName: "server.rack",
                title: L10n.string("error_host_unreachable_title", fallback: "Stream Host Unavailable"),
                message: L10n.string(
                    "error_host_unreachable_msg",
                    fallback: "The remote hosting server\(hostLabel) refused the connection or is offline."
                ),
                suggestedAction: L10n.string("error_host_unreachable_action", fallback: "Try selecting a different stream source or Debrid provider."),
                technicalDetails: formatTechnicalLine(host: host, code: "-1004 (Connection Refused)", raw: rawError),
                host: host
            )
        }

        // 3. HTTP 403 Forbidden / Expired Link / Token
        if lower.contains("403")
            || lower.contains("forbidden")
            || lower.contains("expired")
            || lower.contains("unauthorized")
            || lower.contains("401") {
            return PlaybackErrorDiagnostic(
                origin: .hostingProvider,
                badgeText: "STREAM LINK EXPIRED",
                badgeIconName: "clock.badge.exclamationmark",
                title: L10n.string("error_link_expired_title", fallback: "Stream Link Expired"),
                message: L10n.string("error_link_expired_msg", fallback: "The playback token or link for this stream has expired (HTTP 403)."),
                suggestedAction: L10n.string("error_link_expired_action", fallback: "Go back and select a fresh stream source."),
                technicalDetails: formatTechnicalLine(host: host, code: "HTTP 403 (Forbidden / Token Expired)", raw: rawError),
                host: host
            )
        }

        // 4. HTTP 404 Not Found
        if lower.contains("404") || lower.contains("not found") {
            return PlaybackErrorDiagnostic(
                origin: .hostingProvider,
                badgeText: "FILE NOT FOUND",
                badgeIconName: "doc.badge.ellipsis",
                title: L10n.string("error_not_found_title", fallback: "Stream File Missing"),
                message: L10n.string("error_not_found_msg", fallback: "The media file was removed or not found on the remote server (HTTP 404)."),
                suggestedAction: L10n.string("error_not_found_action", fallback: "Please select an alternative stream source."),
                technicalDetails: formatTechnicalLine(host: host, code: "HTTP 404 (Not Found)", raw: rawError),
                host: host
            )
        }

        // 5. HTTP 500 / 502 / 503 / 504 (Server Outage / Bad Gateway)
        if lower.contains("502") || lower.contains("bad gateway")
            || lower.contains("503") || lower.contains("service unavailable")
            || lower.contains("504") || lower.contains("gateway timeout")
            || lower.contains("500") || lower.contains("internal server error") {
            return PlaybackErrorDiagnostic(
                origin: .hostingProvider,
                badgeText: "HOST SERVER ERROR",
                badgeIconName: "exclamationmark.icloud",
                title: L10n.string("error_server_outage_title", fallback: "Hosting Server Error"),
                message: L10n.string("error_server_outage_msg", fallback: "The stream hosting server returned an error (HTTP 502/503)."),
                suggestedAction: L10n.string("error_server_outage_action", fallback: "Select a different stream source."),
                technicalDetails: formatTechnicalLine(host: host, code: "Server Outage (5xx)", raw: rawError),
                host: host
            )
        }

        // 6. Host Connection Timeout (-1001)
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("code=-1001") || lower.contains("error code: -1001") {
            return PlaybackErrorDiagnostic(
                origin: .hostingProvider,
                badgeText: "HOST TIMED OUT",
                badgeIconName: "hourglass.badge.exclamationmark",
                title: L10n.string("error_host_timeout_title", fallback: "Stream Host Timed Out"),
                message: L10n.string("error_host_timeout_msg", fallback: "The remote stream server took too long to respond."),
                suggestedAction: L10n.string("error_host_timeout_action", fallback: "Choose another stream source."),
                technicalDetails: formatTechnicalLine(host: host, code: "Timeout (-1001)", raw: rawError),
                host: host
            )
        }

        // 7. Simulator AV1 / Incompatible Video Codec
        if lower.contains("av1") || lower.contains("simulator") {
            return PlaybackErrorDiagnostic(
                origin: .compatibility,
                badgeText: "SIMULATOR COMPATIBILITY",
                badgeIconName: "film.trianglebadge.exclamationmark",
                title: L10n.string("error_simulator_av1_title", fallback: "Unsupported Simulator Format"),
                message: L10n.string("error_simulator_av1_msg", fallback: "AV1 video decoding is not supported in the Apple TV Simulator. Choose an H.264 or HEVC stream."),
                suggestedAction: L10n.string("error_simulator_av1_action", fallback: "Select an H.264 or HEVC source."),
                technicalDetails: rawError,
                host: host
            )
        }

        // 8. Corrupt / Empty Stream / Demuxer failure (when connecting to a remote host)
        if (lower.contains("unrecognized file format")
            || lower.contains("invalid data found when processing input")
            || lower.contains("demuxer: open failed")
            || lower.contains("no probe resolved a size")
            || lower.contains("end of file")) && isRemote {
            let hostLabel = host.map { " from \($0)" } ?? ""
            return PlaybackErrorDiagnostic(
                origin: .hostingProvider,
                badgeText: "STREAM UNAVAILABLE",
                badgeIconName: "tray.and.arrow.down.fill",
                title: L10n.string("error_invalid_stream_title", fallback: "Stream Source Invalid"),
                message: L10n.string(
                    "error_invalid_stream_msg",
                    fallback: "The remote hosting server\(hostLabel) returned an empty or invalid stream response."
                ),
                suggestedAction: L10n.string("error_invalid_stream_action", fallback: "Select a different stream source."),
                technicalDetails: formatTechnicalLine(host: host, code: "Demux / Format Error", raw: rawError),
                host: host
            )
        }

        // 9. Internal Player Engine Unavailable
        if lower.contains("aetherengine is unavailable") || lower.contains("unavailable on this device") {
            return PlaybackErrorDiagnostic(
                origin: .playerEngine,
                badgeText: "PLAYER ENGINE",
                badgeIconName: "gearshape.fill",
                title: L10n.string("error_engine_unavailable_title", fallback: "Player Engine Unavailable"),
                message: L10n.string("error_engine_unavailable_msg", fallback: "The selected player engine is not supported on this device."),
                suggestedAction: L10n.string("error_engine_unavailable_action", fallback: "Change default player engine in Settings."),
                technicalDetails: rawError,
                host: host
            )
        }

        // 10. Generic Fallback
        let origin: PlaybackErrorOrigin = isRemote ? .hostingProvider : .playerEngine
        let badge = isRemote ? "STREAM ERROR" : "PLAYBACK ERROR"
        let icon = isRemote ? "server.rack" : "exclamationmark.triangle"
        let fallbackMsg = isRemote
            ? "The remote stream could not be played. Please try another source."
            : "An unexpected error occurred during playback."

        return PlaybackErrorDiagnostic(
            origin: origin,
            badgeText: badge,
            badgeIconName: icon,
            title: L10n.string("player_status_playback_failed", fallback: "Playback Failed"),
            message: rawError.isEmpty ? fallbackMsg : rawError,
            suggestedAction: L10n.string("error_generic_action", fallback: "Try selecting another stream source or provider."),
            technicalDetails: formatTechnicalLine(host: host, code: nil, raw: rawError),
            host: host
        )
    }

    private static func extractHost(from url: URL?, rawError: String) -> String? {
        if let host = url?.host, !host.isEmpty {
            return host
        }
        // Attempt to extract hostname from error strings containing URLs
        if let match = rawError.range(of: #"https?://([^/:\s]+)"#, options: .regularExpression) {
            let urlString = String(rawError[match])
            return URL(string: urlString)?.host
        }
        return nil
    }

    private static func formatTechnicalLine(host: String?, code: String?, raw: String) -> String {
        var parts: [String] = []
        if let host {
            parts.append("Host: \(host)")
        }
        if let code {
            parts.append("Status: \(code)")
        }
        if !raw.isEmpty && !parts.contains(where: { raw.contains($0) }) {
            // Trim down very verbose raw strings
            let clean = raw.components(separatedBy: .newlines).first ?? raw
            if clean.count <= 100 {
                parts.append("Detail: \(clean)")
            }
        }
        return parts.joined(separator: " • ")
    }
}
