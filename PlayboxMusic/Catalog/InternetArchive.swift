import Foundation

/// The Internet Archive's free audio collection (archive.org): live
/// concerts, netlabels, public domain and Creative Commons music. No account
/// or key; only the search words and opened items are sent.
enum InternetArchive {
    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let creator: String?
        let downloads: Int
        var artworkURL: URL? { URL(string: "https://archive.org/services/img/\(id)") }
    }

    struct File: Identifiable, Hashable, Sendable {
        let name: String
        let title: String
        let format: String
        let size: Int64?
        let length: Double?
        var id: String { name }
        var isLossless: Bool { format.localizedCaseInsensitiveContains("flac") }
    }

    /// A text field the archive sends as one string or a list of them.
    private struct Text: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let one = try? container.decode(String.self) {
                value = one
            } else if let many = try? container.decode([String].self) {
                value = many.joined(separator: ", ")
            } else {
                value = nil
            }
        }
    }

    private struct SearchResponse: Decodable {
        struct Body: Decodable { let docs: [Doc] }
        struct Doc: Decodable {
            let identifier: String
            let title: Text?
            let creator: Text?
            let downloads: Int?
        }
        let response: Body
    }

    private struct MetadataResponse: Decodable {
        struct Entry: Decodable {
            let name: String
            let format: String?
            let title: Text?
            let size: Text?
            let length: Text?
        }
        let files: [Entry]?
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Audio items matching the words, most downloaded first.
    static func search(_ term: String) async throws -> [Item] {
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        let words = term.replacingOccurrences(of: "\"", with: "")
        components.queryItems = [
            URLQueryItem(name: "q", value: "(\(words)) AND mediatype:(audio)"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "downloads"),
            URLQueryItem(name: "sort[]", value: "downloads desc"),
            URLQueryItem(name: "rows", value: "40"),
            URLQueryItem(name: "output", value: "json")
        ]
        let decoded: SearchResponse = try await get(components.url!)
        return decoded.response.docs.map {
            Item(id: $0.identifier, title: $0.title?.value ?? $0.identifier,
                 creator: $0.creator?.value, downloads: $0.downloads ?? 0)
        }
    }

    /// An item's songs, in order, in every format it is offered in.
    static func files(of item: Item) async throws -> [File] {
        let url = URL(string: "https://archive.org/metadata/\(item.id)")!
        let decoded: MetadataResponse = try await get(url)
        return (decoded.files ?? []).compactMap { entry in
            let ext = (entry.name as NSString).pathExtension.lowercased()
            guard SlskAudio.extensions.contains(ext), let format = entry.format,
                  // Short previews the archive makes of every song.
                  !entry.name.contains("_sample") else { return nil }
            let stem = ((entry.name as NSString).lastPathComponent as NSString).deletingPathExtension
            return File(name: entry.name, title: entry.title?.value ?? stem, format: format,
                        size: entry.size?.value.flatMap { Int64($0) },
                        length: entry.length?.value.flatMap(Self.seconds))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "245.3" or "4:05" → seconds.
    private static func seconds(_ text: String) -> Double? {
        if let plain = Double(text) { return plain }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Downloads one song into Music/Internet Archive/<item>/ and returns
    /// where it was saved.
    static func download(_ file: File, of item: Item, into root: URL) async throws -> URL {
        let path = file.name.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let source = URL(string: "https://archive.org/download/\(item.id)/\(path)") else {
            throw URLError(.badURL)
        }
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let folderName = MusicText.clean(item.title).replacingOccurrences(of: "/", with: "-")
        let folder = root.appendingPathComponent("Internet Archive", isDirectory: true)
            .appendingPathComponent(folderName.isEmpty ? item.id : folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent((file.name as NSString).lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}
