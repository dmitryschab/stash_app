// WatchSection.swift
//
// Rewatch inside the detail screen. The block opens as a poster — the save's own thumbnail,
// dimmed, with the author and the first thing the creator says — because that is what brings
// a clip back, and it costs nothing: no network, no cookie banner, no "video unavailable" card
// on the saves TikTok has since deleted. Tap it and TikTok's official embed player takes its
// place (a WKWebView by video ID only — no API approval involved, nothing downloaded); long
// press and the clip opens in TikTok itself.
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

    @State private var playing = false
    @Environment(\.openURL) private var openURL

    /// The poster is always dark (a photo under a black gradient), so its type is always cream —
    /// not `stashOnInk`, which turns to ink in dark mode.
    private let cream = Color(hex: 0xF7F1E1)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Micro(text: "Watch", size: 11, tracking: 2, color: tint)
                .padding(.top, 20)

            if playing {
                // The seeded demo library carries invented video ids, so the embed would load
                // TikTok's "video unavailable" page. Name it for what it is instead.
                if StashSession.shared.isDemoAccount {
                    samplePlaceholder
                } else {
                    embed
                }
            } else {
                poster
            }
        }
        .animation(.easeOut(duration: 0.25), value: playing)
    }

    // MARK: - Poster

    private var poster: some View {
        ZStack(alignment: .bottomLeading) {
            // Overlay on a clear colour, clipped, and out of hit-testing: `scaledToFill`
            // makes the frame taller than the card, and a tap on the header must never land
            // "inside" the poster (the featured card shipped that bug in build 21).
            Color.clear
                .overlay {
                    if let url = video.thumbnailURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            tint
                        }
                    } else {
                        tint
                    }
                }
                .clipped()
                .allowsHitTesting(false)
            LinearGradient(
                colors: [.black.opacity(0.3), .black.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 0) {
                Micro(text: video.author.isEmpty ? platform : "@\(video.author)",
                      size: 9, tracking: 1.6, color: cream.opacity(0.85))
                Spacer(minLength: 0)
                if let line = firstLine {
                    Text("“\(line)”")
                        .font(.archivo(12.5, .semibold))
                        .foregroundStyle(cream)
                        .lineLimit(3)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
        }
        .overlay {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(cream)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.25)))
                .overlay(Circle().strokeBorder(cream, lineWidth: 1.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { playing = true }
        .onLongPressGesture { openURL(video.url) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Play video")
        .accessibilityHint("Long press to open in \(platform)")
        .accessibilityAddTraits(.isButton)
    }

    private var platform: String { TikTokLink.isInstagram(video.url) ? "Instagram" : "TikTok" }

    /// The first sentence the creator says — or the caption when there is no transcript.
    // ponytail: first terminator wins, so "Mr. Smith says…" cuts early; good enough for a recall line.
    private var firstLine: String? {
        let source = video.transcript.flatMap { $0.isEmpty ? nil : $0 }
            ?? (video.caption.isEmpty ? nil : video.caption)
        guard let source else { return nil }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = text.firstIndex { ".!?".contains($0) }.map { text.index(after: $0) } ?? text.endIndex
        let sentence = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count > 140 ? String(sentence.prefix(137)) + "…" : sentence
    }

    // MARK: - Playback

    private var embed: some View {
        EmbedView(url: TikTokLink.embedURL(for: video.url, videoID: video.videoID))
            // ponytail: measured once — Instagram's embed lays out at 980 px and scales to ~520 pt on a phone card.
            .frame(height: TikTokLink.isInstagram(video.url) ? 540 : 480)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.stashInk.opacity(0.12), lineWidth: 1)
            )
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

/// The platform's official embed player for one video.
private struct EmbedView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        if let url {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
