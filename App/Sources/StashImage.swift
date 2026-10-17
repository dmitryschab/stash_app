import SwiftData
import SwiftUI
import TikTokBrainKit

/// Local previews display immediately on a cache hit, including newly recreated cards.
/// Cold reads decode off the main thread; remote artwork retains AsyncImage behavior.
struct StashImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loaded: LoadedImage?

    private struct LoadedImage {
        let url: URL
        let image: CGImage
    }

    var body: some View {
        if let url, url.isFileURL {
            localImage(url)
                .task(id: url) {
                    guard let image = await LocalImageCache.shared.image(for: url),
                          !Task.isCancelled else { return }
                    loaded = LoadedImage(url: url, image: image)
                }
        } else {
            AsyncImage(url: url, content: content, placeholder: placeholder)
        }
    }

    @ViewBuilder
    private func localImage(_ url: URL) -> some View {
        if let image = (loaded?.url == url ? loaded?.image : nil)
            ?? LocalImageCache.shared.cachedImage(for: url) {
            content(Image(decorative: image, scale: 1))
        } else {
            placeholder()
        }
    }
}

/// Decodes every tab's first screen at launch, so switching to a tab finds its covers already
/// in memory instead of watching them trickle in. Newest saves first, per slot in the pill;
/// the budget is the memory cache's (`LocalImageCache`), not the library's, so each tab gets
/// its first screen and no more.
enum CoverPrewarm {
    /// About one screen of a category grid, of the Library's shelves, of the music wall.
    static let perTab = 10, overall = 16, sleeves = 12

    static func run(container: ModelContainer, slots: [StashTab]) async {
        let urls = await Task.detached(priority: .utility) { urls(container: container, slots: slots) }.value
        LocalImageCache.shared.prewarm(urls)
    }

    /// Reads on its own context, like the other background drains, so the fetch never sits
    /// on the main thread between the splash and the shell.
    nonisolated static func urls(container: ModelContainer, slots: [StashTab]) -> [URL] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Video>(sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)])
        // ponytail: every first screen lives in the newest few hundred saves; a category
        // with no save among them simply starts cold.
        descriptor.fetchLimit = 600
        guard let videos = try? context.fetch(descriptor) else { return [] }
        // Library, Lately and Haul all open on the newest saves across every category.
        var urls = videos.prefix(overall).compactMap(\.thumbnailURL)
        for tab in slots {
            guard let category = tab.ownedCategory else { continue }
            let own = videos.filter { $0.category == category }
            if category == .music {
                // The wall draws album sleeves, not the clips' own covers.
                urls += AlbumStore.cachedSleeves(
                    for: own.prefix(sleeves * 2).map { ($0.videoID, $0.music.count) }, limit: sleeves)
            } else {
                urls += own.prefix(perTab).compactMap(\.thumbnailURL)
            }
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}
