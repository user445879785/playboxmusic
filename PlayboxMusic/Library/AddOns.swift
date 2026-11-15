import Foundation

/// Optional services the app can use, picked in Settings › Add-ons.
///
/// Every add-on is built into the app (iOS doesn't let an app download new
/// code), so "adding" one switches it on. Each says what it sends and to
/// which site; none needs an account and none sends your library, stars or
/// listening history anywhere.
enum AddOn: String, CaseIterable, Identifiable, Sendable {
    case smartSearch
    case internetArchive
    case lrclib
    case lyricsOvh
    case coverFinder
    case coverArtArchive

    enum Kind: String, CaseIterable, Identifiable {
        case search = "Search"
        case sources = "Song Sources"
        case lyrics = "Lyrics"
        case artwork = "Artwork"
        var id: String { rawValue }
    }

    var id: String { rawValue }

    var kind: Kind {
        switch self {
        case .smartSearch: .search
        case .internetArchive: .sources
        case .lrclib, .lyricsOvh: .lyrics
        case .coverFinder, .coverArtArchive: .artwork
        }
    }

    var name: String {
        switch self {
        case .smartSearch: "Smart Search"
        case .internetArchive: "Internet Archive"
        case .lrclib: "LRCLIB Synced Lyrics"
        case .lyricsOvh: "Lyrics.ovh"
        case .coverFinder: "iTunes Cover Finder"
        case .coverArtArchive: "Cover Art Archive"
        }
    }

    var maker: String {
        switch self {
        case .smartSearch: "Powered by Deezer"
        case .internetArchive: "archive.org"
        case .lrclib: "lrclib.net"
        case .lyricsOvh: "lyrics.ovh"
        case .coverFinder: "Apple iTunes Search"
        case .coverArtArchive: "MusicBrainz"
        }
    }

    var symbol: String {
        switch self {
        case .smartSearch: "wand.and.stars"
        case .internetArchive: "building.columns.fill"
        case .lrclib: "quote.bubble.fill"
        case .lyricsOvh: "text.quote"
        case .coverFinder: "photo.fill"
        case .coverArtArchive: "photo.stack.fill"
        }
    }

    /// One line for the list.
    var tagline: String {
        switch self {
        case .smartSearch: "Most played songs first, typos fixed."
        case .internetArchive: "Search and download free, legal music."
        case .lrclib: "Lyrics that scroll with the song."
        case .lyricsOvh: "Plain lyrics when nothing else has them."
        case .coverFinder: "Finds covers for songs without one."
        case .coverArtArchive: "Album covers from MusicBrainz."
        }
    }

    /// What it does, for its page.
    var about: String {
        switch self {
        case .smartSearch:
            "Catalogue search lists the most played songs first, like Spotify, and understands typos: \"draek\" finds Drake. When a Soulseek search finds nothing, it fixes the spelling and asks Soulseek once more."
        case .internetArchive:
            "Adds an Archive tab to Search with millions of free recordings: live concerts, netlabel releases, public domain and Creative Commons albums. Downloads go straight into your library as MP3 or FLAC."
        case .lrclib:
            "Time-synced lyrics from an open, community-run database. Lyrics follow the song in the player and are saved on your phone, so they also work offline and in library search."
        case .lyricsOvh:
            "A second lyrics source, asked only when LRCLIB has nothing for a song. Its lyrics aren't synced."
        case .coverFinder:
            "When a song has no cover in its file or folder, looks it up in the iTunes catalogue by its artist and title."
        case .coverArtArchive:
            "A second cover source for albums the iTunes catalogue doesn't know, using MusicBrainz's open database."
        }
    }

    /// Exactly what leaves the phone.
    var sends: String {
        switch self {
        case .smartSearch: "The words you search for, to api.deezer.com."
        case .internetArchive: "The words you search for and the items you open, to archive.org."
        case .lrclib: "The title, artist, album and length of the song you open lyrics for, to lrclib.net."
        case .lyricsOvh: "The title and artist of the song, to api.lyrics.ovh."
        case .coverFinder: "The artist and title of a song with no cover, to itunes.apple.com."
        case .coverArtArchive: "The artist and album of a song with no cover, to musicbrainz.org and coverartarchive.org."
        }
    }

    /// The ones already part of the app stay on until you turn them off.
    var onByDefault: Bool {
        switch self {
        case .smartSearch, .lrclib, .coverFinder: true
        case .internetArchive, .lyricsOvh, .coverArtArchive: false
        }
    }

    private var storageKey: String { "addon." + rawValue }

    /// Safe to read from any thread (settings are thread-safe).
    var isOn: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? onByDefault
    }

    func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: storageKey)
    }
}

/// What the store and the Search tab watch, so turning an add-on on or off
/// shows up straight away.
@MainActor
final class AddOnStore: ObservableObject {
    static let shared = AddOnStore()

    @Published private(set) var installed: Set<AddOn>

    private init() {
        installed = Set(AddOn.allCases.filter(\.isOn))
    }

    func isOn(_ addOn: AddOn) -> Bool { installed.contains(addOn) }

    func set(_ addOn: AddOn, _ on: Bool) {
        addOn.set(on)
        if on { installed.insert(addOn) } else { installed.remove(addOn) }
    }
}
