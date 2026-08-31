//
//  CastCrewSection.swift
//  NuvioTV
//
//  Cast and crew display section for content details
//

import SwiftUI

struct CastCrewSection: View {
    let cast: [String]?
    let director: [String]?
    let writer: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let cast = cast, !cast.isEmpty {
                CastList(title: L10n.string("details_cast", fallback: "Cast"), names: cast)
            }

            if let director = director, !director.isEmpty {
                CrewList(title: L10n.string("details_director", fallback: "Director"), names: director)
            }

            if let writer = writer, !writer.isEmpty {
                CrewList(title: L10n.string("details_writer", fallback: "Writer"), names: writer)
            }
        }
    }
}

struct CastList: View {
    let title: String
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(names.prefix(10)), id: \.self) { name in
                        CastCard(name: name)
                    }
                }
            }
        }
    }
}

struct CrewList: View {
    let title: String
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text(names.joined(separator: ", "))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

struct CastCard: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Placeholder for actor image
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 120, height: 160)

            Text(name)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(width: 120)
        }
    }
}
