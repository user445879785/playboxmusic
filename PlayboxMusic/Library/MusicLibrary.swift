import Combine
import Foundation
import Security

struct Track: Identifiable, Hashable {
    let url: URL
    let addedAt: Date

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
}

/// Catalog details saved for a downloaded file (title, artist, album, cover).
struct TrackMeta: Codable, Hashable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var artworkURL: URL?
}

/// A list of songs you made, saved by each song's place in the library.
struct Playlist: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var items: [String]
    var created: Date
}

/// Lists audio files downloaded into Documents/Music (also visible in the Files app).
@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var metadata: [String: TrackMeta] = [:]
    @Published private(set) var favourites: Set<String> = []
    /// Snoozed songs (Spotify's 30-day Snooze): key → when the snooze ends.
    @Published private(set) var snoozed: [String: Double] = [:]
    /// Hidden songs: never played automatically until un-hidden.
    @Published private(set) var hidden: Set<String> = []
    @Published private(set) var playlists: [Playlist] = []
    let root: URL

    private var playlistsURL: URL { root.appendingPathComponent(".playbox-playlists.json") }

    private var metadataURL: URL { root.appendingPathComponent(".playbox-metadata.json") }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataURL),
           let saved = try? JSONDecoder().decode([String: TrackMeta].self, from: data) {
            metadata = saved
        }
        favourites = Set(UserDefaults.standard.stringArray(forKey: "music.favourites") ?? [])
        let now = Date().timeIntervalSince1970
        snoozed = (UserDefaults.standard.dictionary(forKey: "music.snoozed") as? [String: Double] ?? [:])
            .filter { $0.value > now }
        hidden = Set(UserDefaults.standard.stringArray(forKey: "music.hidden") ?? [])
        if let data = try? Data(contentsOf: playlistsURL),
           let saved = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = saved
        }
        reload()
    }

    var favouriteTracks: [Track] { tracks.filter(isFavourite) }

    func isFavourite(_ track: Track) -> Bool { favourites.contains(key(for: track.url)) }

    func setFavourite(_ track: Track, _ value: Bool) {
        let id = key(for: track.url)
        if value { favourites.insert(id) } else { favourites.remove(id) }
        UserDefaults.standard.set(Array(favourites), forKey: "music.favourites")
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String, with tracks: [Track] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: UUID(), name: trimmed.isEmpty ? "New Playlist" : trimmed,
                                items: tracks.map { key(for: $0.url) }, created: Date())
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = trimmed
        savePlaylists()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    func add(_ tracks: [Track], to id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].items += tracks.map { key(for: $0.url) }
        savePlaylists()
    }

    func removeFromPlaylist(_ id: UUID, at offsets: IndexSet) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].items.remove(atOffsets: offsets)
        savePlaylists()
    }

    func movePlaylistItems(_ id: UUID, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].items.move(fromOffsets: source, toOffset: destination)
        savePlaylists()
    }

    /// A playlist's songs that are still in the library, in order.
    func tracks(in playlist: Playlist) -> [Track] {
        let byKey = Dictionary(tracks.map { (key(for: $0.url), $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.items.compactMap { byKey[$0] }
    }

    func contains(_ track: Track, in playlist: Playlist) -> Bool {
        playlist.items.contains(key(for: track.url))
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: playlistsURL, options: .atomic)
        }
    }

    // MARK: Snooze and hide

    /// Days left on a song's snooze, or nil if it isn't snoozed.
    func snoozeDaysLeft(_ track: Track) -> Int? {
        guard let until = snoozed[key(for: track.url)] else { return nil }
        let left = until - Date().timeIntervalSince1970
        return left > 0 ? max(1, Int((left / 86_400).rounded(.up))) : nil
    }

    func isSnoozed(_ track: Track) -> Bool { snoozeDaysLeft(track) != nil }
    func isHidden(_ track: Track) -> Bool { hidden.contains(key(for: track.url)) }
    /// Left out of queues, shuffle, autoplay and mixes (still playable by tapping it).
    func isSkipped(_ track: Track) -> Bool { isHidden(track) || isSnoozed(track) }

    func snooze(_ track: Track, days: Int = 30) {
        snoozed[key(for: track.url)] = Date().addingTimeInterval(Double(days) * 86_400).timeIntervalSince1970
        UserDefaults.standard.set(snoozed, forKey: "music.snoozed")
    }

    func unsnooze(_ track: Track) {
        snoozed[key(for: track.url)] = nil
        UserDefaults.standard.set(snoozed, forKey: "music.snoozed")
    }

    func setHidden(_ track: Track, _ value: Bool) {
        let id = key(for: track.url)
        if value { hidden.insert(id) } else { hidden.remove(id) }
        UserDefaults.standard.set(Array(hidden), forKey: "music.hidden")
    }

    /// Songs to autoplay after the queue: same artist, then same folder, then
    /// favourites, then anything else not played recently.
    func similar(to track: Track, excluding played: [Track], limit: Int = 10) -> [Track] {
        let exclude = Set(played.suffix(50))
        let pool = tracks.filter { !exclude.contains($0) && !isSkipped($0) }
        let artist = meta(for: track)?.artist?.lowercased()
        let sameArtist = pool.filter { artist != nil && meta(for: $0)?.artist?.lowercased() == artist }
        let sameFolder = pool.filter { $0.url.deletingLastPathComponent() == track.url.deletingLastPathComponent() }
        let liked = pool.filter(isFavourite)
        var picked: [Track] = []
        for candidate in sameArtist.shuffled() + sameFolder + liked.shuffled() + pool.shuffled()
        where !picked.contains(candidate) {
            picked.append(candidate)
            if picked.count == limit { break }
        }
        return picked
    }

    /// The downloaded copy of a catalog song, if there is one.
    func downloaded(title: String?, artist: String?) -> Track? {
        guard let title = title?.lowercased() else { return nil }
        return tracks.first { track in
            guard let meta = meta(for: track) else { return false }
            return meta.title.lowercased() == title
                && (artist == nil || meta.artist?.lowercased() == artist?.lowercased())
        }
    }

    /// Whether a catalog song is already downloaded.
    func has(title: String?, artist: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return metadata.values.contains {
            $0.title.lowercased() == title && (artist == nil || $0.artist?.lowercased() == artist?.lowercased())
        }
    }

    func meta(for track: Track) -> TrackMeta? { metadata[key(for: track.url)] }

    func setMeta(_ meta: TrackMeta, for url: URL) {
        var meta = meta
        // Album downloads leave the title empty; fill it from the file's
        // name now and from its tags as soon as they are read.
        if meta.title.isEmpty {
            meta.title = TagReader.parse(url).title
            Task {
                let tags = await TagReader.meta(for: url)
                guard var current = metadata[key(for: url)] else { return }
                current.title = tags.title
                metadata[key(for: url)] = current
                save()
            }
        }
        metadata[key(for: url)] = meta
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(metadata) { try? data.write(to: metadataURL, options: .atomic) }
    }

    func title(of track: Track) -> String { meta(for: track)?.title ?? track.title }

    func subtitle(of track: Track) -> String {
        guard let meta = meta(for: track) else { return track.folder }
        let text = [meta.artist, meta.album].compactMap { $0 }.joined(separator: " — ")
        return text.isEmpty ? track.folder : text
    }

    /// Keys are relative to the Music folder because the app container path changes.
    private func key(for url: URL) -> String {
        let base = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    func reload() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            tracks = []
            return
        }
        var found: [Track] = []
        for case let url as URL in enumerator
        where SlskAudio.extensions.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            found.append(Track(url: url, addedAt: values?.contentModificationDate ?? .distantPast))
        }
        tracks = found.sorted { $0.addedAt > $1.addedAt }
        fillMissingMeta()
    }

    private var readingTags: Set<String> = []

    /// Reads tags (or parses names) for songs without saved details, so
    /// every song shows a proper title, artist and album.
    private func fillMissingMeta() {
        let missing = tracks.filter { metadata[key(for: $0.url)] == nil && !readingTags.contains(key(for: $0.url)) }
        guard !missing.isEmpty else { return }
        missing.forEach { readingTags.insert(key(for: $0.url)) }
        Task {
            for track in missing {
                let meta = await TagReader.meta(for: track.url)
                setMeta(meta, for: track.url)
            }
        }
    }

    func track(for url: URL) -> Track {
        tracks.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            ?? Track(url: url, addedAt: Date())
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        metadata[key(for: track.url)] = nil
        reload()
    }
}

/// Stores the Soulseek password in the Keychain rather than UserDefaults.
enum CredentialStore {
    private static let service = "com.playboxapp.music.soulseek"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
