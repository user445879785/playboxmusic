import Foundation

/// An album or song from the public iTunes Search API (no account or key).
struct ITunesItem: Decodable, Identifiable, Hashable {
    let wrapperType: String?
    let artistId: Int?
    let collectionId: Int?
    let trackId: Int?
    let artistName: String?
    let collectionName: String?
    let trackName: String?
    let artworkUrl100: String?
    let releaseDate: String?
    let primaryGenreName: String?
    let trackCount: Int?
    let trackNumber: Int?
    let discNumber: Int?
    let trackTimeMillis: Int?
    let collectionExplicitness: String?
    let trackExplicitness: String?
    let previewUrl: String?

    var id: Int { trackId ?? collectionId ?? artistId ?? 0 }
    var isSingle: Bool { (collectionName ?? "").hasSuffix("- Single") || (trackCount ?? 99) <= 3 }
    var releaseDateValue: Date? { releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) } }

    /// A minimal artist item used for navigation.
    static func artist(id: Int, name: String) -> ITunesItem {
        ITunesItem(wrapperType: "artist", artistId: id, collectionId: nil, trackId: nil, artistName: name,
                   collectionName: nil, trackName: nil, artworkUrl100: nil, releaseDate: nil,
                   primaryGenreName: nil, trackCount: nil, trackNumber: nil, discNumber: nil,
                   trackTimeMillis: nil, collectionExplicitness: nil, trackExplicitness: nil, previewUrl: nil)
    }
    var isExplicit: Bool { (trackExplicitness ?? collectionExplicitness) == "explicit" }
    var durationSeconds: Int? { trackTimeMillis.map { $0 / 1000 } }

    var durationText: String? {
        durationSeconds.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }

    func artworkURL(size: Int) -> URL? {
        guard let artworkUrl100 else { return nil }
        return URL(string: artworkUrl100.replacingOccurrences(
            of: #"\d+x\d+bb"#, with: "\(size)x\(size)bb", options: .regularExpression
        ))
    }

    var releaseText: String? {
        guard let releaseDate, let date = ISO8601DateFormatter().date(from: releaseDate) else { return nil }
        return "Released " + date.formatted(date: .abbreviated, time: .omitted)
    }

    func trackMeta() -> TrackMeta {
        TrackMeta(title: trackName ?? collectionName ?? "", artist: artistName, album: collectionName, artworkURL: artworkURL(size: 1000))
    }
}

enum ITunesCatalog {
    private struct Response: Decodable { let results: [ITunesItem] }

