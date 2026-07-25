// WatchSection.swift
//
// Rewatch inside the detail screen: TikTok's official embed player in a WKWebView, by video
// ID only — no API approval involved and nothing is downloaded to the device.
//
// There used to be a "Keep offline" button here that stored the mp4 in Application Support.
// It is gone: persistent local copies of someone else's video are an App Store guideline
// 5.2.3 problem, and nothing in the app needs them. The transient fetch that OCR uses lives
// in PipelineCenter (`BoxVideoDownload`) — it downloads, samples frames and deletes.

import SwiftUI
import TikTokBrainKit
import WebKit

struct WatchSection: View {
    let video: Video
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Micro(text: "Watch", size: 11, tracking: 2, color: tint)
                .padding(.top, 20)

            // The seeded demo library carries invented video ids, so the embed would load
            // TikTok's "video unavailable" page as the tallest element on the screen — the
            // first thing an App Review reviewer sees. Name it for what it is instead.
            if StashSession.shared.isDemoAccount {
                samplePlaceholder
            } else {
                TikTokEmbedView(videoID: video.videoID)
                    .frame(height: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.stashInk.opacity(0.12), lineWidth: 1)
                    )
            }
        }
    }

    /// Stands in for the embed on the seeded demo library.
    private var samplePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.3))
            Micro(text: "Sample video · no playback", size: 10.5, tracking: 1.4,
                  color: .stashInk.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.stashInk.opacity(0.12), lineWidth: 1)
        )
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
