// Theme.swift
//
// Presentation layer for the app shell: the "Set List" design system — jewel tones on warm
// cream, Archivo type, ink pill chrome — plus display helpers on the Kit's public types and
// a couple of small shared views. No Kit API is invented here — everything is a computed
// convenience over the existing public surface (Task 1 contract).

import SwiftUI
import SwiftData
import TikTokBrainKit

/// `Category` (the Kit enum) collides with the Objective-C runtime's `Category` typedef that
/// Foundation imports. A module-local typealias shadows the Clang import so unqualified
/// `Category` unambiguously means the Kit type everywhere in the app target.
typealias Category = TikTokBrainKit.Category

// MARK: - Color palette (Set List handoff)

extension Color {
    /// Hex convenience, e.g. `Color(hex: 0xC43A26)`.
    init(hex: UInt) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    /// Adaptive color: one hex for light, a brightened/darkened one for dark mode.
    init(light: UInt, dark: UInt) {
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    // Category jewel tones (brightened on dark).
    static let categoryRecipe = Color(light: 0xC43A26, dark: 0xDD4E33)   // brick red
    static let categoryFitness = Color(light: 0xE0661F, dark: 0xF27C35)  // orange
    static let categoryStyle = Color(light: 0xC0367F, dark: 0xDB4F98)    // magenta
    static let categoryTravel = Color(light: 0x1C8AA8, dark: 0x30A7C6)   // teal
    static let categoryHome = Color(light: 0x6F8A1E, dark: 0x88A63A)     // olive
    static let categoryLearning = Color(light: 0x5A3EC0, dark: 0x745AE0) // indigo
    static let categoryComedy = Color(light: 0x9B2FC4, dark: 0xB44CDE)   // purple
    static let categoryMusic = Color(light: 0x2743C7, dark: 0x4A63E7)    // cobalt
    static let categoryCoding = Color(light: 0x1A6F52, dark: 0x2A9271)   // forest green
    static let categoryOther = Color(light: 0xC98A12, dark: 0xC98A12)    // amber

    // Chrome.
    static let stashBackground = Color(light: 0xF3ECDB, dark: 0x191408) // warm cream / near-black
    static let stashSurface = Color(light: 0xF7F1E1, dark: 0x241D0F)    // raised fields
    static let stashInk = Color(light: 0x201A12, dark: 0xF1E8D2)        // primary text + tab bar
    static let stashOnInk = Color(light: 0xF7F1E1, dark: 0x201A12)      // text on the ink pill
    static let stashOnAccent = Color(light: 0xF7F1E1, dark: 0x1D0E06)   // text on jewel cards
}

// MARK: - Type (Archivo)

extension Font {
    /// Archivo at an explicit size; weights map onto the five bundled static faces.
    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom(Font.archivoName(weight), size: size)
    }

    static func archivoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .black: "Archivo-Black"
        case .heavy: "Archivo-ExtraBold"
        case .bold: "Archivo-Bold"
        case .semibold: "Archivo-SemiBold"
        default: "Archivo-Medium"
        }
    }
}

/// An uppercase Archivo micro-label with wide tracking — the design's smallest voice.
struct Micro: View {
    let text: String
    var size: CGFloat = 10
    var tracking: CGFloat = 1.6
    var color: Color = .stashInk.opacity(0.45)

    var body: some View {
        Text(text.uppercased())
            .font(.archivo(size, .heavy))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

/// The standard screen header: the STASH wordmark row plus a big Archivo title.
struct StashHeader: View {
    var title: String
    var trailing: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Micro(text: "STASH", size: 11, tracking: 3.4, color: .stashInk)
                Spacer()
                if !trailing.isEmpty {
                    Micro(text: trailing, size: 11, tracking: 1.4, color: .stashInk.opacity(0.5))
                }
            }
            Text(title)
                .font(.archivo(40, .heavy))
                .foregroundStyle(Color.stashInk)
        }
    }
}

/// A full-width solid-ink pill — the design's single primary action.
struct StashPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title.uppercased())
                    .font(.archivo(13, .heavy))
                    .tracking(0.8)
            }
            .foregroundStyle(Color.stashOnInk)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.stashInk, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The design's card container: 18pt radius, either a jewel fill or a 1.5pt ink outline.
extension View {
    func stashCard(fill: Color) -> some View {
        padding(18)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func stashOutlineCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.stashInk.opacity(0.9), lineWidth: 1.5)
            )
    }
}

// MARK: - Category display

extension Category {
    /// The library segment title.
    var displayName: String {
        switch self {
        case .recipe: "Recipes"
        case .fitness: "Fitness"
        case .style: "Style"
        case .travel: "Travel"
        case .home: "Home & DIY"
        case .learning: "Learning"
        case .comedy: "Comedy"
        case .music: "Music"
        case .coding: "Tech"
        case .other: "Other"
        }
    }

    /// Singular form used on badges.
    var singular: String {
        switch self {
        case .recipe: "Recipe"
        case .fitness: "Fitness"
        case .style: "Style"
        case .travel: "Travel"
        case .home: "Home"
        case .learning: "Learning"
        case .comedy: "Comedy"
        case .music: "Music"
        case .coding: "Tech"
        case .other: "Other"
        }
    }

