// ImportView.swift
//
// The Import screen (pushed from Library), which doubles as pipeline status/history. It
// imports an extracted TikTok export (JSON file or folder), runs the pipeline via
// `PipelineRunner`, shows live progress and model-box reachability, and hosts the
// box-config settings sheet. Set List style: sync card, outlined status card, count grid.

import SwiftUI
import SwiftData
import Observation
import UniformTypeIdentifiers
import TikTokBrainKit

// MARK: - Box status

enum BoxStatus {
    case unknown, checking, online, offline

    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .online: "Online"
        case .offline: "Unreachable"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .stashInk.opacity(0.45)
        case .checking: .categoryMusic
        case .online: .categoryCoding
        case .offline: .categoryOther
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .online: "checkmark.circle.fill"
        case .offline: "wifi.exclamationmark"
        }
    }
}

// MARK: - Controller

@MainActor
@Observable
final class ImportController {
    var progress: (done: Int, total: Int)?
    var isImporting = false
    var boxStatus: BoxStatus = .unknown
    var lastError: String?
    var lastSummary: String?

    /// A lightweight reachability probe: any answer (even an error response) means the box is
    /// up; only a transport-level `unreachable` means it is offline.
    func pingBox(config: BoxConfig) async {
        boxStatus = .checking
        let analyzer = AnalyzerClient(config: config)
        do {
            _ = try await analyzer.analyze(meta: VideoMeta(caption: "ping"), transcript: nil, ocrText: nil)
            boxStatus = .online
        } catch let error as BoxError {
            switch error {
            case .unreachable:
                boxStatus = .offline
            case .badResponse(let status) where status == 401 || status == 403:
                // Reaching the box with a bad token is NOT online — surface it.
                boxStatus = .offline
            default:
                boxStatus = .online  // it answered; model hiccups still count as reachable
            }
        } catch {
            boxStatus = .offline
        }
    }

