import SwiftUI

/// Draws add-on stream text with SF Symbols in place of the emoji that
/// formatters such as AIOStreams use as line markers (🎬, 🔊, 🌐, 📝, ⚡…).
/// Symbols take the surrounding font and color, so a card reads like system
/// UI. Emoji without a mapping (flags, for example) are left as they are.
/// Off by default: Settings > Layout > Stream List > Symbols Instead of Emoji.
enum StreamSymbolText {
    static let symbols: [String: String] = [
        "🎬": "film",
        "🎞": "film.stack",
        "🎥": "video.fill",
        "📹": "video.fill",
        "📺": "tv",
        "🖥": "display",
        "🔊": "speaker.wave.2.fill",
        "🔉": "speaker.wave.1.fill",
        "🔈": "speaker.fill",
        "🎧": "headphones",
        "🎵": "music.note",
        "🗣": "waveform",
        "🌐": "globe",
        "🌍": "globe",
        "🌎": "globe",
        "🌏": "globe",
        "📝": "captions.bubble",
        "💬": "captions.bubble",
        "📦": "shippingbox",
        "💾": "internaldrive",
        "📁": "folder",
        "📄": "doc",
        "⚡": "bolt.fill",
        "🚀": "bolt.fill",
        "⏳": "hourglass",
        "⌛": "hourglass",
        "⏱": "timer",
        "🕒": "clock",
        "📅": "calendar",
        "👤": "person.fill",
        "👥": "person.2.fill",
        "🌱": "leaf",
        "🏷": "tag",
        "🔍": "magnifyingglass",
        "🔎": "magnifyingglass",
        "☁": "cloud",
        "🔗": "link",
        "🧲": "link",
        "📡": "antenna.radiowaves.left.and.right",
        "🔒": "lock.fill",
        "🔓": "lock.open",
        "✅": "checkmark.circle.fill",
        "✔": "checkmark",
        "❌": "xmark.circle",
        "⭐": "star.fill",
        "🌟": "star.fill",
        "🔥": "flame",
        "📊": "chart.bar",
        "🎚": "slider.horizontal.3",
        "⚙": "gearshape",
        "🎯": "scope",
        "ℹ": "info.circle"
    ]

    /// `Text` for `string`; with `symbols` on, mapped emoji become inline symbols.
    static func text(_ string: String, symbols: Bool) -> Text {
        symbols ? text(string) : Text(verbatim: string)
    }

    /// `Text` for `string`, with mapped emoji replaced by inline symbols.
    static func text(_ string: String) -> Text {
        var result = Text(verbatim: "")
        var pending = ""
        for character in string {
            let key = String(String.UnicodeScalarView(
                character.unicodeScalars.filter { $0.value != 0xFE0F && $0.value != 0xFE0E }
            ))
            if let symbol = symbols[key] {
                if !pending.isEmpty {
                    result = result + Text(verbatim: pending)
                    pending = ""
                }
                result = result + Text(Image(systemName: symbol))
            } else {
                pending.append(character)
            }
        }
        if !pending.isEmpty {
            result = result + Text(verbatim: pending)
        }
        return result
    }
}
