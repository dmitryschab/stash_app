// CookView.swift
//
// The Cook tab (design: "Cook Tab Options" 4a → 5a → 5b): every recipe save on a photo
// wall whose filter chips dim tiles instead of hiding them, a cook-focused recipe screen
// (hero, ingredients, the pipeline's summarized method), and a full-screen Cook Mode that
// walks one step per screen in kitchen-distance type while keeping the screen awake.

import SwiftUI
import SwiftData
import TikTokBrainKit

// MARK: - The wall (4a)

struct CookView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var focus: String?   // selected topic chip; nil = all
    @State private var browsingTopics = false

    /// Checks for the payload rather than decoding it: `recipe` also runs the metric rewrite over
    /// every line, and this is read several times per body — on a 233-recipe phone that was most
    /// of what opening Cook cost.
    private var recipes: [Video] {
        videos.filter { $0.category == .recipe && $0.recipeJSON != nil }
    }

    private func matches(_ video: Video) -> Bool {
        guard let focus else { return true }
        return video.topics.contains(focus)
    }

    /// What the wall draws. A chosen filter removes the rest rather than dimming them: at 233
    /// recipes the dimmed majority was most of the scroll, so "chicken" still meant paging past
    /// two hundred greyed tiles to find thirty.
    private var shown: [Video] {
        recipes.filter(matches)
    }

    /// Every topic across the recipe saves with how many carry it, most-used first.
    /// A 233-recipe library runs to ~350 of these, so the row shows the head and the
    /// picker owns the rest.
    private var topics: [TopicCount] {
        var counts: [String: Int] = [:]
        for video in recipes {
            for topic in video.topics { counts[topic, default: 0] += 1 }
        }
        return counts
            .map { TopicCount(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The five most-used topics — plus whatever is in focus, which the picker may have set
    /// to something far down the tail. A selected chip you cannot see reads as no selection.
    ///
    /// A topic on one recipe is a label, not a way through the library, so it never pads the
    /// row: a sparse shelf shows three real chips rather than three plus two one-offs.
    private var rowTopics: [TopicCount] {
        let head = Array(topics.filter { $0.count >= TopicPicker.browseFloor }.prefix(5))
        guard let focus, !head.contains(where: { $0.name == focus }) else { return head }
        let selected = topics.first { $0.name == focus } ?? TopicCount(name: focus, count: 0)
        return [selected] + head.dropLast()
    }

    private var trailing: String {
        guard focus != nil else { return "\(recipes.count) recipes" }
        return "\(shown.count) of \(recipes.count)"
    }

    /// The wall in month runs, so the time rail has something to jump to.
    private var runs: [MonthRun<Video>] {
        monthRuns(shown) { $0.bookmarkedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: .cook) {
                    VStack(alignment: .leading, spacing: 0) {
                        StashHeader(title: "Cook", trailing: trailing)
                            .padding(.top, 8)
                        if !topics.isEmpty {
                            chips.padding(.top, 8)
                        }
                        if recipes.isEmpty {
                            emptyState.padding(.top, 48)
                        } else {
                            wall.padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, stashTabBarClearance)
                }
                .background(Color.stashBackground.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .trailing) {
                    let entries = timeRailEntries(for: runs)
                    if entries.count >= 2 {
                        TimeRail(entries: entries, proxy: proxy)
                    }
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TopicChip(label: "all", isOn: focus == nil) { focus = nil }
                ForEach(rowTopics) { topic in
                    TopicChip(label: topic.name, count: topic.count, isOn: focus == topic.name) {
                        focus = focus == topic.name ? nil : topic.name
                    }
                }
                TopicChip(label: "more", symbol: "ellipsis", isOn: false) { browsingTopics = true }
            }
        }
        .sheet(isPresented: $browsingTopics) {
            TopicPicker(topics: topics, focus: $focus)
        }
    }

    private var wall: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                Micro(text: run.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.45))
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .id(run.id)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(run.items, id: \.videoID) { video in
                        NavigationLink { RecipeDetailView(video: video) } label: {
                            WallTile(video: video)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(video.rowTitle)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: focus)
    }

    private var emptyState: some View {
        StashEmptyState(
            symbol: "fork.knife",
            tint: .categoryRecipe,
            title: "Nothing to cook yet",
            message: videos.isEmpty
                ? "Recipes land here as a wall once your favorites are in."
                : "None of your saves came back as a recipe yet — the wall fills as they are analyzed.",
            offersImport: videos.isEmpty
        )
    }
}

// MARK: - Topic filters

/// A topic and how many recipes carry it.
struct TopicCount: Identifiable, Equatable {
    let name: String
    let count: Int
    var id: String { name }
}

/// One filter chip. The pill stays small; the tap target does not.
///
/// The old chip was ~28 pt tall with its hit area ending at the pill's edge, sitting in a
/// horizontal strip nested inside the vertical scroll view — so a tap that drifted a few
/// points became a scroll and the chip "wasn't pressable". A 44 pt `contentShape` (Apple's
/// minimum) around the same visual pill is the whole fix.
struct TopicChip: View {
    let label: String
    var count: Int? = nil
    var symbol: String? = nil
    /// What `count` counts, for VoiceOver: recipes on Cook, saves on Films.
    var unit = "recipes"
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(foreground)
            }
            Micro(text: label, size: 9.5, tracking: 0.8, color: foreground)
            if let count {
                Micro(text: "\(count)", size: 9.5, tracking: 0.4,
                      color: foreground.opacity(isOn ? 0.6 : 0.4))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background {
            if isOn {
                Capsule().fill(Color.stashInk)
            } else {
                Capsule().strokeBorder(Color.stashInk.opacity(0.28), lineWidth: 1.2)
            }
        }
        .padding(.vertical, 7)          // pads the target, not the pill
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map { "\(label), \($0) \(unit)" } ?? label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
    }

    private var foreground: Color { isOn ? .stashOnInk : .stashInk.opacity(0.65) }
}

