import XCTest
import SwiftData
@testable import TikTokBrainKit

final class FilmPickTests: XCTestCase {
    func testCleanedTrimsDropsBlanksDeduplicatesStablyAndCapsResults() {
        let input = [
            FilmPick(title: "  Arrival  ", year: 2016),
            FilmPick(title: "arrival", year: 2016),
            FilmPick(title: "   ", year: 1999),
            FilmPick(title: "Dune", year: 1984),
            FilmPick(title: "Dune", year: 2021),
        ] + (0..<25).map { FilmPick(title: "Film \($0)") }

        let cleaned = FilmPick.cleaned(input)

        XCTAssertEqual(cleaned.count, FilmPick.maxPerVideo)
        XCTAssertEqual(Array(cleaned.prefix(3)), [
            FilmPick(title: "Arrival", year: 2016),
            FilmPick(title: "Dune", year: 1984),
            FilmPick(title: "Dune", year: 2021),
        ])
    }

    func testDecodeToleratesStringAndInvalidYearMetadata() throws {
        let json = #"[{"title":"  Arrival  ","year":"2016"},{"title":"Dune","year":50000},{"title":"Heat","year":"unknown"}]"#
            .data(using: .utf8)!

        let picks = try JSONDecoder().decode([FilmPick].self, from: json)

        XCTAssertEqual(picks, [
            FilmPick(title: "Arrival", year: 2016),
            FilmPick(title: "Dune"),
            FilmPick(title: "Heat"),
        ])
    }

    func testOldAnalysisPayloadDefaultsFilmsToEmpty() throws {
        let json = #"{"category":"film","title":"Three favorites","summary":"","topics":[]}"#
            .data(using: .utf8)!

        let analysis = try JSONDecoder().decode(Analysis.self, from: json)

        XCTAssertEqual(analysis.films, [])
        XCTAssertFalse(analysis.hasFilmPayload)
    }

    func testExplicitAnalysisMarksFilmPayloadWithoutAddingAMarkerToJSON() throws {
        let analysis = Analysis(category: .film, title: "No named films", summary: "", films: [])

        XCTAssertTrue(analysis.hasFilmPayload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) as? [String: Any]
        )
        XCTAssertNotNil(object["films"])
        XCTAssertNil(object["hasFilmPayload"])
    }

    func testNullFilmPayloadUsesLegacyMigrationMarker() throws {
        let json = #"{"category":"film","title":"Old response","summary":"","films":null}"#
            .data(using: .utf8)!

        let analysis = try JSONDecoder().decode(Analysis.self, from: json)

        XCTAssertFalse(analysis.hasFilmPayload)
        XCTAssertEqual(analysis.films, [])
    }

    func testMalformedFilmEntriesDoNotFailAnalysisDecode() throws {
        let json = #"{"category":"film","title":"Favorites","summary":"","topics":[],"films":[{"title":"Arrival","year":2016},null,"bad",{"title":99,"year":1995},{"title":"Heat","year":{}}]}"#
            .data(using: .utf8)!

        let analysis = try JSONDecoder().decode(Analysis.self, from: json)

        XCTAssertEqual(analysis.films, [
            FilmPick(title: "Arrival", year: 2016),
            FilmPick(title: "Heat"),
        ])
    }

    func testVideoKeepsNilMigrationMarkerAndDecodesStoredFilms() throws {
        let video = Video(
            videoID: "film-1",
            url: URL(string: "https://www.tiktok.com/@x/video/1")!,
            bookmarkedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(video.filmsJSON)
        XCTAssertEqual(video.films, [])

        video.filmsJSON = try JSONEncoder().encode([FilmPick(title: "Arrival", year: 2016)])
        XCTAssertEqual(video.films, [FilmPick(title: "Arrival", year: 2016)])
    }
}
