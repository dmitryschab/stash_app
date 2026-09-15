import Foundation

/// An explicit choice by the user. An extracted product starts unmarked (nil).
public enum HaulPickState: String, Codable, CaseIterable, Sendable {
    case want
    case bought
}

public extension Video {
    func haulState(for pick: BuyPick) -> HaulPickState? {
        haulStates[Self.haulKey(for: pick)]
    }

    /// Changes this video's local shortlist; the caller saves its ModelContext as usual.
    /// Passing nil removes the choice without hiding the extracted product.
    func setHaulState(_ state: HaulPickState?, for pick: BuyPick) {
        var states = haulStates
        states[Self.haulKey(for: pick)] = state
        haulStatesJSON = states.isEmpty ? nil : try? JSONEncoder().encode(states)
    }

    private var haulStates: [String: HaulPickState] {
        guard let haulStatesJSON,
              let states = try? JSONDecoder().decode([String: HaulPickState].self, from: haulStatesJSON)
        else { return [:] }
        return states
    }

    /// Array order, prices, categories and links can change during reanalysis. The product's
    /// name is the available stable identity. Same-named duplicates in one video intentionally
    /// share a choice; a genuinely renamed product starts unmarked.
    private static func haulKey(for pick: BuyPick) -> String {
        pick.name.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