/// The full topic list behind the row's "more" chip: every topic, most-used first, with a
/// search field for the long tail. A real library runs to ~350 topics of which two thirds
/// sit on a single recipe, so scrolling to one is hopeless and searching for it is not.
struct TopicPicker: View {
    let topics: [TopicCount]
    @Binding var focus: String?
    /// The noun in "All …": recipes on Cook, saves on Films.
    var unit = "recipes"

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// Below this a topic is a label on one recipe, not a way through the library. They stay
    /// out of the browse list and out of the chip row, and stay findable by name.
    static let browseFloor = 2

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var shown: [TopicCount] {
        guard !trimmed.isEmpty else { return topics.filter { $0.count >= Self.browseFloor } }
        return topics.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var hiddenCount: Int { topics.count - topics.filter { $0.count >= Self.browseFloor }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            field.padding(.horizontal, 20).padding(.top, 14)
            if shown.isEmpty {
                Text("No topic matched.")
                    .font(.archivo(14, .semibold))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                Spacer()
            } else {
                list
            }
        }
        .background(Color.stashBackground.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("Filter")
                .font(.archivo(28, .heavy))
                .foregroundStyle(Color.stashInk)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.stashInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.stashInk)
            TextField("chicken, soup, meal prep", text: $query)
                .font(.archivo(15, .semibold))
                .foregroundStyle(Color.stashInk)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(Color.stashSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                row(label: "All \(unit)", count: nil, isOn: focus == nil) { focus = nil }
                ForEach(shown) { topic in
                    row(label: topic.name, count: topic.count, isOn: focus == topic.name) {
                        focus = topic.name
                    }
                }
                if trimmed.isEmpty, hiddenCount > 0 {
                    Text("\(hiddenCount) more topics sit on one save each — search to find them.")
                        .font(.archivo(12, .medium))
                        .foregroundStyle(Color.stashInk.opacity(0.45))
                        .padding(.vertical, 18)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .padding(.top, 8)
    }

    private func row(label: String, count: Int?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(label)
                    .font(.archivo(15, isOn ? .heavy : .semibold))
                    .foregroundStyle(Color.stashInk)
                Spacer()
                if let count {
                    Micro(text: "\(count)", size: 10, tracking: 0.4, color: .stashInk.opacity(0.4))
                }
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? Color.categoryRecipe : Color.stashInk.opacity(0.2))
            }
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.stashInk.opacity(0.08)).frame(height: 1)
        }
    }
}

/// One wall tile: the thumbnail edge to edge, jewel placeholder until it loads.
private struct WallTile: View {
    let video: Video

    var body: some View {
        // Overlay on a clear colour: the image never gets a say in the tile's size. Letting a
        // scaledToFill image be the layout subject let one landscape thumbnail widen its grid
        // column and shove the whole row off screen.
        Color.clear
            .overlay {
                StashImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Color.categoryRecipe
                        Image(systemName: "fork.knife")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.stashOnAccent)
                    }
                }
            }
        .frame(height: 104)
        .frame(maxWidth: .infinity)
        // `clipShape` clips the drawing, not the touch region: a scaledToFill image overflows
        // its frame, so without this each tile was tappable well beyond its own square — far
        // enough up to swallow the filter chips' taps.
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Recipe detail (5a)

struct RecipeDetailView: View {
    let video: Video

    @State private var isCooking = false

