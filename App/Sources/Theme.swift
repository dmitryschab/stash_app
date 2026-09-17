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
    static let categoryFilm = Color(light: 0x1F6BA8, dark: 0x3389C6)     // steel blue
    static let categoryDining = Color(light: 0xB02C55, dark: 0xCE4670)   // rose
    static let categoryWellness = Color(light: 0x3F8A3A, dark: 0x55A84F) // grass green
    static let categoryOther = Color(light: 0xC98A12, dark: 0xC98A12)    // amber

    /// Haul's accent. Not a category jewel — Haul is a query across all thirteen, so it takes a
    /// tone none of them uses: tanned leather, the colour of a shop rather than a subject.
    static let stashHaul = Color(light: 0x7A4A22, dark: 0xA9713C)        // saddle tan

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

// MARK: - Shimmer

/// A slow highlight sweep across a placeholder — the app's only loading texture. Static
/// under Reduce Motion: the dimmed block reads as a placeholder without moving.
struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.5) / 1.5
                content.overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: geo.size.width * 1.6 * phase - geo.size.width * 0.6)
                    }
                }
            }
        }
    }
}

/// A shimmering placeholder block, clipped to its rounded shape.
struct ShimmerBlock: View {
    var cornerRadius: CGFloat = 5

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.stashInk.opacity(0.09))
            .modifier(ShimmerModifier())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        case .film: "Film & TV"
        case .dining: "Dining"
        case .wellness: "Wellness"
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
        case .film: "Film"
        case .dining: "Dining"
        case .wellness: "Wellness"
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
        case .film: .categoryFilm
        case .dining: .categoryDining
        case .wellness: .categoryWellness
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
        case .film: "film"
        case .dining: "cup.and.saucer.fill"
        case .wellness: "leaf.fill"
        case .other: "sparkles"
        }
    }
}

/// The library segments, in tab order.
let librarySegments: [Category] = [
    .recipe, .fitness, .style, .travel, .home, .learning, .comedy, .music, .coding,
    .film, .dining, .wellness, .other,
]

