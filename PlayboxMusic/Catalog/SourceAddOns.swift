import Foundation

/// A song source anyone can describe in a small JSON file and add from
/// Settings › Add-ons › Add from Link. It is only a description: which web
/// address to search, and where the title, artist, cover and audio are in
/// the answer. The app runs no code from it (iOS doesn't allow that).
///
///     {
///       "playbox": 1,
///       "id": "audius",
///       "name": "Audius",
///       "about": "Free music uploaded by artists.",
///       "homepage": "https://audius.co",
///       "search": {
///         "url": "https://api.audius.co/v1/tracks/search?query={query}",
///         "results": "data",
///         "title": "title",
///         "artist": "user.name",
///         "artwork": "artwork.480x480",
///         "audio": "https://api.audius.co/v1/tracks/{id}/stream",
///         "duration": "duration"
///       }
///     }
///
/// Fields are dotted paths into each result ("user.name", "files.0.url");
/// a value with {braces} is a template filled from the result. "results"
/// may point to a list or to an object whose values are the results.
struct SourceManifest: Codable, Identifiable, Hashable, Sendable {
    var playbox: Int?
    var id: String
    var name: String
    var about: String?
    var homepage: String?
    /// An SF Symbol name for its tile.
    var icon: String?
    var search: Search

    struct Search: Codable, Hashable, Sendable {
        var url: String
        var results: String?
        var title: String
        var artist: String?
        var artwork: String?
        var audio: String
        var duration: String?
        /// "s" (default) or "ms".
        var durationUnit: String?
        var format: String?
        /// Live radio and other streams: they play, they don't download.
        var stream: Bool?
    }

    /// The sites it talks to, for "What it sends".
    var hosts: [String] {
        let addresses = [search.url, search.audio, search.artwork ?? ""]
        let found = addresses.compactMap { address -> String? in
            guard address.hasPrefix("http") else { return nil }
            return URL(string: address.replacingOccurrences(of: #"\{[^}]*\}"#, with: "x", options: .regularExpression))?.host
        }
        return Array(Set(found)).sorted()
    }
}

/// One song (or stream) a source add-on found.
struct SourceHit: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String?
    let artwork: URL?
    let audio: URL
    let duration: Double?
    let format: String?
    let isStream: Bool
    let source: String
}

enum SourceAddOnError: LocalizedError {
    case nothingFound
    case unreadable

    var errorDescription: String? {
        switch self {
        case .nothingFound: "No add-on was found there. Paste the add-on's JSON, or a link to its JSON or web page."
        case .unreadable: "That link couldn't be opened."
        }
    }
}

enum SourceAddOns {
    // MARK: Reading add-ons

    /// Add-ons from whatever was pasted: a link (to JSON, a GitHub page or a
    /// web page that contains or links to the JSON), or the JSON itself.
    static func manifests(from input: String) async throws -> [SourceManifest] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme, scheme.hasPrefix("http") {
            let page = try await fetch(rawLink(url))
            let found = parse(page)
            if !found.isEmpty { return found }
            // A web page that links to its add-on file.
            if let link = firstMatch(#"<link[^>]+rel=["']playbox-addon["'][^>]+href=["']([^"']+)["']"#, in: page)
                ?? firstMatch(#"href=["']([^"']+\.playbox\.json)["']"#, in: page),
               let target = URL(string: link, relativeTo: url)?.absoluteURL {
                let linked = parse(try await fetch(rawLink(target)))
                if !linked.isEmpty { return linked }
            }
            throw SourceAddOnError.nothingFound
        }
        let found = parse(text)
        if found.isEmpty { throw SourceAddOnError.nothingFound }
        return found
    }

    /// GitHub file pages and gists show HTML; their raw copy is the JSON.
    private static func rawLink(_ url: URL) -> URL {
        let text = url.absoluteString
        if text.contains("github.com"), text.contains("/blob/") {
            let raw = text.replacingOccurrences(of: "://github.com/", with: "://raw.githubusercontent.com/")
                .replacingOccurrences(of: "/blob/", with: "/")
            return URL(string: raw) ?? url
        }
        if text.contains("gist.github.com"), !text.hasSuffix("/raw") {
            return URL(string: text + "/raw") ?? url
        }
        return url
    }

    private static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { throw SourceAddOnError.unreadable }
        return text
    }