    private let cream = Color(hex: 0xF7F1E1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 0) {
                    Text(video.rowTitle)
                        .font(.archivo(26, .heavy))
                        .foregroundStyle(Color.stashInk)
                        .padding(.top, 16)
                    Text(byline)
                        .font(.archivo(12, .semibold))
                        .foregroundStyle(Color.stashInk.opacity(0.5))
                        .padding(.top, 6)
                    if let recipe = video.recipe {
                        ingredientsSection(recipe.ingredients)
                        methodSection(recipe.steps)
                    }
                    actionBar.padding(.top, 26)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $isCooking) {
            CookModeView(title: video.rowTitle, steps: video.recipe?.steps ?? [])
        }
    }

    private var byline: String {
        var parts: [String] = []
        if !video.author.isEmpty { parts.append("@\(video.author)") }
        parts.append("saved \(video.bookmarkedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .top) {
            StashImage(url: video.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.categoryRecipe
            }
            .frame(height: 216)
            .frame(maxWidth: .infinity)
            .clipped()
            LinearGradient(
                colors: [Color(hex: 0x201A12).opacity(0.55), Color(hex: 0x201A12).opacity(0.12)],
                startPoint: .bottom, endPoint: .top
            )
            VStack {
                HStack {
                    StashBackButton(tint: cream)
                    Spacer()
                    Micro(text: "Recipe", size: 10, tracking: 1.8, color: cream)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color.categoryRecipe, in: Capsule())
                }
                .padding(.top, 58)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(video.topics.prefix(3), id: \.self) { topic in
                        Micro(text: topic, size: 9.5, tracking: 1.4, color: cream)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().strokeBorder(cream.opacity(0.6), lineWidth: 1.2))
                    }
                    Spacer()
                }
                .padding(.bottom, 14)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 216)
    }

    // MARK: Sections

    @ViewBuilder
    private func ingredientsSection(_ ingredients: [String]) -> some View {
        if !ingredients.isEmpty {
            Micro(text: "Ingredients · \(ingredients.count)", size: 10, tracking: 2, color: .categoryRecipe)
                .padding(.top, 18)
            VStack(spacing: 0) {
                ForEach(ingredients, id: \.self) { ingredient in
                    HStack(spacing: 12) {
                        Rectangle().fill(Color.categoryRecipe).frame(width: 8, height: 8)
                        Text(ingredient)
                            .font(.archivo(14, .semibold))
                            .foregroundStyle(Color.stashInk)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    if ingredient != ingredients.last {
                        Divider().overlay(Color.stashInk.opacity(0.12))
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func methodSection(_ steps: [String]) -> some View {
        if !steps.isEmpty {
            Micro(text: "Method · Summarized from the video", size: 10, tracking: 2, color: .categoryRecipe)
                .padding(.top, 16)
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.archivo(17, .heavy))
                            .foregroundStyle(Color.categoryRecipe)
                            // 26pt fits two digits — recipes routinely run past step 9.
                            .frame(width: 26, alignment: .leading)
                        Text(step)
                            .font(.archivo(13.5))
                            .foregroundStyle(Color.stashInk)
                            .lineSpacing(3)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            if !(video.recipe?.steps.isEmpty ?? true) {
                StashPrimaryButton(title: "Start cooking") { isCooking = true }
            }
            Link(destination: video.url) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.stashInk)
                    .frame(width: 52, height: 52)
                    .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
            }
            .accessibilityLabel("Open in TikTok")
        }
    }
}

// MARK: - Cook Mode (5b)

/// One step per screen, readable from across the counter. The screen stays awake while open.
struct CookModeView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let steps: [String]

    @State private var step = 0

    private let cream = Color(hex: 0xF7F1E1)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(cream)
                        .frame(width: 36, height: 36)
                        .background(Circle().strokeBorder(cream, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
                Micro(text: title, size: 10, tracking: 2.2, color: cream.opacity(0.75))
                    .lineLimit(1)
                Spacer()
                Micro(text: "\(step + 1) / \(steps.count)", size: 10, tracking: 1.4, color: cream.opacity(0.75))
            }
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? cream : cream.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(step + 1)")
                        .font(.archivo(84, .black))
                        .foregroundStyle(cream.opacity(0.35))
                    Text(steps.indices.contains(step) ? steps[step] : "")
                        .font(.archivo(30, .black))
                        .foregroundStyle(cream)
                        .lineSpacing(6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 44)
            }
            HStack(spacing: 12) {
                Button {
                    if step > 0 { step -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(cream)
                        .frame(width: 52, height: 52)
                        .background(Circle().strokeBorder(cream, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .opacity(step == 0 ? 0.35 : 1)
                .disabled(step == 0)
                .accessibilityLabel("Previous step")
                Button {
                    if step + 1 < steps.count { step += 1 } else { dismiss() }
                } label: {
                    Text(step + 1 < steps.count ? "NEXT STEP" : "DONE")
                        .font(.archivo(13, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Color.categoryRecipe)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(cream, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Micro(text: "Screen stays awake", size: 9.5, tracking: 1.6, color: cream.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.categoryRecipe.ignoresSafeArea())
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

#Preview("Cook wall") {
    CookView()
        .modelContainer(SampleData.previewContainer)
}

#Preview("Cook mode") {
    CookModeView(title: "Cacio e pepe", steps: [
        "Toast the cracked pepper in the dry pan until fragrant.",
        "Cook the spaghetti right in the pan, just shy of al dente.",
        "Mash pecorino with a splash of cool pasta water into a paste.",
    ])
}