    func runImport(url: URL, container: ModelContainer, config: BoxConfig) async {
        guard !isImporting else { return }
        isImporting = true
        lastError = nil
        defer { isImporting = false; progress = nil }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let bookmarks: [Bookmark]
        do {
            let parser = ExportParser()
            if url.hasDirectoryPath {
                bookmarks = try parser.parse(zipAt: url)
            } else {
                bookmarks = try parser.parse(jsonData: Data(contentsOf: url))
            }
        } catch {
            lastError = "Could not read the export: \(error.localizedDescription)"
            return
        }

        let runner = PipelineRunner(deps: Self.makeDeps(config: config), container: container)
        let newCount: Int
        do {
            newCount = try await runner.ingest(bookmarks: bookmarks)
        } catch {
            lastError = "Could not save bookmarks: \(error.localizedDescription)"
            return
        }

        progress = (0, newCount)
        await runner.processAll { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
        lastSummary = "Imported \(bookmarks.count) bookmarks · \(newCount) new"
    }

    /// Builds the pipeline from the Kit's concrete clients. Shared with the per-video re-run.
    static func makeDeps(config: BoxConfig) -> PipelineDeps {
        PipelineDeps(
            enricher: Enricher(),
            media: MediaFetcher(),
            transcriber: TranscriberClient(config: config),
            analyzer: AnalyzerClient(config: config),
            musicResolver: MusicLinkResolver(),
            ocr: { try await FrameReader().recognizeText(in: $0) }
        )
    }
}

// MARK: - Box config storage

/// Default box configuration: the cloud pipeline API. The bearer token is compiled
/// in from the gitignored generated file (scripts/gen-box-token.sh); Settings can
/// override everything for local-box development.
enum BoxDefaults {
    static let baseURL = "https://stash.dmitrijs.dev/v1"
    static let chatModel = "google.gemma-4-26b-a4b"   // pinned server-side; informational
    static let whisperModel = "whisper-large-v3-turbo" // pinned server-side; informational
    static let apiKey = BoxToken.value
}

func makeBoxConfig(baseURL: String, chatModel: String, whisperModel: String,
                   apiKey: String = BoxDefaults.apiKey) -> BoxConfig {
    BoxConfig(
        baseURL: URL(string: baseURL) ?? URL(string: "http://localhost:9")!,
        chatModel: chatModel,
        whisperModel: whisperModel,
        apiKey: apiKey
    )
}

// MARK: - View

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var videos: [Video]
    @State private var controller = ImportController()
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showConnect = false
    @State private var showGuide = false

    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @AppStorage("boxApiKey") private var boxApiKey = BoxDefaults.apiKey
    @AppStorage("chatModel") private var chatModel = BoxDefaults.chatModel
    @AppStorage("whisperModel") private var whisperModel = BoxDefaults.whisperModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                connectCard.padding(.top, 16)
                importSection.padding(.top, 12)
                boxCard.padding(.top, 12)
                if let error = controller.lastError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .bold))
                        Text(error).font(.archivo(13, .semibold))
                    }
                    .foregroundStyle(Color.categoryRecipe)
                    .padding(.top, 14)
                }
                librarySection.padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, .folder],
            allowsMultipleSelection: false
        ) { handleImport($0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showConnect) { ConnectFlowView() }
        .sheet(isPresented: $showGuide) { DataDownloadGuideView() }
        .task { await controller.pingBox(config: config) }
    }

    // MARK: - Sections

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.stashInk)
                        .frame(width: 36, height: 36)
                        .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.stashInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            Text("Import")
                .font(.archivo(40, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    /// The TikTok sync card: green when importing (with the progress bar), an invitation otherwise.
    private var connectCard: some View {
        Button { showConnect = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Micro(text: "TikTok", size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7))
                    Spacer()
                    Micro(
                        text: controller.isImporting ? "Syncing" : "Not connected",
                        size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7)
                    )
                }
                Text(controller.isImporting ? "Syncing favorites" : "Connect your TikTok")
                    .font(.archivo(23, .heavy))
                    .foregroundStyle(Color.stashOnAccent)
                    .padding(.top, 9)
                Text(subtitleLine)
                    .font(.archivo(13, .semibold))
                    .foregroundStyle(Color.stashOnAccent.opacity(0.8))
                    .padding(.top, 4)
                if let progress = controller.progress, progress.total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.stashOnAccent.opacity(0.25))
                            Capsule().fill(Color.stashOnAccent)
                                .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                        }
                    }
                    .frame(height: 8)
                    .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .stashCard(fill: .categoryCoding)
        }
        .buttonStyle(.plain)
    }

    private var subtitleLine: String {
        if let progress = controller.progress {
            return "\(progress.done) of \(progress.total) processed"
        }
        if let summary = controller.lastSummary { return summary }
        return "Sync the videos you favorite — or import an export below."
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StashPrimaryButton(title: "Import TikTok export", systemImage: "square.and.arrow.down") {
                showImporter = true
            }
            .disabled(controller.isImporting)
            .opacity(controller.isImporting ? 0.5 : 1)

            Button { showGuide = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Micro(text: "How to get your TikTok data", size: 10, tracking: 1.2, color: .stashInk.opacity(0.7))
                }
                .foregroundStyle(Color.stashInk.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    private var boxCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Micro(text: "Model box", size: 10, tracking: 1.8)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: controller.boxStatus.symbol)
                        .font(.system(size: 12, weight: .bold))
                    Micro(text: controller.boxStatus.label, size: 10, tracking: 1.2, color: controller.boxStatus.color)
                }
                .foregroundStyle(controller.boxStatus.color)
            }
            Button {
                Task { await controller.pingBox(config: config) }
            } label: {
                Micro(text: "Check again", size: 10, tracking: 1.4, color: .stashInk)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(controller.boxStatus == .checking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashOutlineCard()
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Micro(text: "Library", size: 10, tracking: 1.8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(librarySegments, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(count(category))")
                            .font(.archivo(26, .heavy))
                            .foregroundStyle(Color.stashOnAccent)
                        Micro(text: category.displayName, size: 10, tracking: 1.4, color: .stashOnAccent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(category.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            let flagged = videos.filter(\.needsLook).count
            if flagged > 0 {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .bold))
                        Micro(text: "Needs a look", size: 10, tracking: 1.4, color: .categoryOther)
                    }
                    .foregroundStyle(Color.categoryOther)
                    Spacer()
                    Text("\(flagged)")
                        .font(.archivo(15, .heavy))
                        .foregroundStyle(Color.stashInk)
                        .monospacedDigit()
                }
                .stashOutlineCard()
            }
        }
    }

    // MARK: - Helpers

    private var config: BoxConfig {
        makeBoxConfig(baseURL: boxBaseURL, chatModel: chatModel, whisperModel: whisperModel, apiKey: boxApiKey)
    }

    private func count(_ category: Category) -> Int {
        videos.filter { !$0.needsLook && $0.category == category }.count
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let container = context.container
            let boxConfig = config
            Task { await controller.runImport(url: url, container: container, config: boxConfig) }
        case .failure(let error):
            controller.lastError = error.localizedDescription
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @AppStorage("boxApiKey") private var boxApiKey = BoxDefaults.apiKey
    @AppStorage("chatModel") private var chatModel = BoxDefaults.chatModel
    @AppStorage("whisperModel") private var whisperModel = BoxDefaults.whisperModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Stash cloud") {
                    field("Base URL", text: $boxBaseURL, placeholder: BoxDefaults.baseURL, disableAutocaps: true)
                    LabeledContent("API key") {
                        SecureField("token", text: $boxApiKey)
                            .multilineTextAlignment(.trailing)
                    }
                    field("Chat model", text: $chatModel, placeholder: BoxDefaults.chatModel)
                    field("Whisper model", text: $whisperModel, placeholder: BoxDefaults.whisperModel)
                }
                Section {
                    Text("Analysis and transcription run on the Stash cloud by default. Point the base URL at your own model box for local development — models are pinned server-side either way.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, disableAutocaps: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(disableAutocaps ? .never : .sentences)
        }
    }
}

#Preview {
    NavigationStack {
        ImportView()
    }
    .modelContainer(SampleData.previewContainer)
}