    /// JSON (one add-on or a list), or JSON tucked inside HTML.
    static func parse(_ text: String) -> [SourceManifest] {
        if let found = decode(text) { return found }
        // In a <script type="application/json"> tag, or shown in <pre>/<code>.
        let blocks = matches(#"<script[^>]*type=["']application/(?:playbox\+)?json["'][^>]*>([\s\S]*?)</script>"#, in: text)
            + matches(#"<(?:pre|code)[^>]*>([\s\S]*?)</(?:pre|code)>"#, in: text)
        for block in blocks {
            if let found = decode(unescape(stripTags(block))) { return found }
        }
        // Anything between the first { and the last }.
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let found = decode(unescape(String(text[start...end]))) {
            return found
        }
        return []
    }

    private static func decode(_ text: String) -> [SourceManifest]? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let one = try? decoder.decode(SourceManifest.self, from: data) { return [one] }
        if let many = try? decoder.decode([SourceManifest].self, from: data), !many.isEmpty { return many }
        struct Wrapped: Decodable { let addons: [SourceManifest] }
        if let wrapped = try? decoder.decode(Wrapped.self, from: data), !wrapped.addons.isEmpty { return wrapped.addons }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Searching

    /// Asks one source for the words and reads its answer.
    static func search(_ manifest: SourceManifest, for query: String) async -> [SourceHit] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let address = manifest.search.url.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: address) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("PlayboxMusic/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let spec = manifest.search
        let listValue = spec.results.flatMap { $0.isEmpty ? json : value(at: $0, in: json) } ?? json
        let list: [Any]
        if let array = listValue as? [Any] {
            list = array
        } else if let object = listValue as? [String: Any] {
            list = Array(object.values)
        } else {
            return []
        }

        return list.prefix(40).enumerated().compactMap { offset, item -> SourceHit? in
            guard let title = text(spec.title, in: item), !title.isEmpty,
                  let audioText = text(spec.audio, in: item),
                  let audio = URL(string: audioText, relativeTo: url)?.absoluteURL,
                  audio.scheme?.hasPrefix("http") == true else { return nil }
            var duration = spec.duration.flatMap { text($0, in: item) }.flatMap(Double.init)
            if spec.durationUnit == "ms" { duration = duration.map { $0 / 1000 } }
            return SourceHit(
                id: "\(manifest.id)#\(offset)#\(audio.absoluteString)",
                title: title.replacingOccurrences(of: "File:", with: ""),
                artist: spec.artist.flatMap { text($0, in: item) },
                artwork: spec.artwork.flatMap { text($0, in: item) }.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL },
                audio: audio,
                duration: duration,
                format: spec.format.flatMap { text($0, in: item) ?? $0 },
                isStream: spec.stream ?? false,
                source: manifest.name
            )
        }
    }

    /// A field's text: a dotted path, or a template with {paths} in it.
    private static func text(_ field: String, in item: Any) -> String? {
        if field.contains("{") {
            var output = field
            for path in matches(#"\{([^}]+)\}"#, in: field) {
                guard let piece = value(at: path, in: item).flatMap(string) else { return nil }
                output = output.replacingOccurrences(of: "{\(path)}", with: piece)
            }
            return output
        }
        return value(at: field, in: item).flatMap(string)
    }

    private static func string(_ value: Any) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// "user.name", "files.0.url" → the value in the JSON.
    private static func value(at path: String, in json: Any) -> Any? {
        var current: Any? = json
        for part in path.split(separator: ".").map(String.init) {
            if let object = current as? [String: Any] {
                current = object[part]
            } else if let array = current as? [Any], let index = Int(part), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    // MARK: Downloading

    /// Saves a found song into Music/<source>/ and returns where it went.
    static func download(_ hit: SourceHit, into root: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: hit.audio)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        // The file type from the address, else from what the server says it sent.
        var ext = hit.audio.pathExtension.lowercased()
        if !SlskAudio.extensions.contains(ext) {
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            ext = type.contains("flac") ? "flac" : type.contains("ogg") ? "ogg" : type.contains("wav") ? "wav"
                : type.contains("mp4") || type.contains("m4a") || type.contains("aac") ? "m4a" : "mp3"
        }
        let safe: (String) -> String = { MusicText.clean($0).replacingOccurrences(of: "/", with: "-") }
        let name = [hit.artist.map(safe), safe(hit.title)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        let folder = root.appendingPathComponent(safe(hit.source), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent((name.isEmpty ? "Song" : name) + "." + ext)
        var copy = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(name) \(copy).\(ext)")
            copy += 1
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}

/// The source add-ons you added, saved on the phone.
@MainActor
final class SourceAddOnStore: ObservableObject {
    static let shared = SourceAddOnStore()

    @Published private(set) var manifests: [SourceManifest] = []
    @Published private(set) var disabled: Set<String> = []

    private struct Saved: Codable {
        var manifests: [SourceManifest]
        var disabled: [String]
    }

    private let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("addons.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            manifests = saved.manifests
            disabled = Set(saved.disabled)
        }
    }

    /// The ones switched on.
    var enabled: [SourceManifest] { manifests.filter { !disabled.contains($0.id) } }

    func isOn(_ id: String) -> Bool { manifests.contains { $0.id == id } && !disabled.contains(id) }

    func install(_ new: [SourceManifest]) {
        for manifest in new {
            manifests.removeAll { $0.id == manifest.id }
            manifests.append(manifest)
            disabled.remove(manifest.id)
        }
        save()
    }

    func set(_ id: String, on: Bool) {
        if on { disabled.remove(id) } else { disabled.insert(id) }
        save()
    }

    func remove(_ id: String) {
        manifests.removeAll { $0.id == id }
        disabled.remove(id)
        save()
    }

    private func save() {
        let snapshot = Saved(manifests: manifests, disabled: Array(disabled))
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }
}