    var color: Color {
        switch self {
        case .recipe: .categoryRecipe
        case .fitness: .categoryFitness
        case .style: .categoryStyle
        case .travel: .categoryTravel
        case .home: .categoryHome
        case .learning: .categoryLearning
        case .comedy: .categoryComedy
        case .music: .categoryMusic
        case .coding: .categoryCoding
        case .other: .categoryOther
        }
    }

    var symbol: String {
        switch self {
        case .recipe: "fork.knife"
        case .fitness: "dumbbell.fill"
        case .style: "bag.fill"
        case .travel: "airplane"
        case .home: "house.fill"
        case .learning: "graduationcap.fill"
        case .comedy: "theatermasks.fill"
        case .music: "music.note"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .other: "sparkles"
        }
    }
}

/// The library segments, in tab order.
let librarySegments: [Category] = [
    .recipe, .fitness, .style, .travel, .home, .learning, .comedy, .music, .coding, .other,
]

// MARK: - Stage state display

extension StageState {
    var symbol: String {
        switch self {
        case .pending: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .awaitingBox: "wifi.exclamationmark"
        case .skipped: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .stashInk.opacity(0.4)
        case .running: .categoryOther
        case .done: .categoryCoding
        case .failed: .categoryRecipe
        case .awaitingBox: .categoryOther
        case .skipped: .stashInk.opacity(0.4)
        }
    }

    var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .awaitingBox: "Awaiting box"
        case .skipped: "Skipped"
        }
    }
}

/// Pipeline stage order, matching the keys `Video` seeds into `stageStatesJSON`.
let pipelineStageOrder = ["enrich", "media", "transcribe", "ocr", "analyze"]

// MARK: - Video view helpers

extension Video {
    /// Decoded category, or `nil` until analysis has run.
    var category: Category? { Category(rawValue: categoryRaw) }

    /// Videos that failed extraction or have not been classified yet — the
    /// "needs a look" pile shown at the end of each library segment.
    var needsLook: Bool { unavailable || categoryRaw.isEmpty }

    var recipe: RecipeData? { Self.decode(recipeJSON, as: RecipeData.self) }
    var track: TrackData? { Self.decode(trackJSON, as: TrackData.self) }
    var codeNote: CodeData? { Self.decode(codeJSON, as: CodeData.self) }

    var stageStates: [String: StageState] {
        (try? JSONDecoder().decode([String: StageState].self, from: stageStatesJSON)) ?? [:]
    }

    /// A short line for list rows: the caption, falling back to author or the id.
    var subtitle: String {
        if !caption.isEmpty { return caption }
        if !author.isEmpty { return "@\(author)" }
        return videoID
    }

    /// The best display title for a row, honoring the category payload.
    var rowTitle: String {
        if let recipe, !recipe.name.isEmpty { return recipe.name }
        if let track, !track.title.isEmpty { return track.title }
        if !title.isEmpty { return title }
        return subtitle
    }

    /// A one-line meta string for rows ("5 ingredients · 4 steps", "M83 · synthwave"…).
    var rowMeta: String {
        if let recipe { return "\(recipe.ingredients.count) ingredients · \(recipe.steps.count) steps" }
        if let track {
            let tag = topics.first.map { " · \($0)" } ?? ""
            return track.artist + tag
        }
        if let codeNote, !codeNote.techTags.isEmpty {
            return codeNote.techTags.prefix(3).joined(separator: " · ")
        }
        if !author.isEmpty { return "@\(author)" }
        return topics.prefix(2).joined(separator: " · ")
    }

    /// Clears prior results and re-arms every stage so the pipeline reprocesses this video.
    func resetStagesToPending() {
        let pending: [String: StageState] = [
            "enrich": .pending, "media": .pending, "transcribe": .pending, "ocr": .pending, "analyze": .pending,
        ]
        stageStatesJSON = (try? JSONEncoder().encode(pending)) ?? stageStatesJSON
        unavailable = false
    }

    private static func decode<T: Decodable>(_ data: Data?, as type: T.Type) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Shared views

/// A rounded thumbnail; the placeholder is now a solid jewel tile with a cream symbol,
/// matching the Set List row tiles (offline-safe).
struct Thumbnail: View {
    let url: URL?
    let category: Category?
    var size: CGFloat = 44

    var body: some View {
        let tint = category?.color ?? Color.stashInk.opacity(0.35)
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                tint
                Image(systemName: category?.symbol ?? "photo")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Color.stashOnAccent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A small pill showing the category color and name.
struct CategoryBadge: View {
    let category: Category

    var body: some View {
        Micro(text: category.singular, size: 10, tracking: 1.8, color: .stashOnAccent)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(category.color, in: Capsule())
    }
}

/// A thin outlined capsule chip — an icon plus an uppercase micro label — used for
/// reassurance and sync-status lines (e.g. the connect flow).
struct InfoChip: View {
    let text: String
    let systemImage: String
    var tint: Color = .stashInk

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
            Micro(text: text, size: 10, tracking: 1.4, color: tint)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().strokeBorder(tint, lineWidth: 1.5))
    }
}
