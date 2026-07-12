// WatchSection.swift
//
// Rewatch inside the detail screen. Local offline mp4 plays natively (AVPlayer)
// when the user has kept it; otherwise TikTok's official embed player renders in
// a WKWebView (video ID only — no API approval involved).
//
// "Keep offline" downloads through the model box (`{boxBaseURL}/tiktok/download/<id>`,
// yt-dlp server-side). Pure in-app downloading is impossible against current TikTok
// controls — verified empirically: pages serve a blank playAddr without the JS
// handshake, the CDN 403s cookie-replayed stream URLs, and CORS blocks even the
// embed page fetching its own stream. The box is the production path anyway.

import AVKit
import SwiftUI
import SwiftData
import TikTokBrainKit
import WebKit

struct WatchSection: View {
    @Environment(\.modelContext) private var context
    let video: Video
    let tint: Color

    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @State private var isSaving = false
    @State private var saveFailed = false

    private var offlineURL: URL? {
        guard let name = video.offlineVideoFilename else { return nil }
        let url = OfflineVideoStore.fileURL(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Micro(text: "Watch", size: 11, tracking: 2, color: tint)
                if offlineURL != nil {
                    Micro(text: "OFFLINE", size: 8.5, tracking: 1.4, color: .stashOnAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint))
                }
                Spacer()
                // Hidden only for unavailable videos with nothing kept (nothing to download).
                if !video.unavailable || offlineURL != nil { keepButton }
            }
            .padding(.top, 20)

            Group {
                if let url = offlineURL {
                    OfflinePlayerView(url: url)
                } else {
                    TikTokEmbedView(videoID: video.videoID)
                }
            }
            .frame(height: 480)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.stashInk.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Keep offline

    private var keepButton: some View {
        Button {
            if offlineURL != nil {
                remove()
            } else if !isSaving {
                Task { await save() }
            }
        } label: {
            HStack(spacing: 5) {
                if isSaving {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: offlineURL != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 11, weight: .semibold))
                }
                Micro(text: buttonLabel, size: 9, tracking: 1, color: .stashInk.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().strokeBorder(Color.stashInk.opacity(0.3), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .foregroundStyle(Color.stashInk.opacity(0.75))
    }

    private var buttonLabel: String {
        if isSaving { return "SAVING…" }
        if let url = offlineURL {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            let size = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            return size.map { "OFFLINE · \($0)" } ?? "OFFLINE"
        }
        return saveFailed ? "RETRY" : "KEEP OFFLINE"
    }

    private func save() async {
        isSaving = true
        saveFailed = false
        do {
            video.offlineVideoFilename = try await OfflineVideoStore.download(
                videoID: video.videoID, boxBaseURL: boxBaseURL)
            try context.save()
        } catch {
            NSLog("StashOffline: download failed: %@", String(describing: error))
            saveFailed = true
        }
        isSaving = false
    }

    private func remove() {
        if let name = video.offlineVideoFilename {
            try? FileManager.default.removeItem(at: OfflineVideoStore.fileURL(name))
        }
        video.offlineVideoFilename = nil
        try? context.save()
    }
}

// MARK: - Offline storage

enum OfflineVideoStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OfflineVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Asks the model box to yt-dlp the video and stores the returned mp4.
    static func download(videoID: String, boxBaseURL: String) async throws -> String {
        guard let base = URL(string: boxBaseURL) else { throw URLError(.badURL) }
        let endpoint = base.appendingPathComponent("tiktok/download/\(videoID)")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 120  // yt-dlp on the box takes 5–20 s per video

        let (data, response) = try await URLSession.shared.data(for: request)
        // Valid mp4s carry "ftyp" at byte 4; error bodies are small HTML/text.
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 50_000,
              data.subdata(in: 4..<8) == Data("ftyp".utf8) else {
            throw URLError(.badServerResponse)
        }

        let name = "\(videoID).mp4"
        try data.write(to: fileURL(name), options: .atomic)
        return name
    }
}

// MARK: - Players

/// AVPlayer wrapper whose player is created once per URL (a bare `AVPlayer(url:)`
/// in `body` would reset playback on every unrelated view update).
private struct OfflinePlayerView: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
    }
}

/// TikTok's official embed player for one video.
private struct TikTokEmbedView: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        if let url = URL(string: "https://www.tiktok.com/embed/v2/\(videoID)") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
