import Foundation

// Where a tap on a release goes. Chosen once, on the first tap, and changeable in Settings.

public enum MusicService: String, CaseIterable, Identifiable, Sendable {
    case spotify, appleMusic, youtubeMusic, songLink

    /// `UserDefaults` key; empty until the first tap has asked.
    public static let key = "musicService"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .youtubeMusic: return "YouTube Music"
        case .songLink: return "Every service (song.link)"
        }
    }

    /// The URL to open for a release, given its name and its resolved `song.link` (nil when
    /// nothing in the catalogue matched it).
    ///
    /// Spotify and YouTube Music get a search on the name: song.link's mapping to them missed
    /// every real album tested, and each app claims its `/search` path so a search lands in the
    /// app. Apple Music gets the exact record, unwrapped from the song.link the resolver built.
    public func url(title: String, artist: String, link: URL?) -> URL {
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        // One path component: titles contain "/" ("Reflections / Secret Portraits").
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        switch self {
        case .spotify:
            return URL(string: "https://open.spotify.com/search/\(encoded)")
                ?? URL(string: "https://open.spotify.com")!
        case .youtubeMusic:
            return URL(string: "https://music.youtube.com/search?q=\(encoded)")
                ?? URL(string: "https://music.youtube.com")!
        case .appleMusic:
            if let link, link.host == "song.link",
               let apple = URL(string: link.lastPathComponent), apple.host?.hasSuffix("apple.com") == true {
                return apple
            }
            return URL(string: "https://music.apple.com/search?term=\(encoded)")
                ?? URL(string: "https://music.apple.com")!
        case .songLink:
            return link ?? MusicService.spotify.url(title: title, artist: artist, link: nil)
        }
    }
}
