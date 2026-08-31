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
                    Text(L10n.string("details_watch_now", fallback: "Watch Now"))
                }
                .frame(height: 56)
                .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(L10n.string("details_watch_now", fallback: "Watch Now"))
            .accessibilityHint(L10n.string("details_play_hint", fallback: "Starts playback"))

            Button(action: onWatchlistClick) {
                HStack(spacing: 8) {
                    Image(systemName: isInWatchlist ? "checkmark" : "plus")
                        .accessibilityHidden(true)
                    Text(isInWatchlist
                        ? L10n.string("details_in_library", fallback: "In Library")
                        : L10n.string("details_library", fallback: "Library"))
                }
                .frame(height: 56)
                .padding(.horizontal, 20)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isInWatchlist
                ? L10n.string("details_in_library", fallback: "In library")
                : L10n.string("details_add_to_library", fallback: "Add to library"))
            .accessibilityHint(isInWatchlist
                ? L10n.string("details_remove_from_library_hint", fallback: "Removes this title from your library")
                : L10n.string("details_add_to_library_hint", fallback: "Adds this title to your library"))

            Button(action: onWatchedClick) {
                Image(systemName: isWatched ? "eye.fill" : "eye.slash.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isWatched
                ? L10n.string("details_watched", fallback: "Watched")
                : L10n.string("details_not_watched", fallback: "Not watched"))
            .accessibilityHint(isWatched
                ? L10n.string("details_mark_unwatched_hint", fallback: "Marks this title as unwatched")
                : L10n.string("details_mark_watched_hint", fallback: "Marks this title as watched"))

            Button(action: onShareClick) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("action_share", fallback: "Share"))
            .accessibilityHint(L10n.string("details_share_hint", fallback: "Shares this title"))
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
                    Text(L10n.string("details_watch_now", fallback: "Watch Now"))
                        .font(.title3)
                }
                .frame(height: 64)
                .padding(.horizontal, 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(L10n.string("details_watch_now", fallback: "Watch Now"))
            .accessibilityHint(L10n.string("details_play_hint", fallback: "Starts playback"))

            Button(action: onWatchlistClick) {
                HStack(spacing: 12) {
                    Image(systemName: isInWatchlist ? "checkmark" : "plus")
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                    Text(isInWatchlist
                        ? L10n.string("details_in_library", fallback: "In Library")
                        : L10n.string("details_library", fallback: "Library"))
                        .font(.title3)
                }
                .frame(height: 64)
                .padding(.horizontal, 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isInWatchlist
                ? L10n.string("details_in_library", fallback: "In library")
                : L10n.string("details_add_to_library", fallback: "Add to library"))
            .accessibilityHint(isInWatchlist
                ? L10n.string("details_remove_from_library_hint", fallback: "Removes this title from your library")
                : L10n.string("details_add_to_library_hint", fallback: "Adds this title to your library"))

            Button(action: onWatchedClick) {
                HStack(spacing: 12) {
                    Image(systemName: isWatched ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                    Text(isWatched
                        ? L10n.string("details_watched", fallback: "Watched")
                        : L10n.string("details_unwatched", fallback: "Unwatched"))
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                .frame(height: 64)
                .padding(.horizontal, 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isWatched
                ? L10n.string("details_watched", fallback: "Watched")
                : L10n.string("details_not_watched", fallback: "Not watched"))
            .accessibilityHint(isWatched
                ? L10n.string("details_mark_unwatched_hint", fallback: "Marks this title as unwatched")
                : L10n.string("details_mark_watched_hint", fallback: "Marks this title as watched"))

            Button(action: onShareClick) {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                    Text(L10n.string("action_share", fallback: "Share"))
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                .frame(height: 64)
                .padding(.horizontal, 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L10n.string("action_share", fallback: "Share"))
            .accessibilityHint(L10n.string("details_share_hint", fallback: "Shares this title"))
        }
    }
}