/// The Library tab's shelves: every segment whose own tab is not currently on the pill.
///
/// Recipes live on Cook, music on Music and coding on Code, each richer than a list row, so a
/// Library copy of one of those is the same saves a second time. But the pill is configurable
/// now (`TabSlots`), and a category whose tab has been switched off has nowhere else to be —
/// hiding Code must not also hide every coding save in the app.
func libraryShelves(visible: [StashTab]) -> [Category] {
    let spokenFor = Set(visible.compactMap(\.ownedCategory))
    return librarySegments.filter { !spokenFor.contains($0) }
}

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

    /// Saves the pipeline gave up on: gone or private on TikTok, or an analysis that failed.
    /// They leave the Library for Settings › Archive, which retries them.
    var isArchived: Bool { unavailable || (categoryRaw.isEmpty && stageStates.values.contains(.failed)) }

    /// The recipe as the kitchen reads it: US quantities rewritten to metric on the way out
    /// (`Metric.localize`), so saves analyzed before the prompt asked for metric read right too.
    var recipe: RecipeData? {
        guard var recipe = Self.decode(recipeJSON, as: RecipeData.self) else { return nil }
        recipe.ingredients = recipe.ingredients.map(Metric.localize)
        recipe.steps = recipe.steps.map(Metric.localize)
        return recipe
    }
    var codeNote: CodeData? { Self.decode(codeJSON, as: CodeData.self) }

    /// Everything this save is selling, in the order the video presented it. Empty for most
    /// saves and for every save analyzed before `buys` existed — see `BuyPick`.
    var buys: [BuyPick] { Self.decode(buysJSON, as: [BuyPick].self) ?? [] }

    /// Every release this save recommends, in the order the video showed them.
    ///
    /// Falls back to the legacy single `trackJSON` so a library saved before multi-pick
    /// extraction still reads as one pick until the re-analysis pass rewrites it.
    var music: [MusicPick] {
        if let picks = Self.decode(musicJSON, as: [MusicPick].self) { return picks }
        guard let legacy = Self.decode(trackJSON, as: TrackData.self), !legacy.title.isEmpty else {
            return []
        }
        return [MusicPick(kind: .track, title: legacy.title,
                          artist: legacy.artist, link: legacy.universalLink)]
    }

    /// The single pick, when there is exactly one. Nil for a recommendation list — callers that
    /// show one song must not silently show the first of five.
    var soleMusicPick: MusicPick? {
        let picks = music
        return picks.count == 1 ? picks[0] : nil
    }

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
    ///
    /// A recommendation list keeps the video's own title: naming it after the first of five
    /// releases would misrepresent four of them.
    var rowTitle: String {
        if let recipe, !recipe.name.isEmpty { return recipe.name }
        if let pick = soleMusicPick, !pick.title.isEmpty { return pick.title }
        if !title.isEmpty { return title }
        return subtitle
    }

    /// A one-line meta string for rows ("5 ingredients · 4 steps", "M83 · synthwave"…).
    var rowMeta: String {
        if let recipe { return "\(recipe.ingredients.count) ingredients · \(recipe.steps.count) steps" }
        if let pick = soleMusicPick {
            let tag = topics.first.map { " · \($0)" } ?? ""
            return pick.artist + tag
        }
        if music.count > 1 { return "\(music.count) releases" }
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
        .clipped()                           // touch region too, not just the drawing
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// The one empty state every tab shows before anything has been imported: a jewel symbol, a
/// line naming what lands here, and — crucially — the way to fill it. Import is only reachable
/// from the Library header, so a brand-new account landing on Cook or Music would otherwise
/// read a dead end. Each caller must sit inside a `NavigationStack` (all five tabs do).
struct StashEmptyState: View {
    let symbol: String
    var tint: Color = .stashInk.opacity(0.35)
    let title: String
    let message: String
    /// Off when the caller already offers Import a tap away — the Library header has its own
    /// button, and a second one under a half-empty shelf is noise.
    var offersImport = true
    /// Seconds since 1970 when the user told the data guide they asked TikTok for the export;
    /// zero until then. While set, the empty library is a wait, not a dead end.
    @AppStorage(PipelineCenter.exportRequestedKey) private var exportRequestedAt = 0.0

    private var waitingOnTikTok: Bool { offersImport && exportRequestedAt > 0 }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: waitingOnTikTok ? "envelope.badge.clock" : symbol)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(tint)
            Text(waitingOnTikTok ? "Waiting on TikTok" : title)
                .font(.archivo(17, .bold))
                .foregroundStyle(Color.stashInk)
            Text(waitingOnTikTok ? waitingMessage : message)
                .font(.archivo(13))
                .foregroundStyle(Color.stashInk.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            if offersImport {
                NavigationLink { ImportView() } label: {
                    InfoChip(text: "Import your saves", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var waitingMessage: String {
        let requested = Date(timeIntervalSince1970: exportRequestedAt)
            .formatted(.relative(presentation: .named))
        return "You asked for your export \(requested). TikTok emails when it is ready — "
            + "usually within the hour, sometimes a day or two. Then bring the file in here."
    }
}

/// The published policy pages. Guideline 5.1.1(i) wants both reachable from inside the app,
/// so they are linked from the sign-in gate — where continuing *is* the agreement — and again
/// from Settings.
/// ponytail: SignInView spells these two URLs out a second time inside a Markdown string,
/// because `Text` only parses link syntax in literal segments — an interpolated URL renders as
/// plain text. Changing the domain means changing both places.
enum StashLegal {
    static let terms = URL(string: "https://stash.dmitrijs.dev/terms")!
    static let privacy = URL(string: "https://stash.dmitrijs.dev/privacy")!
}

// MARK: - Time rail

/// One month's run of saves. Lists are newest-first, so consecutive grouping is enough.
struct MonthRun<Item>: Identifiable {
    let id: String
    /// Section heading — "MARCH", or "MARCH '24" once the year is not this one.
    let title: String
    let year: Int
    let month: Int
    var items: [Item]
}

/// Groups a newest-first list into month runs.
func monthRuns<Item>(_ items: [Item], date: (Item) -> Date) -> [MonthRun<Item>] {
    let calendar = Calendar.current
    let currentYear = calendar.component(.year, from: Date())
    var out: [MonthRun<Item>] = []
    for item in items {
        let parts = calendar.dateComponents([.year, .month], from: date(item))
        guard let year = parts.year, let month = parts.month else { continue }
        let id = "\(year)-\(month)"
        if out.last?.id != id {
            var title = calendar.monthSymbols[month - 1].uppercased()
            if year != currentYear { title += " '\(String(year % 100))" }
            out.append(MonthRun(id: id, title: title, year: year, month: month, items: []))
        }
        out[out.count - 1].items.append(item)
    }
    return out
}

/// One rail stop: a label and the section id it jumps to.
struct TimeRailEntry: Identifiable {
    let label: String
    let target: String
    var id: String { target }
}

/// Rail stops for a set of month runs: month abbreviations for the current year, then a
/// single year marker per older year, each jumping to that year's newest section.
func timeRailEntries<Item>(for runs: [MonthRun<Item>]) -> [TimeRailEntry] {
    let calendar = Calendar.current
    let currentYear = calendar.component(.year, from: Date())
    var seenYears = Set<Int>()
    var out: [TimeRailEntry] = []
    for run in runs {
        if run.year == currentYear {
            out.append(TimeRailEntry(label: calendar.shortMonthSymbols[run.month - 1].uppercased(), target: run.id))
        } else if !seenYears.contains(run.year) {
            seenYears.insert(run.year)
            out.append(TimeRailEntry(label: "'\(String(run.year % 100))", target: run.id))
        }
    }
    return out
}

/// Right-edge jump rail. Tap a label to jump; press and drag up/down to scrub through
/// months continuously, Contacts-index style. ponytail: no scroll-position sync back into
/// the rail — add only if the highlight feels dead when scrolling.
struct TimeRail: View {
    let entries: [TimeRailEntry]
    let proxy: ScrollViewProxy

    @State private var railHeight: CGFloat = 0
    @State private var scrubTarget: String?
    private let inset: CGFloat = 10

    var body: some View {
        VStack(spacing: 9) {
            ForEach(entries) { entry in
                Button {
                    withAnimation { proxy.scrollTo(destination(of: entry.target), anchor: .top) }
                } label: {
                    Micro(
                        text: entry.label,
                        size: 8.5,
                        tracking: 0.8,
                        color: scrubTarget == entry.target ? .stashInk : .stashInk.opacity(0.55)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, inset)
        .padding(.horizontal, 5)
        .background(Capsule().fill(Color.stashBackground.opacity(0.92)))
        .overlay(Capsule().strokeBorder(Color.stashInk.opacity(0.12), lineWidth: 1))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { railHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in railHeight = new }
            }
        )
        .contentShape(Capsule())
        // High priority: the per-label Buttons otherwise claim the touch and the drag only
        // ever reports its first point. Taps still land — minimumDistance 0 means touch-down
        // alone jumps — and VoiceOver activates the Buttons directly.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let target = target(at: value.location.y), target != scrubTarget else { return }
                    scrubTarget = target
                    proxy.scrollTo(destination(of: target), anchor: .top)
                }
                .onEnded { _ in scrubTarget = nil }
        )
        .sensoryFeedback(.selection, trigger: scrubTarget)
        .padding(.trailing, 4)
    }

    /// The newest stop is the top of the page, header and featured card included — landing
    /// on the first month's label leaves the rest of the way up to the thumb.
    private func destination(of target: String) -> String {
        target == entries.first?.target ? stashSectionTopID : target
    }

    /// Which rail entry sits under a finger `y` points down the rail.
    private func target(at y: CGFloat) -> String? {
        guard !entries.isEmpty, railHeight > inset * 2 else { return nil }
        let slot = (railHeight - inset * 2) / CGFloat(entries.count)
        let index = Int((y - inset) / slot)
        return entries[min(entries.count - 1, max(0, index))].target
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

// MARK: - Pushed-screen navigation

/// The back control on every pushed screen — they all hide the navigation bar, so each
/// draws its own. A bare chevron, no ring, no fill. The 36pt footprint is what the ringed
/// circle it replaced occupied, so header rows keep their height and the glyph its spot;
/// the hit area is widened to the 44pt minimum without changing layout. `tint` is for the
/// one site that sits on a photo (the Cook hero) rather than the cream background.
struct StashBackButton: View {
    @Environment(\.dismiss) private var dismiss
    var tint: Color = .stashInk

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint.opacity(0.75))
                // The cream variant sits on a photo; a soft shadow keeps it legible on a bright one.
                .shadow(color: .black.opacity(tint == .stashInk ? 0 : 0.45), radius: 3, y: 1)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

/// Hiding the navigation bar (`.toolbar(.hidden, for: .navigationBar)`) also switches off
/// the swipe back: UIKit's own delegate on the pop gestures refuses to begin while the bar
/// is hidden. Re-own those delegates class-wide, so every NavigationStack in the app gets
/// the standard left-edge swipe with no per-screen wiring.
///
/// iOS 26 drives the pop through `interactiveContentPopGestureRecognizer` — a pan that may
/// start anywhere in the content — and the classic `interactivePopGestureRecognizer` never
/// begins on its own there. Both go to `SwipeBackDelegate`, which only lets a pan that
/// started in the left-edge strip through: the Mind map canvas drag, the horizontal shelves
/// and the right-edge TimeRail scrub stay untouched, and nothing starts at a stack root
/// (sheets, Cook Mode) or mid-transition, which is where a stray pop corrupts the stack.
extension UINavigationController {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = SwipeBackDelegate.shared
        if #available(iOS 26, *) {
            interactiveContentPopGestureRecognizer?.delegate = SwipeBackDelegate.shared
        }
    }
}

/// A separate object rather than the controller itself, so nothing SwiftUI's private
/// UINavigationController subclass implements can shadow it.
private final class SwipeBackDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackDelegate()

    /// The strip a pop may start in — the system's screen-edge region.
    private let edge: CGFloat = 20
    private var startedAtEdge = false

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = recognizer.view else { return false }
        startedAtEdge = touch.location(in: view).x <= edge
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard startedAtEdge,
              let navigation = navigationController(of: recognizer),
              navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil
        else { return false }
        // Rightward and mostly horizontal. Velocity, not translation: the pop recognizers
        // ask before they begin, while translation still reads zero.
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return velocity.x >= abs(velocity.y)
    }

    private func navigationController(of recognizer: UIGestureRecognizer) -> UINavigationController? {
        var responder: UIResponder? = recognizer.view
        while let current = responder {
            if let navigation = current as? UINavigationController { return navigation }
            responder = current.next
        }
        return nil
    }
}
