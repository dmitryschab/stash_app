import Foundation
import Testing
@testable import TikTokBrainKit

@Suite struct MusicServiceTests {
    let link = MusicPickResolver.songLink(for: "https://music.apple.com/us/album/thuggin/1435160486?i=1435160492")

    @Test func appleMusicUnwrapsTheSongLink() {
        let url = MusicService.appleMusic.url(title: "Thuggin", artist: "Freddie Gibbs", link: link)
        #expect(url.absoluteString == "https://music.apple.com/us/album/thuggin/1435160486?i=1435160492")
    }

    @Test func spotifySearchesEvenWithALink() {
        let url = MusicService.spotify.url(title: "Reflections / Secret", artist: "X", link: link)
        #expect(url.absoluteString == "https://open.spotify.com/search/Reflections%20%2F%20Secret%20X")
    }

    @Test func songLinkFallsBackToSpotifySearchWithoutALink() {
        #expect(MusicService.songLink.url(title: "A", artist: "B", link: link) == link)
        #expect(MusicService.songLink.url(title: "A", artist: "B", link: nil).host == "open.spotify.com")
    }

    @Test func appleMusicSearchesWithoutALink() {
        #expect(MusicService.appleMusic.url(title: "A", artist: "B", link: nil).absoluteString
                == "https://music.apple.com/search?term=A%20B")
    }
}
