// DataDownloadGuideView.swift
//
// "Get your TikTok data" — the walkthrough testers need before their first import.
// TikTok's export is the only historical-import path until Data Portability sync
// ships; Stash reads the zip as downloaded, so nothing has to be uncompressed.
// Set List style: numbered ink circles, micro headers, accent cards for the one
// setting that can waste two days and for the wait itself.

import SwiftUI

struct DataDownloadGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PipelineCenter.exportRequestedKey) private var exportRequestedAt = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Get your TikTok data")
                        .font(.archivo(28, .heavy))
                        .foregroundStyle(Color.stashInk)
                        .padding(.top, 8)
                    Text("Stash builds your library from the export TikTok gives you. It takes two minutes to request — TikTok prepares it in minutes to a couple of days.")
                        .font(.archivo(14))
                        .foregroundStyle(Color.stashInk.opacity(0.75))
                        .lineSpacing(4)
                        .padding(.top, 10)

                    formatCallout.padding(.top, 22)

                    section("Request it", steps: [
                        "In TikTok: Profile → ☰ → Settings and privacy",
                        "Account → Download your data",
                        "\"All data\" or anything that includes Activity — then Request data",
                    ]).padding(.top, 22)

                    openTikTokButton.padding(.top, 18)

                    waitCard.padding(.top, 18)

                    section("Bring it into Stash", steps: [
                        "Back in Download your data → Download data tab → download the .zip",
                        "Open the Files app, find the zip in Downloads",
                        "In Stash: Import → Choose your export → pick the zip",
                    ]).padding(.top, 22)

                    privacyNote.padding(.top, 24)

                    // Turns every empty tab into "waiting on TikTok" until the import lands, so
                    // the days between asking and receiving do not read as a broken app — and
                    // schedules the pair of nudges, because nothing else tells you it landed.
                    StashPrimaryButton(title: "I've requested it", systemImage: "checkmark") {
                        exportRequestedAt = Date().timeIntervalSince1970
                        PipelineCenter.shared.scheduleExportReminders()
                        dismiss()
                    }
                    .padding(.top, 28)

                    Text("Stash reminds you in 1 hour and again tomorrow.")
                        .font(.archivo(12, .semibold))
                        .foregroundStyle(Color.stashInk.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar {
                // Closing is leaving without doing the thing; "I've requested it" at the bottom
                // is the confirmation. A bold "Done" in the corner claimed otherwise.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var formatCallout: some View {
        guideFormatCallout(
            title: "Choose JSON, not TXT",
            body: "Stash cannot read a TXT export, and you would wait two days to find out.")
    }

    /// Straight to the page the three steps above describe. `arrow.up.right`: this leaves Stash.
    private var openTikTokButton: some View {
        Link(destination: URL(string: "https://www.tiktok.com/setting/download-your-data")!) {
            HStack(spacing: 8) {
                Text("Open TikTok settings".uppercased())
                    .font(.archivo(12, .heavy))
                    .tracking(1.2)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Color.stashInk)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5))
        }
    }

    private func section(_ title: String, steps: [String]) -> some View {
        guideSection(title, steps: steps)
    }

    private var waitCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.stashOnAccent)
            Text("TikTok prepares the export — usually within the hour, occasionally a day or two. You'll see it under \"Download data\" when it's ready.")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashOnAccent)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashCard(fill: .categoryMusic)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.6))
            Text("Stash reads only your Favorite Videos list from the export. Everything else in the file is ignored and never leaves your phone.")
                .font(.archivo(12.5))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .lineSpacing(3)
        }
    }
}

// MARK: - Shared pieces

/// Ink that stays ink. `categoryOther` is the one jewel that does not change between
/// themes, so text on it must not either: `stashInk` flips to cream in dark mode and all
/// but disappears against the amber.
private let calloutInk = Color(light: 0x201A12, dark: 0x1D0E06)

/// The one step that costs days when it is missed: a TXT or HTML export parses into nothing,
/// and the user only finds out after the wait. Promoted out of the numbered list, where it
/// read like any other step.
private func guideFormatCallout(title: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Micro(text: "The one setting that matters", size: 10, tracking: 1.8,
              color: calloutInk.opacity(0.7))
        Text(title)
            .font(.archivo(22, .heavy))
            .foregroundStyle(calloutInk)
        Text(body)
            .font(.archivo(13, .semibold))
            .foregroundStyle(calloutInk.opacity(0.75))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .stashCard(fill: .categoryOther)
}

private func guideSection(_ title: String, steps: [String]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Micro(text: title, size: 11, tracking: 2, color: .categoryCoding)
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1)")
                    .font(.archivo(13, .heavy))
                    .foregroundStyle(Color.stashOnAccent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.stashInk))
                Text(step)
                    .font(.archivo(14, .semibold))
                    .foregroundStyle(Color.stashInk)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Instagram

/// "Get your Instagram saves" — Meta's Accounts Center export, asked for with Saved alone so
/// it stays small. `ExportParser` reads `saved_posts.json` out of the zip; only reels come in.
/// No reminders here: those, and the "waiting on TikTok" empty states, are keyed to TikTok's
/// export and would say the wrong thing.
struct InstagramSavesGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Get your Instagram saves")
                        .font(.archivo(28, .heavy))
                        .foregroundStyle(Color.stashInk)
                        .padding(.top, 8)
                    Text("Stash builds your library from the export Instagram gives you. Ask for your saves alone and the file stays small.")
                        .font(.archivo(14))
                        .foregroundStyle(Color.stashInk.opacity(0.75))
                        .lineSpacing(4)
                        .padding(.top, 10)

                    guideFormatCallout(
                        title: "Choose JSON, not HTML",
                        body: "Stash cannot read an HTML export, and you would only find out after the wait.")
                        .padding(.top, 22)

                    guideSection("Request it", steps: [
                        "In Instagram: Profile → ☰ → Accounts Center",
                        "Your information and permissions → Export your information → Create export",
                        "Pick your profile → Export to device",
                        "Customize information: tick only Saved · Date range: All time · Format: JSON → Start export",
                    ]).padding(.top, 22)

                    waitCard.padding(.top, 18)

                    guideSection("Bring it into Stash", steps: [
                        "Accounts Center → Export your information → download the .zip",
                        "In Stash: Import → Choose your export → pick the zip",
                    ]).padding(.top, 22)

                    privacyNote.padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var waitCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.stashOnAccent)
            Text("Meta emails you and notifies you in Instagram when the export is ready. The download stays up for four days.")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashOnAccent)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashCard(fill: .categoryMusic)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.6))
            Text("Stash reads only your saved reels from the export — saved photo posts are skipped. Everything else in the file is ignored and never leaves your phone.")
                .font(.archivo(12.5))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .lineSpacing(3)
        }
    }
}

#Preview {
    DataDownloadGuideView()
}

#Preview("Instagram") {
    InstagramSavesGuideView()
}
