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
