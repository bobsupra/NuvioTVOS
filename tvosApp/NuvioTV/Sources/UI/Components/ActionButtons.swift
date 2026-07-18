//
//  ActionButtons.swift
//  NuvioTV
//
//  Action buttons for content details (play, library/watchlist, watched, share).
//  Mobile/preview helpers — production tvOS details uses TvDetailsActionRow.
//

import SwiftUI

struct ActionButtons: View {
    let onPlayClick: () -> Void
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onShareClick: () -> Void
    let isInWatchlist: Bool
    var isWatched: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onPlayClick) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .accessibilityHidden(true)
                    Text("Watch Now")
                }
                .frame(height: 56)
                .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Watch Now")
            .accessibilityHint("Starts playback")

            Button(action: onWatchlistClick) {
                HStack(spacing: 8) {
                    Image(systemName: isInWatchlist ? "checkmark" : "plus")
                        .accessibilityHidden(true)
                    Text(isInWatchlist ? "In Library" : "Library")
                }
                .frame(height: 56)
                .padding(.horizontal, 20)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isInWatchlist ? "In library" : "Add to library")
            .accessibilityHint(isInWatchlist
                ? "Removes this title from your library"
                : "Adds this title to your library")

            Button(action: onWatchedClick) {
                Image(systemName: isWatched ? "eye.fill" : "eye.slash.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isWatched ? "Watched" : "Not watched")
            .accessibilityHint(isWatched
                ? "Marks this title as unwatched"
                : "Marks this title as watched")

            Button(action: onShareClick) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")
            .accessibilityHint("Shares this title")
        }
    }
}

struct TvActionButtons: View {
    let onPlayClick: () -> Void
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onShareClick: () -> Void
    let isInWatchlist: Bool
    var isWatched: Bool = false

    var body: some View {
        HStack(spacing: 24) {
            Button(action: onPlayClick) {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24))
                        .accessibilityHidden(true)
                    Text("Watch Now")
                        .font(.title3)
                }
                .frame(height: 64)
                .padding(.horizontal, 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Watch Now")
            .accessibilityHint("Starts playback")

            Button(action: onWatchlistClick) {
                HStack(spacing: 12) {
                    Image(systemName: isInWatchlist ? "checkmark" : "plus")
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                    Text(isInWatchlist ? "In Library" : "Library")
                        .font(.title3)
                }
                .frame(height: 64)
                .padding(.horizontal, 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isInWatchlist ? "In library" : "Add to library")
            .accessibilityHint(isInWatchlist
                ? "Removes this title from your library"
                : "Adds this title to your library")

            Button(action: onWatchedClick) {
                HStack(spacing: 12) {
                    Image(systemName: isWatched ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                    Text(isWatched ? "Watched" : "Unwatched")
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                .frame(height: 64)
                .padding(.horizontal, 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isWatched ? "Watched" : "Not watched")
            .accessibilityHint(isWatched
                ? "Marks this title as unwatched"
                : "Marks this title as watched")

            Button(action: onShareClick) {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                    Text("Share")
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                .frame(height: 64)
                .padding(.horizontal, 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Share")
            .accessibilityHint("Shares this title")
        }
    }
}
