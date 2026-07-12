// DataDownloadGuideView.swift
//
// "Get your TikTok data" — the walkthrough testers need before their first import.
// TikTok's export is the only historical-import path until Data Portability sync
// ships, and it arrives as a zip the Files app must uncompress first. Set List
// style: numbered ink circles, micro headers, one accent card for the wait step.

import SwiftUI

struct DataDownloadGuideView: View {
    @Environment(\.dismiss) private var dismiss

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

                    section("Request it", steps: [
                        "In TikTok: Profile → ☰ → Settings and privacy",
                        "Account → Download your data",
                        "Select file format: JSON — this one matters",
                        "\"All data\" or anything that includes Activity — then Request data",
                    ]).padding(.top, 22)

                    waitCard.padding(.top, 18)

                    section("Bring it into Stash", steps: [
                        "Back in Download your data → Download data tab → download the .zip",
                        "Open the Files app, find the zip in Downloads",
                        "Long-press the zip → Uncompress",
                        "In Stash: Import → Import TikTok export → pick user_data_tiktok.json inside the extracted folder",
                    ]).padding(.top, 22)

                    privacyNote.padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(_ title: String, steps: [String]) -> some View {
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

#Preview {
    DataDownloadGuideView()
}
