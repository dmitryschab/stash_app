import Foundation

/// One movie explicitly named or shown by a video.
public struct FilmPick: Codable, Equatable, Sendable {
    public static let maxPerVideo = 20

    public var title: String
    public var year: Int?

    public init(title: String, year: Int? = nil) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.year = Self.validated(year)
    }

    public static func cleaned(_ picks: [FilmPick]) -> [FilmPick] {
        var seen = Set<Identity>()
        var result: [FilmPick] = []
        result.reserveCapacity(min(picks.count, maxPerVideo))

        for raw in picks {
            let pick = FilmPick(title: raw.title, year: raw.year)
            guard !pick.title.isEmpty else { continue }
            let identity = Identity(
                title: pick.title.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ),
                year: pick.year
            )
            guard seen.insert(identity).inserted else { continue }
            result.append(pick)
            if result.count == maxPerVideo { break }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case title, year }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTitle = (try? values.decode(String.self, forKey: .title)) ?? ""
        let decodedYear: Int?
        if let integer = try? values.decode(Int.self, forKey: .year) {
            decodedYear = integer
        } else if let string = try? values.decode(String.self, forKey: .year) {
            decodedYear = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            decodedYear = nil
        }
        self.init(title: decodedTitle, year: decodedYear)
    }

    private static func validated(_ year: Int?) -> Int? {
        guard let year, (1888...2100).contains(year) else { return nil }
        return year
    }

    private struct Identity: Hashable {
        let title: String
        let year: Int?
    }
}

extension KeyedDecodingContainer {
    /// Decode each pick independently so one malformed model entry cannot discard the analysis.
    func decodeFilmPicksIfPresent(forKey key: Key) -> [FilmPick] {
        guard var values = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var picks: [FilmPick] = []
        while !values.isAtEnd {
            guard let decoder = try? values.superDecoder() else { continue }
            if let pick = try? FilmPick(from: decoder) { picks.append(pick) }
        }
        return FilmPick.cleaned(picks)
    }
}
