import Foundation

extension CodeData {
    /// What kind of coding post this is; each kind is laid out differently on the detail
    /// screen. A checklist gets tick boxes, a howto numbered steps, a tools roundup one row
    /// per tool with a link, an explainer plain takeaways.
    public enum Kind: String, Codable, Sendable {
        case checklist, tools, howto, explainer
    }
}

/// One point a coding post makes: a thing to do, a tool, a step or a takeaway.
public struct CodeItem: Codable, Equatable, Sendable {
    /// For a tools roundup this is the tool's name as the post wrote it.
    public var text: String
    /// What the post adds about the item, or "" when it says nothing more.
    public var detail: String

    private enum CodingKeys: String, CodingKey { case text, detail }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: (try? values.decode(String.self, forKey: .text)) ?? "",
                  detail: (try? values.decode(String.self, forKey: .detail)) ?? "")
    }

    init(text: String, detail: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trim, drop blanks, drop repeats of the same text, cap — source order kept.
    public static func cleaned(_ raw: [CodeItem]) -> [CodeItem] {
        var seen = Set<String>()
        var result: [CodeItem] = []
        for item in raw {
            let clean = CodeItem(text: item.text, detail: item.detail)
            guard !clean.text.isEmpty, seen.insert(clean.key).inserted else { continue }
            result.append(clean)
            if result.count == CodeData.maxItems { break }
        }
        return result
    }

    /// Order, detail and spacing can change on a re-run; the text is the stable identity.
    /// Same normalization as `HaulPickState`'s product key.
    var key: String {
        text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

public extension Video {
    func isChecked(_ item: CodeItem) -> Bool {
        codeChecks.contains(item.key)
    }

    /// Ticks or clears one checklist item; the caller saves its ModelContext as usual.
    func setChecked(_ checked: Bool, for item: CodeItem) {
        var keys = codeChecks
        if checked { keys.insert(item.key) } else { keys.remove(item.key) }
        codeChecksJSON = keys.isEmpty ? nil : try? JSONEncoder().encode(keys.sorted())
    }

    private var codeChecks: Set<String> {
        guard let codeChecksJSON,
              let keys = try? JSONDecoder().decode([String].self, from: codeChecksJSON)
        else { return [] }
        return Set(keys)
    }
}

public extension CodeData {
    /// The kind the screens lay out: an item list with no readable kind reads as takeaways.
    var shape: Kind { kind ?? .explainer }

    /// The Code shelf's meta text — "checklist · 20", "6 tools", "4 steps" — or nil when the
    /// save has no items and the row should fall back to its link count.
    var shelfLabel: String? {
        guard !items.isEmpty else { return nil }
        let n = items.count
        switch shape {
        case .checklist: return "checklist · \(n)"
        case .tools: return "\(n) tool\(n == 1 ? "" : "s")"
        case .howto: return "\(n) step\(n == 1 ? "" : "s")"
        case .explainer: return "\(n) takeaway\(n == 1 ? "" : "s")"
        }
    }

    /// The detail screen's section header; a checklist carries its progress.
    func headline(checked: Int) -> String {
        switch shape {
        case .checklist: return "Checklist · \(checked) of \(items.count)"
        case .howto: return "Steps"
        case .tools: return shelfLabel ?? "Tools"
        case .explainer: return "Takeaways"
        }
    }
}
