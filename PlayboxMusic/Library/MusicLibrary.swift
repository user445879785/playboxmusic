import Combine
import Foundation
import Security

struct Track: Identifiable, Hashable, Sendable {
    let url: URL
    let addedAt: Date

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }

    // The same file is the same song, whenever the folder was last scanned.
    // (Comparing the date too made "now playing" marks vanish after a rescan.)
    static func == (a: Track, b: Track) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
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

/// How often and how recently a song was played, for smart playlists.
struct PlayStat: Codable, Sendable {
    var count: Int
    var last: Double
}

/// Playlists that fill themselves from what you add, star and play.
enum SmartPlaylist: String, CaseIterable, Identifiable, Hashable {
    case recentlyAdded, mostPlayed, rediscover, lossless

    var id: String { rawValue }

    var name: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .mostPlayed: "Most Played"
        case .rediscover: "Rediscover"
        case .lossless: "Lossless"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyAdded: "clock"
        case .mostPlayed: "flame"
        case .rediscover: "arrow.counterclockwise"
        case .lossless: "waveform"
        }
    }

    var detail: String {
        switch self {
        case .recentlyAdded: "The last 100 songs you added."
        case .mostPlayed: "What you play the most."
        case .rediscover: "Starred and well-played songs you haven't heard for a month."
        case .lossless: "FLAC, ALAC, WAV and AIFF files."
        }
    }
}

/// A library search result; `lyric` is the matching line when the words
/// were found in a song's saved lyrics instead of its title.
struct LibraryHit: Sendable {
    let track: Track
    let lyric: String?
}

