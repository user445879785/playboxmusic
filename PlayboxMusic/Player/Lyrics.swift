import CryptoKit
import Foundation

struct LyricLine: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let time: Double?
    let text: String
}

/// Synced lyrics from LRCLIB (lrclib.net), a free, open lyrics database.
actor LyricsService {
    static let shared = LyricsService()

    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
    }

    private var cache: [String: [LyricLine]] = [:]
    /// Lyrics that were found are kept on the phone (Application Support),
    /// so they open instantly, work offline and can be searched.
    private let directory: URL
    /// Every saved song's words (key → text), loaded the first time you
    /// search the library by lyrics.
    private var texts: [String: String]?

    private struct Saved: Codable {
        var key: String
        var lines: [LyricLine]
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
    }

    /// How a song's lyrics are filed: by artist and title, ignoring case.
    static func key(title: String, artist: String?) -> String {
        [artist ?? "", title].joined(separator: "|").lowercased()
    }

    private func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    /// The words of every song whose lyrics are saved, for library search.
    func savedTexts() -> [String: String] {
        if let texts { return texts }
        var loaded: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data) else { continue }
            loaded[saved.key] = saved.lines.map(\.text).joined(separator: "\n")
        }
        texts = loaded
        return loaded
    }

    func lyrics(title: String, artist: String?, album: String?, duration: Double?) async -> [LyricLine] {
        let key = Self.key(title: title, artist: artist)
        if let cached = cache[key] { return cached }
        if let data = try? Data(contentsOf: file(for: key)),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.lines.isEmpty {
            cache[key] = saved.lines
            return saved.lines
        }

        var lines: [LyricLine] = []
        if let artist {
            var query = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist)
            ]
            if let album { query.append(URLQueryItem(name: "album_name", value: album)) }
            if let duration, duration > 0 { query.append(URLQueryItem(name: "duration", value: String(Int(duration)))) }
            if let response: Response = await fetch("get", query) { lines = Self.parse(response) }
        }
        if lines.isEmpty {
            let term = [artist, title].compactMap { $0 }.joined(separator: " ")
            if let results: [Response] = await fetch("search", [URLQueryItem(name: "q", value: term)]),
               let best = results.first(where: { $0.syncedLyrics != nil }) ?? results.first {
                lines = Self.parse(best)
            }
        }
        cache[key] = lines
        // Only real lyrics are saved; a miss is asked again another day.
        if lines.contains(where: { $0.text != "♪ Instrumental ♪" }) {
            if let data = try? JSONEncoder().encode(Saved(key: key, lines: lines)) {
                try? data.write(to: file(for: key), options: .atomic)
            }
            texts?[key] = lines.map(\.text).joined(separator: "\n")
        }
        return lines
    }

    private func fetch<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Playbox Music (https://github.com/aminoulogie/playbox)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func parse(_ response: Response) -> [LyricLine] {
        if response.instrumental == true { return [LyricLine(id: 0, time: nil, text: "♪ Instrumental ♪")] }
        if let synced = response.syncedLyrics, !synced.isEmpty {
            var lines: [LyricLine] = []
            for raw in synced.split(separator: "\n") {
                // [mm:ss.xx] text
                guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
                let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
                guard stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) else { continue }
                let text = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
                lines.append(LyricLine(id: lines.count, time: minutes * 60 + seconds, text: text.isEmpty ? "♪" : text))
            }
            if !lines.isEmpty { return lines }
        }
        return (response.plainLyrics ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { LyricLine(id: $0.offset, time: nil, text: String($0.element)) }
            .filter { !$0.text.isEmpty }
    }
}
