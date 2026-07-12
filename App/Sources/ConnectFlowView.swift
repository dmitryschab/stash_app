// ConnectFlowView.swift
//
// A three-step "connect your TikTok" onboarding flow, presented as a sheet from the Import
// screen. This is a UI prototype only: the primary buttons advance an enum-modeled `step` —
// there is no OAuth, no networking, and no secrets. "Open library" dismisses the sheet.
// Set List style: ink app tile, four jewel dots, outlined chips, green access checks.

import SwiftUI
import TikTokBrainKit

struct ConnectFlowView: View {
    /// The three screens, advanced in order on each primary button tap.
    private enum Step: Hashable {
        case intro, access, success
    }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .intro

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if step != .success {
                    Button { dismiss() } label: {
                        Micro(text: "Cancel", size: 11, tracking: 1.7, color: .stashInk.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 24)
            .padding(.top, 16)

            Group {
                switch step {
                case .intro: intro
                case .access: access
                case .success: success
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stashBackground.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    // MARK: - Step 1 · Connect entry point

    private var intro: some View {
        VStack(spacing: 0) {
            Spacer()
            appTile
            HStack(spacing: 8) {
                ForEach(librarySegments, id: \.self) { category in
                    Circle().fill(category.color).frame(width: 9, height: 9)
                }
            }
            .padding(.top, 16)
            Text("Connect your TikTok")
                .font(.archivo(27, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 20)
            Text("Stash organizes the videos you save on TikTok into a searchable library — automatically.")
                .font(.archivo(14))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 280)
                .padding(.top, 10)
            InfoChip(text: "We only read your Favorites", systemImage: "lock.fill")
                .padding(.top, 20)
            Spacer()
            StashPrimaryButton(title: "Connect TikTok") { step = .access }
        }
    }

    /// The ink app tile with the cream bookmark mark.
    private var appTile: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.stashInk)
            .frame(width: 88, height: 88)
            .overlay(
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.stashOnInk)
            )
            .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
    }

    // MARK: - Step 2 · What Stash will access

    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("What Stash will access")
                .font(.archivo(30, .heavy))
                .foregroundStyle(Color.stashInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 22) {
                AccessRow(
                    granted: true,
                    title: "Your favourite videos",
                    detail: "The videos you bookmarked, to organize them."
                )
                AccessRow(granted: false, title: "Not your messages")
                AccessRow(granted: false, title: "Not your profile or watch history")
            }
            .padding(.top, 30)

            discardNote.padding(.top, 30)

            Spacer()
            StashPrimaryButton(title: "Continue to TikTok") { step = .success }
        }
    }

    private var discardNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.stashOnAccent)
            Text("Everything except your favourites is discarded the moment it arrives.")
                .font(.archivo(13.5, .semibold))
                .foregroundStyle(Color.stashOnAccent)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.categoryCoding, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Step 3 · Connected

    private var success: some View {
        VStack(spacing: 0) {
            Spacer()
            Circle()
                .fill(Color.categoryCoding)
                .frame(width: 84, height: 84)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color.stashOnAccent)
                )
                .shadow(color: Color.categoryCoding.opacity(0.35), radius: 15, y: 8)
            Text("Connected")
                .font(.archivo(30, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 22)
            Text("1,868 favourites imported")
                .font(.archivo(14, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .padding(.top, 6)
            InfoChip(text: "New saves sync automatically", systemImage: "arrow.triangle.2.circlepath", tint: .categoryCoding)
                .padding(.top, 18)

            previewList.padding(.top, 30)

            Spacer()
            StashPrimaryButton(title: "Open library") { dismiss() }
        }
    }

    /// A short taste of the organized library, using the app's category tiles.
    private var previewList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Micro(text: "First in", size: 10, tracking: 1.8)
            PreviewRow(category: .recipe, title: "15-minute miso ramen", subtitle: "Recipe · 5 ingredients")
            Divider().overlay(Color.stashInk.opacity(0.12))
            PreviewRow(category: .music, title: "Midnight City", subtitle: "M83 · synthwave")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

/// One line in the "what Stash will access" list: a granted check or a muted cross.
private struct AccessRow: View {
    let granted: Bool
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 14) {
            ZStack {
                if granted {
                    Circle().fill(Color.categoryCoding)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.stashOnAccent)
                } else {
                    Circle().strokeBorder(Color.stashInk.opacity(0.35), lineWidth: 1.5)
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.stashInk.opacity(0.5))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.archivo(17, .heavy))
                    .foregroundStyle(granted ? Color.stashInk : Color.stashInk.opacity(0.55))
                if let detail {
                    Text(detail)
                        .font(.archivo(13.5))
                        .foregroundStyle(Color.stashInk.opacity(0.6))
                        .lineSpacing(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A library-style preview row with a category tile (offline-safe placeholder).
private struct PreviewRow: View {
    let category: Category
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: nil, category: category, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.archivo(16, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.archivo(12.5))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }
}

#Preview {
    ConnectFlowView()
}
