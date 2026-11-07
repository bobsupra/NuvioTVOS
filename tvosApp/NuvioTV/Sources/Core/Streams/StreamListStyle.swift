import CoreGraphics
import Foundation

/// How the list of sources looks when an episode or a film is opened (Settings → Playback →
/// Stream List, an editor with a live preview): the size of the text, of the details under the
/// name, of the badges and the add-on logo, the cards and the space in them, how wide and how
/// tall the list is, and how much of a stream's name and description shows before it is cut.
/// The defaults are the list as it was.
struct StreamListStyle: Equatable {
    enum CardSize: String, CaseIterable {
        case compact
        case standard = "default"
        case large

        var label: String {
            switch self {
            case .compact: return "Compact"
            case .standard: return "Default"
            case .large: return "Large"
            }
        }
    }

    enum Width: String, CaseIterable {
        case standard = "default"
        case wide
        case full

        var label: String {
            switch self {
            case .standard: return "Default"
            case .wide: return "Wide"
            case .full: return "Full"
            }
        }
    }

    enum Height: String, CaseIterable {
        case standard = "default"
        case tall
        case full

        var label: String {
            switch self {
            case .standard: return "Default"
            case .tall: return "Tall"
            case .full: return "Full"
            }
        }
    }

    /// Smaller, as it is, or larger: the details, the badges, the add-on logo.
    enum Step: String, CaseIterable {
        case small
        case standard = "default"
        case large

        var label: String {
            switch self {
            case .small: return "Small"
            case .standard: return "Default"
            case .large: return "Large"
            }
        }
    }

    enum Spacing: String, CaseIterable {
        case tight
        case standard = "default"
        case loose

        var label: String {
            switch self {
            case .tight: return "Tight"
            case .standard: return "Default"
            case .loose: return "Loose"
            }
        }

        var factor: CGFloat {
            switch self {
            case .tight: return 0.5
            case .standard: return 1
            case .loose: return 1.6
            }
        }
    }

    /// Spacing of the cards and around them, in points.
    struct Metrics: Equatable {
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var minHeight: CGFloat
        var cardSpacing: CGFloat
        var lineSpacing: CGFloat
        var panelPadding: CGFloat
        var logoSize: CGFloat
    }

    /// Where the summary (logo, episode) and the list go on the screen.
    struct Layout: Equatable {
        var summaryWidth: CGFloat
        var panelWidth: CGFloat
        var panelHeight: CGFloat
        /// The filters, the episode line when shown, and the list.
        var stackHeight: CGFloat
        var stackSpacing: CGFloat
        var showsSummary: Bool
        var showsHeader: Bool
    }

    static let textScales = [50, 60, 70, 80, 90, 100, 115, 130, 150]
    static let nameLineChoices = [2, 0]
    static let descriptionLineChoices = [3, 6, 10, 0]
    static let filterRowHeight: CGFloat = 90
    static let headerHeight: CGFloat = 112

    /// Text size in percent of the default.
    var textScale: Int = 100
    /// The description (file name and details) against the name.
    var detailSize: Step = .standard
    var badgeSize: Step = .standard
    var logoSize: Step = .standard
    var cardSize: CardSize = .standard
    var spacing: Spacing = .standard
    var width: Width = .standard
    var height: Height = .standard
    /// Lines of the name and of the description before they are cut; nil shows all.
    var nameLines: Int? = 2
    var descriptionLines: Int? = 6
    /// With the full width, the logo and the episode go above the list.
    var episodeHeader = true
    /// The focused card shows its whole name and description.
    var expandFocused = false

    init() {}

    init(
        textScale: Int,
        cardSize: String,
        width: String,
        nameLines: Int,
        descriptionLines: Int,
        episodeHeader: Bool,
        expandFocused: Bool,
        detailSize: String = Step.standard.rawValue,
        badgeSize: String = Step.standard.rawValue,
        logoSize: String = Step.standard.rawValue,
        spacing: String = Spacing.standard.rawValue,
        height: String = Height.standard.rawValue
    ) {
        self.textScale = Self.textScales.contains(textScale) ? textScale : 100
        self.cardSize = CardSize(rawValue: cardSize) ?? .standard
        self.width = Width(rawValue: width) ?? .standard
        self.nameLines = nameLines > 0 ? nameLines : nil
        self.descriptionLines = descriptionLines > 0 ? descriptionLines : nil
        self.episodeHeader = episodeHeader
        self.expandFocused = expandFocused
        self.detailSize = Step(rawValue: detailSize) ?? .standard
        self.badgeSize = Step(rawValue: badgeSize) ?? .standard
        self.logoSize = Step(rawValue: logoSize) ?? .standard
        self.spacing = Spacing(rawValue: spacing) ?? .standard
        self.height = Height(rawValue: height) ?? .standard
    }