/// Lists audio files downloaded into Documents/Music (also visible in the Files app).
@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = [] { didSet { titleIndex = nil } }
    @Published private(set) var metadata: [String: TrackMeta] = [:] { didSet { titleIndex = nil } }
    /// False until the first scan of the Music folder has finished.
    @Published private(set) var loaded = false
    @Published private(set) var favourites: Set<String> = []
    /// Snoozed songs (Spotify's 30-day Snooze): key → when the snooze ends.
    @Published private(set) var snoozed: [String: Double] = [:]
    /// Hidden songs: never played automatically until un-hidden.
    @Published private(set) var hidden: Set<String> = []
    @Published private(set) var playlists: [Playlist] = []
    let root: URL
    /// The Music folder's real path, worked out once (it used to be
    /// resolved on disk for every title, star and snooze lookup).
    private let rootPrefix: String
    private var keyCache: [URL: String] = [:]
    /// Lowercased title → songs, so catalogue rows find a downloaded copy
    /// without walking the whole library. Rebuilt when songs or details change.
    private var titleIndex: [String: [Track]]?
    private var plays: [String: PlayStat] = [:]
    private var scanGeneration = 0
    private var saveTask: Task<Void, Never>?
    /// Files are written one after another off the main thread, in order.
    private let disk = DispatchQueue(label: "playbox.library.disk", qos: .utility)

    private var playlistsURL: URL { root.appendingPathComponent(".playbox-playlists.json") }

    private var metadataURL: URL { root.appendingPathComponent(".playbox-metadata.json") }

    private var playsURL: URL { root.appendingPathComponent(".playbox-plays.json") }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rootPrefix = root.resolvingSymlinksInPath().path + "/"
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
        if let data = try? Data(contentsOf: playsURL),
           let saved = try? JSONDecoder().decode([String: PlayStat].self, from: data) {
            plays = saved
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
        let wanted = artist?.lowercased()
        return index()[title]?.first { wanted == nil || meta(for: $0)?.artist?.lowercased() == wanted }
    }

    /// Whether a catalog song is already downloaded.
    func has(title: String?, artist: String?) -> Bool {
        downloaded(title: title, artist: artist) != nil
    }

    private func index() -> [String: [Track]] {
        if let titleIndex { return titleIndex }
        var built: [String: [Track]] = [:]
        for track in tracks {
            guard let meta = metadata[key(for: track.url)] else { continue }
            built[meta.title.lowercased(), default: []].append(track)
        }
        titleIndex = built
        return built
    }

    func meta(for track: Track) -> TrackMeta? { metadata[key(for: track.url)] }

    /// Saves catalogue details for a file (used when a download finishes).
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
                saveNow()
            }
        }
        metadata[key(for: url)] = meta
        saveNow()
    }

    /// Writes the details file off the main thread.
    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = metadata, url = metadataURL
        disk.async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Saves shortly after a burst of changes instead of once per song.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    /// Call when the app goes to the background: nothing waits unsaved.
    func flush() {
        if saveTask != nil { saveNow() }
    }

    func title(of track: Track) -> String { meta(for: track)?.title ?? track.title }

    func subtitle(of track: Track) -> String {
        guard let meta = meta(for: track) else { return track.folder }
        let text = [meta.artist, meta.album].compactMap { $0 }.joined(separator: " — ")
        return text.isEmpty ? track.folder : text
    }

    /// Keys are relative to the Music folder because the app container path changes.
    func key(for url: URL) -> String {
        if let known = keyCache[url] { return known }
        let value = Self.relativeKey(url, prefix: rootPrefix)
        keyCache[url] = value
        return value
    }

    nonisolated private static func relativeKey(_ url: URL, prefix: String) -> String {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: Scanning

    /// Looks through the Music folder again, off the main thread.
    func reload() {
        Task { await refresh() }
    }

    /// Same as `reload`, for callers that want to wait for the new list.
    func refresh() async {
        scanGeneration += 1
        let generation = scanGeneration
        let root = root, prefix = rootPrefix
        let found = await Task.detached(priority: .userInitiated) { Self.scan(root, prefix: prefix) }.value
        // A newer scan is on its way; let that one publish.
        guard generation == scanGeneration else { return }
        for item in found { keyCache[item.track.url] = item.key }
        let list = found.map { $0.track }
        // Publishing an unchanged list would redraw every screen that shows songs.
        let same = list.count == tracks.count
            && zip(list, tracks).allSatisfy { $0.url == $1.url && $0.addedAt == $1.addedAt }
        if !same { tracks = list }
        if !loaded { loaded = true }
        fillMissingMeta()
    }

    nonisolated private static func scan(_ root: URL, prefix: String) -> [(track: Track, key: String)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [(track: Track, key: String)] = []
        for case let url as URL in enumerator
        where SlskAudio.extensions.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let track = Track(url: url, addedAt: values?.contentModificationDate ?? .distantPast)
            found.append((track, relativeKey(url, prefix: prefix)))
        }
        return found.sorted { $0.track.addedAt > $1.track.addedAt }
    }

    private var readingTags: Set<String> = []

    /// Reads tags (or parses names) for songs without saved details, so
    /// every song shows a proper title, artist and album. Tags are read a
    /// few songs at a time and published together: a big import redraws the
    /// lists a couple of times a second instead of once per song.
    private func fillMissingMeta() {
        let missing = tracks.filter {
            let id = key(for: $0.url)
            return metadata[id] == nil && !readingTags.contains(id)
        }
        guard !missing.isEmpty else { return }
        missing.forEach { readingTags.insert(key(for: $0.url)) }
        Task {
            var start = 0
            while start < missing.count {
                let chunk = Array(missing[start..<min(start + 16, missing.count)])
                start += chunk.count
                let read = await withTaskGroup(of: (URL, TrackMeta).self) { group -> [(URL, TrackMeta)] in
                    for track in chunk {
                        group.addTask { (track.url, await TagReader.meta(for: track.url)) }
                    }
                    var results: [(URL, TrackMeta)] = []
                    for await item in group { results.append(item) }
                    return results
                }
                var next = metadata
                // Keep details a download saved in the meantime.
                for (url, meta) in read where next[key(for: url)] == nil { next[key(for: url)] = meta }
                metadata = next
                scheduleSave()
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
        saveNow()
        // Take it out of the list straight away; no need to rescan the folder.
        tracks.removeAll { $0 == track }
    }

    // MARK: Play counts and smart playlists

    /// Counts one listen (the player calls this once a song is half heard).
    func recordPlay(_ track: Track) {
        let id = key(for: track.url)
        var stat = plays[id] ?? PlayStat(count: 0, last: 0)
        stat.count += 1
        stat.last = Date().timeIntervalSince1970
        plays[id] = stat
        let snapshot = plays, url = playsURL
        disk.async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    func tracks(in smart: SmartPlaylist) -> [Track] {
        let pool = tracks.filter { !isSkipped($0) }
        switch smart {
        case .recentlyAdded:
            return Array(pool.prefix(100))
        case .mostPlayed:
            return pool
                .compactMap { track in plays[key(for: track.url)].map { (track, $0.count) } }
                .sorted { $0.1 > $1.1 }
                .prefix(100)
                .map { $0.0 }
        case .rediscover:
            let monthAgo = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970
            return pool
                .compactMap { track -> (Track, Double)? in
                    let stat = plays[key(for: track.url)]
                    let loved = isFavourite(track) || (stat?.count ?? 0) >= 3
                    let last = stat?.last ?? 0
                    return loved && last < monthAgo ? (track, last) : nil
                }
                .sorted { $0.1 < $1.1 }
                .prefix(100)
                .map { $0.0 }
        case .lossless:
            let lossless: Set<String> = ["FLAC", "ALAC", "WAV", "AIF", "AIFF", "APE", "WV"]
            return pool.filter { lossless.contains($0.fileExtension) }
        }
    }

    // MARK: Search

    /// Songs whose title, artist or album contain the words, then songs
    /// whose saved lyrics do. The matching runs off the main thread.
    func search(_ needle: String) async -> [LibraryHit] {
        let rows = tracks.map { track -> (track: Track, text: String, lyricsKey: String) in
            let details = self.meta(for: track)
            return (track, title(of: track) + "\n" + subtitle(of: track),
                    LyricsService.key(title: details?.title ?? MusicText.clean(track.title), artist: details?.artist))
        }
        // Lyrics are only searched for real phrases, not one or two letters.
        let lyrics = needle.count >= 3 ? await LyricsService.shared.savedTexts() : [:]
        return await Task.detached(priority: .userInitiated) {
            var named: [LibraryHit] = []
            var sung: [LibraryHit] = []
            for row in rows {
                if row.text.localizedCaseInsensitiveContains(needle) {
                    named.append(LibraryHit(track: row.track, lyric: nil))
                } else if let text = lyrics[row.lyricsKey], text.localizedCaseInsensitiveContains(needle) {
                    let line = text.split(separator: "\n").first { $0.localizedCaseInsensitiveContains(needle) }
                    sung.append(LibraryHit(track: row.track, lyric: line.map(String.init)))
                }
            }
            return named + sung
        }.value
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
