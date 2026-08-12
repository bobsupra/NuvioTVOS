//
//  MetadataInfo.swift
//  NuvioTV
//
//  Metadata info display component for content details
//

import SwiftUI

struct MetadataInfo: View {
    let meta: NuvioMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text(meta.name)
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            // Info row: Year, Runtime, Certification, Rating
            HStack(spacing: 16) {
                if let year = meta.year {
                    Text("\(year)")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                if let runtime = NuvioRuntimeDisplay.formatted(meta.runtime) {
                    Text(runtime)
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                if let certification = meta.certification {
                    CertificationBadge(certification: certification)
                }

                if let rating = meta.rating {
                    RatingBadge(rating: rating)
                }
            }

            // Genres
            if let genres = meta.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(genres, id: \.self) { genre in
                            GenreChip(genre: genre)
                        }
                    }
                }
            }

            // Description
            if let description = meta.description {
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
            }

            // Additional info
            VStack(alignment: .leading, spacing: 8) {
                if let country = meta.country {
                    InfoRow(label: "Country", value: country)
                }

                if let releaseInfo = meta.releaseInfo {
                    InfoRow(label: "Release", value: NuvioDateDisplay.formattedDate(releaseInfo) ?? releaseInfo)
                }

                if let released = meta.released {
                    InfoRow(label: "Released", value: NuvioDateDisplay.formattedDate(released) ?? released)
                }
            }
        }
    }
}

struct TvMetadataInfo: View {
    let meta: NuvioMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Title with larger typography for TV
            Text(meta.name)
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(.primary)

            // Info row with larger spacing for TV
            HStack(spacing: 24) {
                if let year = meta.year {
                    Text("\(year)")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }

                if let runtime = NuvioRuntimeDisplay.formatted(meta.runtime) {
                    Text(runtime)
                        .font(.title2)
                        .foregroundColor(.secondary)
                }

                if let certification = meta.certification {
                    CertificationBadge(certification: certification)
                }

                if let rating = meta.rating {
                    RatingBadge(rating: rating)
                }
            }

            // Genres
            if let genres = meta.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(genres, id: \.self) { genre in
                            GenreChip(genre: genre)
                        }
                    }
                }
            }

            // Description with larger typography for TV
            if let description = meta.description {
                Text(description)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .lineSpacing(6)
            }

            // Additional info
            VStack(alignment: .leading, spacing: 12) {
                if let country = meta.country {
                    TvInfoRow(label: "Country", value: country)
                }

                if let releaseInfo = meta.releaseInfo {
                    TvInfoRow(label: "Release", value: NuvioDateDisplay.formattedDate(releaseInfo) ?? releaseInfo)
                }

                if let released = meta.released {
                    TvInfoRow(label: "Released", value: NuvioDateDisplay.formattedDate(released) ?? released)
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(label):")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text(value)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

struct TvInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(label):")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text(value)
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }
}

struct GenreChip: View {
    let genre: String

    var body: some View {
        Text(genre.capitalized)
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.2))
            )
    }
}