    static func current(in settings: UserDefaults = ProfileSettings.current) -> StreamListStyle {
        func int(_ key: String, _ fallback: Int) -> Int {
            settings.object(forKey: key) == nil ? fallback : settings.integer(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            settings.object(forKey: key) == nil ? fallback : settings.bool(forKey: key)
        }
        func string(_ key: String) -> String {
            settings.string(forKey: key) ?? "default"
        }
        return StreamListStyle(
            textScale: int(SettingsKey.streamListTextScale, 100),
            cardSize: string(SettingsKey.streamListCardSize),
            width: string(SettingsKey.streamListWidth),
            nameLines: int(SettingsKey.streamListNameLines, 2),
            descriptionLines: int(SettingsKey.streamListDescriptionLines, 6),
            episodeHeader: bool(SettingsKey.streamListEpisodeHeader, true),
            expandFocused: bool(SettingsKey.streamListExpandFocused, false),
            detailSize: string(SettingsKey.streamListDetailSize),
            badgeSize: string(SettingsKey.streamListBadgeSize),
            logoSize: string(SettingsKey.streamListLogoSize),
            spacing: string(SettingsKey.streamListSpacing),
            height: string(SettingsKey.streamListHeight))
    }

    // MARK: Sizes

    private var scale: CGFloat { CGFloat(textScale) / 100 }

    private static func factor(_ step: Step, small: CGFloat, large: CGFloat) -> CGFloat {
        switch step {
        case .small: return small
        case .standard: return 1
        case .large: return large
        }
    }

    /// A text size of the list at this style's scale.
    func font(_ size: CGFloat) -> CGFloat {
        (size * scale).rounded()
    }

    /// The description's text size (it follows the text size, and its own step).
    func detailFont(_ size: CGFloat) -> CGFloat {
        (size * scale * Self.factor(detailSize, small: 0.85, large: 1.15)).rounded()
    }

    /// How much larger than at the default the badges are drawn.
    var badgeScale: CGFloat {
        scale * Self.factor(badgeSize, small: 0.8, large: 1.25)
    }

    /// The description's space between lines.
    var detailLineSpacing: CGFloat {
        5 * spacing.factor
    }

    var metrics: Metrics {
        var metrics: Metrics
        switch cardSize {
        case .compact:
            metrics = Metrics(horizontalPadding: 24, verticalPadding: 18, minHeight: 0,
                              cardSpacing: 14, lineSpacing: 8, panelPadding: 28, logoSize: 72)
        case .standard:
            metrics = Metrics(horizontalPadding: 36, verticalPadding: 34, minHeight: 250,
                              cardSpacing: 28, lineSpacing: 14, panelPadding: 40, logoSize: 96)
        case .large:
            metrics = Metrics(horizontalPadding: 44, verticalPadding: 40, minHeight: 290,
                              cardSpacing: 32, lineSpacing: 16, panelPadding: 44, logoSize: 96)
        }
        metrics.lineSpacing = (metrics.lineSpacing * spacing.factor).rounded()
        metrics.logoSize = (metrics.logoSize * Self.factor(logoSize, small: 0.7, large: 1.35)).rounded()
        return metrics
    }

    /// The summary on the left and the list on the right of a `width` × `height` screen. The
    /// default is the list as it was; wide narrows the summary; full leaves it out, and the
    /// episode then goes above the list when `episodeHeader` is on. Tall and full heights use
    /// more of the screen's height.
    func layout(width canvasWidth: CGFloat, height canvasHeight: CGFloat) -> Layout {
        let standardSummary = min(canvasWidth * 0.34, 620)
        let showsHeader = width == .full && episodeHeader
        let stackSpacing: CGFloat = showsHeader ? 20 : 28
        let above = showsHeader
            ? Self.filterRowHeight + Self.headerHeight + 2 * stackSpacing
            : Self.filterRowHeight + stackSpacing
        // The most the list can take: the screen less 44 above and below, and what is above it.
        let room = max(canvasHeight - 88 - above, 360)
        let panelHeight: CGFloat
        switch height {
        case .standard: panelHeight = min(min(max(canvasHeight - 300, 440), 720), room)
        case .tall: panelHeight = min(820, room)
        case .full: panelHeight = room
        }
        let stackHeight = panelHeight + above

        switch width {
        case .standard:
            return Layout(
                summaryWidth: standardSummary, panelWidth: min(canvasWidth * 0.56, 1_080),
                panelHeight: panelHeight, stackHeight: stackHeight, stackSpacing: stackSpacing,
                showsSummary: true, showsHeader: false)
        case .wide:
            let panelWidth = min(canvasWidth * 0.70, 1_344)
            // The rest, less the margins (96 left, 64 right) and a gap of 40.
            let summaryWidth = max(min(standardSummary, canvasWidth - panelWidth - 200), 0)
            return Layout(
                summaryWidth: summaryWidth, panelWidth: panelWidth,
                panelHeight: panelHeight, stackHeight: stackHeight, stackSpacing: stackSpacing,
                showsSummary: summaryWidth >= 240, showsHeader: false)
        case .full:
            return Layout(
                summaryWidth: 0, panelWidth: max(canvasWidth - 128, 0),
                panelHeight: panelHeight, stackHeight: stackHeight, stackSpacing: stackSpacing,
                showsSummary: false, showsHeader: showsHeader)
        }
    }

    // MARK: Settings

    static func textScaleLabel(_ percent: Int) -> String { "\(percent) %" }

    static func textScale(fromLabel label: String) -> Int {
        Int(label.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 100
    }

    static func linesLabel(_ lines: Int) -> String { lines > 0 ? "\(lines)" : "All" }

    static func lines(fromLabel label: String) -> Int { Int(label) ?? 0 }

    /// One line for the Stream List entry in Settings.
    var summary: String {
        var parts = ["Text \(Self.textScaleLabel(textScale))", "\(cardSize.label) cards", "\(width.label) width"]
        if height != .standard { parts.append("\(height.label) height") }
        return parts.joined(separator: " · ")
    }
}
