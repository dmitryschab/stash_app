# Many songs from one TikTok

**Date:** 2026-07-28
**Status:** approved, implementing

## The problem

A TikTok recommending five jungle releases was saved as one album — "Jungle Skeletons: Fire
Various Selection, Vol. 1" by Silent Monkz — which appears nowhere in the video. The Music tab
then showed that album's real six-track iTunes tracklist as if it were the video's content: a
confident-looking screen built entirely on a guess.

Three causes, all in the analysis layer. None of them is OCR.

1. **One video can hold one track.** `Analysis.track` is a single `TrackData?`
   (`Core/Types.swift`). Five items cannot be represented at any accuracy.
2. **The prompt collapses lists on purpose.** `BoxClients.swift`: *"if the video is an
   album/artist RECOMMENDATION LIST (not one song), set track.title to the list's theme"*.
3. **The theme is then matched against iTunes with `limit=1` and no confidence check**
   (`AlbumResolver.album`). A search always returns something.

Verified against the source video (`https://www.tiktok.com/@reznikmusic/video/7666837555224136981`)
by running the shipped pipeline locally — yt-dlp metadata, twelve keyframes at the same offsets
`MediaFetcher(keyframeCount: 12)` uses, Vision OCR with the same recognizer settings. The
recognized text is checked in at `Tests/Fixtures/jungle-picks-ocr.txt` and contains every item:

- Dreamcore, Vol. 1
- Atlantis (I Need You) — LTJ Bukem
- Reflections / Secret Portraits — New Balance
- Genesis
- Polaris — KMC

The caption says so too: *"I've collected 5 music projects in the Jungle genre"* (Russian).

Adding `ru-RU` to the recognizer and disabling language correction was measured and changed
nothing material. **The OCR layer is not at fault and is not being touched.**

## What ships

A TikTok that recommends several releases saves all of them, each linked to a streaming service
when — and only when — the match is confident. One that recommends a single song behaves exactly
as it does today.

## Architecture

### 1. One shape for one item or many

`Analysis.track: TrackData?` is replaced by `Analysis.music: [MusicPick]`:

```swift
public struct MusicPick: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case album, track }
    public var kind: Kind
    public var title: String
    public var artist: String     // "" when the video does not say
    public var link: URL?         // nil when nothing matched confidently
}
```

The count is the only distinction between a single-song save and a list — there is no separate
"list" type to keep in sync. A video that is not music has an empty array.

`Video.trackJSON` is superseded by `Video.musicJSON`. `trackJSON` stays on the model and is read
as a one-element list whenever `musicJSON` is nil, so the library is never blank between this
shipping and the re-analysis finishing. Nothing writes `trackJSON` any more.

### 2. Prompt: extract, do not summarise

The collapse rule is replaced with: list every distinct music item the video recommends, in
on-screen order, each tagged `album` or `track`; artist `""` rather than guessed; at most 12.
Everything else in the prompt is unchanged.

The server-side fast-pass prompt (`services/webhook/api_v1.py`) is deliberately **not** changed.
It runs before any OCR exists and has only the caption to work from — it cannot see the names,
and asking it to try would invite exactly the invention this spec removes.

### 3. `MusicPickResolver` — the confidence gate

`MusicLinkResolver` and `AlbumResolver` merge into one resolver. Per pick: query iTunes with
`entity=album` or `entity=song` according to `kind`, then compare what came back against what was
asked for. Below threshold, or a contradicted artist, the link is dropped and the name stands
alone.

Scoring is token overlap on case-folded alphanumeric words — Jaccard over the two title token
sets, requiring ≥ 0.6, plus: if the pick names an artist, the result's artist must share a token
with it. Deliberately not an edit distance: "Reflections / Secret Portraits" vs "Reflections"
should pass, and "jungle selection vol 1" vs "Jungle Skeletons: Fire Various Selection, Vol. 1"
should not, and token overlap separates those two cases where character distance does not.

*ponytail: a fixed 0.6 with no tuning knob. If it turns out wrong, the number moves — a
configurable threshold is a setting nobody would ever change deliberately.*

The existing `AlbumResolver.tracklist(collectionID:)` survives untouched; the album detail screen
still needs it.

### 4. Music tab

- **One pick** — unchanged. Resolved to its album by `AlbumStore` and grouped across videos, so
  "1 of 6 tracks saved" keeps working.
- **Several picks** — one wall unit for the video, listing its items. Its items do **not** also
  appear as individual album cards; the set is the unit.

`SleeveArt` and `SleeveStyle` currently take a `MusicAlbum` but read only `title` and `artist`.
They are changed to take those two strings so both card kinds render through the same art.

The trade-off was named and accepted: an album recommended inside a list is findable through that
list, not through the main grid.

### 5. Re-analysis and how it is paid for

Every `/v1/chat/completions` call reserves one quota unit (`api_v1.py`), so a full-library pass
costs one unit per video against a 500 + 100/month budget. A `grant-quota` subcommand is added to
`manage_invites.py` — same operator, same table, same "runs on the box, never an API route" rule
as the invite commands — so the operator can fund the pass. The existing **Re-analyze library**
button then does the work from stored OCR and transcript text: no re-download, no re-OCR.

## Failure handling

| Failure | Behaviour |
|---|---|
| No confident match for a pick | Name shown, no link. The honest outcome, and the point of the change |
| iTunes unreachable | Pick keeps `link = nil`; the next resolve pass retries, as `AlbumStore` does today |
| Model returns more than 12 picks | Truncated to 12 |
| Model returns the old `track` object | Decoded as a one-element `music` array; the shape change cannot break an in-flight response |
| A pick has an empty title | Dropped before resolution — nothing to search for |

## Testing

- `MatchConfidence` — the gate, against the real failure: "Jungle Skeletons: Fire Various
  Selection, Vol. 1" must be rejected for a jungle-list theme, "Reflections" accepted for
  "Reflections / Secret Portraits", and a contradicted artist rejected regardless of title score.
- `MusicPick` / `Analysis` decoding — a five-item response, an empty array, a missing key, and a
  legacy single `track` object.
- `MusicPickResolver` — `entity=album` for `.album` and `entity=song` for `.track`, asserted on
  the outgoing request via a `URLProtocol` stub; a low-confidence hit yields `link == nil`.
- `PipelineRunner` — an analyzer returning five picks stores five, and resolution is attempted
  once per pick.
- Migration — a `Video` holding only legacy `trackJSON` reads back as one pick.

Fixtures `jungle-picks-ocr.txt` and `jungle-picks-meta.json` hold the real recognized text and
metadata from the source video, so the analyzer prompt can be exercised against genuine input
rather than invented strings.

Not automatically testable: whether the model actually extracts five picks from that text. That
is a prompt-quality question, checked by hand against the fixture and then on the device.

## Explicitly out of scope

- Creating real playlists on Spotify or Apple Music. Links out, nothing written to an account.
- Multi-item extraction for recipes or coding. Same shape of problem, no evidence it bites yet.
- Changing OCR settings, keyframe count, or the recognizer languages — measured, no gain.
- Tuning the fast-pass prompt to guess at music from captions alone.
