import SwiftUI
import TikTokBrainKit

/// Broad browsing categories; extraction keeps the original product kind.
enum HaulCategory: String, CaseIterable, Identifiable {
    case tech, home, style, beauty, wellness, other
    var id: Self { self }
    var label: String { rawValue.capitalized }

    static func category(for pick: BuyPick) -> Self {
        let words = pick.kind.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let groups: [(Self, [String])] = [
            (.tech, ["mouse", "keyboard", "phone", "laptop", "computer", "headphone", "earbud", "speaker", "camera", "monitor", "tablet", "charger", "cable", "microphone", "console", "tech", "gadget"]),
            (.home, ["lamp", "light", "chair", "desk", "table", "sofa", "bed", "pillow", "blanket", "vase", "mug", "coffee", "kitchen", "pan", "pot", "vacuum", "rug", "shelf", "shelves", "furniture", "home"]),
            (.style, ["shoe", "sneaker", "boot", "sandal", "shirt", "jacket", "coat", "dress", "jean", "trouser", "pant", "sweater", "hoodie", "bag", "jewelry", "jewellery", "watch", "glasses", "hat", "clothing", "fashion"]),
            (.beauty, ["serum", "cream", "makeup", "lipstick", "lip", "mascara", "foundation", "cleanser", "sunscreen", "perfume", "fragrance", "shampoo", "conditioner", "skincare", "beauty", "hair"]),
            (.wellness, ["fitness", "yoga", "weight", "dumbbell", "exercise", "supplement", "vitamin", "protein", "massage", "wellness"]),
        ]
        return groups.first { _, terms in
            terms.contains { words.contains($0) || words.contains($0 + "s") }
        }?.0 ?? .other
    }
}

/// The caller supplies the size. Local frames and remote covers use the same layout.
struct HaulProductArtwork: View {
    let video: Video
    var pickIndex: Int? = nil

    private var url: URL? {
        if let pickIndex, let frame = PickFrameStore.shared.frame(videoID: video.videoID, pickIndex: pickIndex) {
            return frame
        }
        return video.thumbnailURL
    }

    var body: some View {
        Color.stashHaul.opacity(0.07)
            .overlay {
                if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { placeholder }
                    }
                } else { placeholder }
            }
            .clipped()
            // clipped() trims the drawing, not the touches: a portrait frame filled into a
            // wide box still spills hundreds of points above it and swallows the taps meant
            // for the page's back and options buttons.
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: pickIndex == nil ? "play.rectangle" : "bag")
            .font(.system(size: 27, weight: .light))
            .foregroundStyle(Color.stashHaul.opacity(0.6))
    }
}

private struct StashTabBarHiddenKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var stashTabBarHidden: Binding<Bool> {
        get { self[StashTabBarHiddenKey.self] }
        set { self[StashTabBarHiddenKey.self] = newValue }
    }
}
