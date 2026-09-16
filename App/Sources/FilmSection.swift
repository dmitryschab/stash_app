// FilmSection.swift
//
// The film detail payload: a compact horizontal strip of posters for every movie the video
// named or showed, in the order it showed them. No embedded video here — `WatchSection`'s
// TikTok/Instagram embed is swapped out for this on `.film` saves (see VideoDetailView), so the
// clip itself is one tap away on "WATCH ON TIKTOK" instead of playing inline.
//
// Poster art and the detail link both come from Wikipedia via `FilmResolver`, resolved lazily
// per card — a title alone (no year, no ambiguity check) is not enough to trust a link, so an
// unresolved pick renders as a plain tinted tile with its title, same as any other "no match
// found" case in this app (see VideoDetailView.pickByline for the music equivalent).

import SwiftUI
import TikTokBrainKit

struct FilmSection: View {
    let video: Video
    let tint: Color

    /// Keyed by index into `films` rather than by title — two picks can share a title (a remake),
    /// and the index is what `.task(id:)` iterates and what the card lookup uses.
    @State private var refs: [Int: FilmRef] = [:]

    private var films: [FilmPick] { video.films }

    var body: some View {
        if !films.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader
                row
            }
            .task(id: video.filmsJSON) { await resolveFilms() }
        }
    }

    private var sectionHeader: some View {
        Micro(text: films.count == 1 ? "Film" : "\(films.count) films", size: 11, tracking: 2, color: tint)
            .padding(.top, 20)
    }

    /// Card width 100 + 12pt spacing means three cards sit fully in view on a ~375pt phone and a
    /// fourth peeks at the edge — the usual "there's more" affordance for a horizontal shelf.
    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(films.enumerated()), id: \.offset) { index, pick in
                    card(index: index, pick: pick)
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func card(index: Int, pick: FilmPick) -> some View {
        let ref = refs[index]
        let content = VStack(alignment: .leading, spacing: 6) {
            poster(pick: pick, ref: ref)
            Text(pick.title)
                .font(.archivo(12.5, .bold))
                .foregroundStyle(Color.stashInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let year = pick.year {
                Text(String(year))
                    .font(.archivo(11))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
            }
        }
        .frame(width: 100, alignment: .leading)

        // Only a resolved pick is a link — the honest outcome for a no-match title is a plain
        // tile, not a link to the wrong movie's page.
        if let ref {
            Link(destination: ref.detailURL) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(pick: pick))
                .accessibilityAddTraits(.isLink)
                .accessibilityHint("Opens movie details")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(pick: pick))
        }
    }

    private func poster(pick: FilmPick, ref: FilmRef?) -> some View {
        // `scaledToFill` overflows the frame; clipping trims the drawing, not the touches, so
        // contentShape bounds the hit area to the card (same fix as HaulProductArtwork). Not
        // allowsHitTesting(false): the poster is the Link's main tap target.
        Color.clear
            .overlay {
                AsyncImage(url: ref?.posterURL) { $0.resizable().scaledToFill() } placeholder: {
                    posterPlaceholder(title: pick.title)
                }
            }
            .frame(width: 100, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func posterPlaceholder(title: String) -> some View {
        Rectangle()
            .fill(tint.opacity(0.14))
            .overlay {
                Text(title)
                    .font(.archivo(13, .heavy))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(8)
            }
    }

    private func accessibilityLabel(pick: FilmPick) -> String {
        guard let year = pick.year else { return pick.title }
        return "\(pick.title), \(year)"
    }

    /// `.task(id:)` cancels this the moment the view leaves the hierarchy (navigating away mid
    /// lookup) and re-runs it whenever `filmsJSON` changes (a re-run pipeline rewriting the
    /// picks) — both for free, instead of hand-rolled cancellation bookkeeping.
    private func resolveFilms() async {
        refs = [:]
        await withTaskGroup(of: (Int, FilmRef?).self) { group in
            for (index, pick) in films.enumerated() {
                group.addTask {
                    (index, try? await FilmResolver.shared.film(for: pick))
                }
            }
            for await (index, ref) in group {
                if let ref { refs[index] = ref }
            }
        }
    }
}

#Preview {
    let video = SampleData.makeSampleVideos().first { $0.category == .film }!
    return ScrollView {
        FilmSection(video: video, tint: .categoryFilm)
            .padding(.horizontal, 20)
    }
    .background(Color.stashBackground)
}
