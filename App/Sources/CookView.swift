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

    private var recipes: [Video] {
        videos.filter { $0.category == .recipe && $0.recipe != nil }
    }

    /// Chips never remove tiles from the wall — non-matching tiles dim instead.
    private func matches(_ video: Video) -> Bool {
        guard let focus else { return true }
        return video.topics.contains(focus)
    }

    /// Top topics across all recipe saves, by save count.
    private var topicChips: [String] {
        var counts: [String: Int] = [:]
        for video in recipes {
            for topic in video.topics { counts[topic, default: 0] += 1 }
        }
        return counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(5)
            .map(\.key)
    }

    private var trailing: String {
        guard focus != nil else { return "\(recipes.count) recipes" }
        let hits = recipes.filter(matches).count
        return "\(hits) of \(recipes.count) in focus"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StashHeader(title: "Cook", trailing: trailing)
                        .padding(.top, 8)
                    if !topicChips.isEmpty {
                        chips.padding(.top, 14)
                    }
                    if recipes.isEmpty {
                        emptyState.padding(.top, 48)
                    } else {
                        wall.padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("all", isOn: focus == nil) { focus = nil }
                ForEach(topicChips, id: \.self) { topic in
                    chip(topic, isOn: focus == topic) {
                        focus = focus == topic ? nil : topic
                    }
                }
            }
        }
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Micro(text: label, size: 9.5, tracking: 0.8, color: isOn ? .stashOnInk : .stashInk.opacity(0.65))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    if isOn {
                        Capsule().fill(Color.stashInk)
                    } else {
                        Capsule().strokeBorder(Color.stashInk.opacity(0.28), lineWidth: 1.2)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var wall: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(recipes, id: \.videoID) { video in
                let hit = matches(video)
                NavigationLink { RecipeDetailView(video: video) } label: {
                    WallTile(video: video)
                        .opacity(hit ? 1 : 0.22)
                        .saturation(hit ? 1 : 0.08)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(video.rowTitle)
            }
        }
        .animation(.easeOut(duration: 0.35), value: focus)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "fork.knife")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.categoryRecipe)
            Text("Nothing to cook yet")
                .font(.archivo(17, .bold))
                .foregroundStyle(Color.stashInk)
            Text("Recipes you save land here as a wall.")
                .font(.archivo(13))
                .foregroundStyle(Color.stashInk.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }
}

/// One wall tile: the thumbnail edge to edge, jewel placeholder until it loads.
private struct WallTile: View {
    let video: Video

    var body: some View {
        AsyncImage(url: video.thumbnailURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.categoryRecipe
                Image(systemName: "fork.knife")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.stashOnAccent)
            }
        }
        .frame(height: 104)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Recipe detail (5a)

struct RecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss
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
            AsyncImage(url: video.thumbnailURL) { image in
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
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(cream)
                            .frame(width: 36, height: 36)
                            .background(Color(hex: 0x201A12).opacity(0.35), in: Circle())
                            .overlay(Circle().strokeBorder(cream, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
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
