//
//  RatingBadge.swift
//  NuvioTV
//
//  Rating badge and certification badge components
//

import SwiftUI

struct RatingBadge: View {
    let rating: Double
    let maxRating: Double

    init(rating: Double, maxRating: Double = 10.0) {
        self.rating = rating
        self.maxRating = maxRating
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.0))
                .font(.system(size: 14))

            Text(String(format: "%.1f", rating))
                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.0))
                .font(.callout)
                .fontWeight(.semibold)

            Text("/ \(Int(maxRating))")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.72, blue: 0.0).opacity(0.2))
        )
    }
}

struct CertificationBadge: View {
    let certification: String

    var body: some View {
        Text(certification)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.3))
            )
    }
}
