// ShareViewController.swift
//
// The whole share extension. It writes the shared link to the app-group inbox and dismisses;
// the app picks it up on its next foreground and runs the import.
//
// Deliberately does no networking and reads no credentials. The deep pass has to happen in the
// app regardless — reading on-screen text downloads the video and runs Vision over twelve
// keyframes, well past what an extension's memory budget survives — so submitting from here
// would buy one round trip in exchange for sharing the session token with a second process.
//
// The status label exists because the alternative is a silent failure: a link that is not a
// TikTok would otherwise dismiss exactly like one that was saved.

import TikTokBrainKit
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    /// Long enough to read three words, short enough that sharing still feels instant.
    private static let visibleDuration: Duration = .milliseconds(800)

    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        installLabel()
        Task { await run() }
    }

    private func run() async {
        guard let link = await sharedLink() else {
            return await finish(saying: "Not a TikTok link")
        }
        guard let inbox = SharedInbox() else {
            // Only reachable if the app group is missing from the signed entitlements.
            return await finish(saying: "Stash can't save right now")
        }
        do {
            try inbox.write(link)
            await finish(saying: "Saved to Stash")
        } catch {
            await finish(saying: "Stash can't save right now")
        }
    }

    /// The first TikTok link among the attachments. Both spellings are read because TikTok's own
    /// sheet is inconsistent: sometimes a `public.url`, sometimes the caption and the link
    /// together as one `public.plain-text` blob.
    private func sharedLink() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if let url = await provider.url(), TikTokLink.isSupported(url) { return url }
            if let text = await provider.text(), let url = TikTokLink.firstLink(in: text) { return url }
        }
        return nil
    }

    private func finish(saying message: String) async {
        label.text = message
        try? await Task.sleep(for: Self.visibleDuration)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func installLabel() {
        view.backgroundColor = .clear
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(card)
        card.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -18),
            label.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -28),
        ])
    }
}

// MARK: - Attachment reading

private extension NSItemProvider {
    func url() async -> URL? {
        let identifier = UTType.url.identifier
        guard hasItemConformingToTypeIdentifier(identifier) else { return nil }
        let item = try? await loadItem(forTypeIdentifier: identifier)
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        return nil
    }

    func text() async -> String? {
        let identifier = UTType.plainText.identifier
        guard hasItemConformingToTypeIdentifier(identifier) else { return nil }
        let item = try? await loadItem(forTypeIdentifier: identifier)
        if let text = item as? String { return text }
        if let text = item as? NSString { return text as String }
        return nil
    }
}