    static func search(_ term: String, entity: String, limit: Int = 25) async throws -> [ITunesItem] {
        try await get("search", [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: country)
        ])
    }

    static func albumTracks(_ collectionId: Int) async throws -> [ITunesItem] {
        try await get("lookup", [
            URLQueryItem(name: "id", value: String(collectionId)),
            URLQueryItem(name: "entity", value: "song")
        ])
        .filter { $0.wrapperType == "track" }
        .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
    }

    static func lookup(ids: [Int]) async throws -> [ITunesItem] {
        guard !ids.isEmpty else { return [] }
        let items = try await get("lookup", [
            URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "country", value: country)
        ])
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    static func artistAlbums(_ artistId: Int) async throws -> [ITunesItem] {
        try await get("lookup", [
            URLQueryItem(name: "id", value: String(artistId)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "100")
        ])
        .filter { $0.wrapperType == "collection" }
        .sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
    }

    static func artistSongs(_ artistId: Int) async throws -> [ITunesItem] {
        try await get("lookup", [
            URLQueryItem(name: "id", value: String(artistId)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25")
        ])
        .filter { $0.wrapperType == "track" }
    }

    // MARK: Charts (US iTunes RSS)

    static let country = "us"

    static let genres: [(name: String, id: Int, symbol: String)] = [
        ("Pop", 14, "star"), ("Hip-Hop/Rap", 18, "music.mic"), ("R&B/Soul", 15, "heart"),
        ("Rock", 21, "guitars"), ("Alternative", 20, "waveform"), ("Dance", 17, "figure.dance"),
        ("Electronic", 7, "bolt"), ("Country", 6, "sun.max"), ("Latin", 12, "flame"),
        ("K-Pop", 51, "sparkles"), ("Jazz", 11, "music.quarternote.3"), ("Classical", 5, "pianokeys"),
        ("Reggae", 24, "leaf"), ("Soundtrack", 16, "film"), ("Singer/Songwriter", 10, "music.note")
    ]

    private struct Feed: Decodable {
        struct Body: Decodable { let entry: [Entry]? }
        struct Entry: Decodable {
            struct ID: Decodable {
                struct Attributes: Decodable {
                    let id: String
                    enum CodingKeys: String, CodingKey { case id = "im:id" }
                }
                let attributes: Attributes
            }
            let id: ID
        }
        let feed: Body
    }

    /// Top songs or albums, optionally for one genre, with full catalog details.
    static func chart(_ kind: String, genre: Int? = nil, limit: Int = 50) async throws -> [ITunesItem] {
        var path = "https://itunes.apple.com/\(country)/rss/\(kind)/limit=\(limit)"
        if let genre { path += "/genre=\(genre)" }
        let (data, response) = try await URLSession.shared.data(from: URL(string: path + "/json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let ids = try JSONDecoder().decode(Feed.self, from: data).feed.entry?.compactMap { Int($0.id.attributes.id) } ?? []
        return try await lookup(ids: ids)
    }

    /// Recent albums from the charts, newest first.
    static func newReleases() async throws -> [ITunesItem] {
        let albums = try await chart("topalbums", limit: 100)
        let recent = albums.filter { ($0.releaseDateValue ?? .distantPast) > Date().addingTimeInterval(-60 * 86_400) }
        return (recent.count >= 6 ? recent : albums)
            .sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
    }

    /// Best-effort cover lookup for files that carry no artwork.
    static func bestMatch(_ term: String) async -> ITunesItem? {
        guard !term.isEmpty else { return nil }
        return try? await search(term, entity: "song", limit: 1).first
    }

    private static func get(_ path: String, _ query: [URLQueryItem]) async throws -> [ITunesItem] {
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = query
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).results
    }
}

/// Search help from Deezer's public catalogue (no account or key). The
/// iTunes search has no popularity numbers and gives up on typos; Deezer's
/// forgives them and ranks every song by how much it is played. Only the
/// words you search for are sent.
enum SearchHelper {
    struct Hit: Decodable, Sendable {
        struct Artist: Decodable, Sendable { let name: String }
        let title: String
        let rank: Int?
        let artist: Artist
    }

    private struct Response: Decodable { let data: [Hit] }

    /// The most played songs matching the words, typos forgiven.
    static func popular(_ term: String) async -> [Hit] {
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "50")]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.data
    }

    static func key(artist: String?, title: String?) -> String {
        MusicText.clean((artist ?? "") + " " + (title ?? "")).lowercased()
    }

    /// What you most likely meant: the top match's artist, with its title
    /// too when you typed more words than the artist's name has.
    static func corrected(_ term: String, from hits: [Hit]) -> String? {
        guard let best = hits.first else { return nil }
        let typed = MusicText.clean(term).split(separator: " ").count
        let artistWords = MusicText.clean(best.artist.name).split(separator: " ").count
        let guess = typed > artistWords ? best.artist.name + " " + best.title : best.artist.name
        return MusicText.clean(guess).lowercased() == MusicText.clean(term).lowercased() ? nil : MusicText.clean(guess)
    }

    /// Puts the most played songs first; songs Deezer doesn't know keep
    /// their place after them.
    static func byPopularity(_ songs: [ITunesItem], hits: [Hit]) -> [ITunesItem] {
        var ranks: [String: Int] = [:]
        for hit in hits {
            let id = key(artist: hit.artist.name, title: hit.title)
            ranks[id] = max(ranks[id] ?? 0, hit.rank ?? 0)
        }
        let scored = songs.enumerated().map { offset, song in
            (song, ranks[key(artist: song.artistName, title: song.trackName)] ?? -1, offset)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map { $0.0 }
    }
}

enum MusicText {
    /// Strips track numbers, bracketed tags and separators so names search well.
    static func clean(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*\d{1,3}([\-\.]\d{1,3})?\s*[\-\.]?\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+-\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
        return text.split(separator: " ").joined(separator: " ")
    }
}
