# Film posters implementation plan

**Goal:** Build the approved compact film detail: one horizontal row of portrait posters, title/year beneath, followed by Watch on TikTok; no embedded video for film details.

**Architecture:** Add category-specific film picks to the existing analysis and cloud contracts. Resolve artwork on demand through Wikipedia's public MediaWiki API, conservatively matching film identity and year. Keep poster resolution separate from source extraction and cache successful catalogue lookups in memory.

**Tech stack:** Existing SwiftUI/iOS 17, SwiftData, SwiftPM, URLSession, Python/FastAPI/Pydantic. No new dependencies or API keys.

**Spec:** Approved screen design in the current task, including the user's compact-row and video-removal corrections.

## Constraints

- Preserve the existing Archivo typography, adaptive colors, and category accent.
- Film cards use approximately 100 × 150 pt artwork and a single scrolling row; support Dynamic Type.
- Show actual extracted titles, in source order, never fill an advertised count with guesses.
- Missing/ambiguous artwork retains a readable title placeholder.
- Changes to embedded video and button copy apply only to film details.
- Leave the pre-existing HaulComponents.swift edit intact. Do not deploy or publish in this implementation task.
- Existing stored records must decode without the new field. Use optional filmsJSON for lightweight migration.

## Shared interfaces

```swift
public struct FilmPick: Codable, Equatable, Sendable {
    public static let maxPerVideo = 20
    public var title: String
    public var year: Int?
    public init(title: String, year: Int? = nil)
    public static func cleaned(_ picks: [FilmPick]) -> [FilmPick]
}
// Analysis.films and CloudImportResult.films default to [].
// Video.filmsJSON: Data? = nil; Video.films: [FilmPick] decodes it.
public struct FilmRef: Equatable, Sendable {
    public let title: String
    public let year: Int?
    public let posterURL: URL?
    public let detailURL: URL
}
public actor FilmResolver {
    public static let shared: FilmResolver
    public init(session: URLSession = .shared)
    public func film(for pick: FilmPick) async throws -> FilmRef?
}
```

## Task 1: Source data and persistence

Owned files: Kit FilmPick.swift, Core/Types.swift, Core/Entities.swift, Pipeline.swift, CloudImport.swift and corresponding tests.

- [x] Add tests for old payloads, trimming/blank removal, stable deduplication, cap, optional year, cloud persistence and stale clearing.
- [x] Add the shared FilmPick type; trim titles, validate optional years, preserve source order and cap at 20.
- [x] Thread films through Analysis and cloud Codable contracts, defaulting absent fields to empty.
- [x] Persist local pipeline film picks, including empty results, and clear on recategorization/reset paths.
- [x] Apply cloud film picks without flattening richer local film picks on empty fast-pass results; clear on explicit recategorization away from film.
- [x] Run focused Swift tests.

## Task 2: Server extraction

Owned files: services/webhook/api_v1.py, cloud_import_models.py, cloud_import_pipeline.py and corresponding tests.

- [x] Add tests for cloud film payload normalization, defaults, caps, order, revision and forwarding.
- [x] Add films [{title, year}] to the shared prompt, only for movies explicitly named/shown; year is null unless stated. Exclude TV series, incidental mentions, invented artwork/links and padding to advertised counts.
- [x] Add matching Pydantic model, normalization, film payload forwarding and bump analysisRevision to 8.
- [x] Run relevant Python suites using the repository requirements.

## Task 3: Film UI

Owned files: App/Sources/FilmSection.swift, VideoDetailView.swift, SampleData.swift and optional app-only helpers.

- [x] Insert FilmSection for film details and omit WatchSection there. Use WATCH ON TIKTOK with external-link icon for film.
- [x] Show a single lazy horizontal row, approximately 100 × 150 pt posters, title/year, extracted count and accessible links to matched movie details.
- [x] Resolve poster refs on demand, keeping placeholders through loading/failure and preserving card order. Cancel work on navigation and react to changed film data.
- [x] ~~On-open legacy backfill~~ dropped: /v1/chat/completions charges one quota unit per call, so opening a save must not trigger it. Legacy film saves get films through the existing "Re-run pipeline".
- [x] Add film demo/preview and support films in seed-file loading.

## Task 4: Resolver and verification

Owned files: Kit FilmResolver.swift and FilmResolverTests.swift; root integration verification.

- [x] Test exact film identity, year disambiguation, ambiguous remakes, non-film results, missing artwork, HTTP failures and cache behavior using URLProtocol fixtures.
- [x] Query en.wikipedia.org/w/api.php with generator=search, intitle search, prop=pageimages|pageterms|extracts|info, pilicense=any, thumbnail size 300, descriptions, introductory plaintext and canonical URL.
- [x] Match normalized page title after film disambiguation suffix removal; require film description/intro. Refuse mismatched year or multiple different matching films without a year. Use HTTPS Wikimedia images and Wikipedia detail links only.
- [x] Cache successful refs and confirmed misses, not network failures; coalesce in-flight requests.
- [x] Run full Swift and backend tests, generate Xcode project if needed, compile simulator build and visually inspect the film screen.
- [x] Review the combined feature diff and document any remaining delivery requirements.
