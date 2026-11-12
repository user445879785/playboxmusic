import AVFoundation
import CryptoKit
import ImageIO
import UIKit

/// Finds cover art: catalog URL, then a cover image in the album folder,
/// then embedded artwork, then an iTunes lookup.
///
/// Covers are shrunk to the size they are shown at and decoded off the main
/// thread, so lists scroll without hitches and a big library doesn't fill
/// memory with full-size images. Shrunk copies are kept on disk, so a cover
/// is only worked out once.
actor ArtworkResolver {
    static let shared = ArtworkResolver()

    /// The pixel sizes covers are kept at: list rows, tiles, the full player.
    enum Size: Int, Sendable {
        case small = 160
        case medium = 480
        case large = 1200

        /// The smallest size that still looks sharp at `points` on screen.
        static func fitting(_ points: CGFloat) -> Size {
            points <= 64 ? .small : (points <= 200 ? .medium : .large)
        }
    }

    /// Decoded covers, capped by their real size in memory.
    private final class Memory: @unchecked Sendable {
        let images = NSCache<NSString, UIImage>()
        init() { images.totalCostLimit = 72 * 1024 * 1024 }
    }

    private static let memory = Memory()

    private struct Loaded: Sendable {
        var image: UIImage?
        /// True when every source was tried and none has a cover.
        var nothingFound: Bool
    }

    /// Songs known to have no cover anywhere (remembered between launches)…
    private var misses: Set<String>
    /// …and songs that failed this session only (offline, tags not read yet).
    private var sessionMisses = Set<String>()
    private var running: [String: Task<Loaded, Never>] = [:]
    private let originals: URL
    private let thumbnails: URL
    private let missesURL: URL
    private var missSave: Task<Void, Never>?
    /// The iTunes cover lookup is rate limited; two at a time is plenty.
    private var lookupSlots = 2
    private var lookupWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("Artwork", isDirectory: true)
        let list = folder.appendingPathComponent("no-cover.json")
        originals = folder
        thumbnails = folder.appendingPathComponent("Thumbnails", isDirectory: true)
        missesURL = list
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Thumbnails", isDirectory: true),
                                                 withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: list),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            misses = Set(saved["songs"] ?? [])
        } else {
            misses = []
        }
    }

    // MARK: Asking for covers

    /// A cover that is already in memory, to show at once with no flash.
    static func cached(_ track: Track, size: Size) -> UIImage? {
        memory.images.object(forKey: "\(songID(track.url))|\(size.rawValue)" as NSString)
    }

    static func cached(_ url: URL, size: Size) -> UIImage? {
        memory.images.object(forKey: "\(url.absoluteString)|\(size.rawValue)" as NSString)
    }

    func image(for track: Track, meta: TrackMeta?, size: Size = .large) async -> UIImage? {
        let id = Self.songID(track.url)
        let key = "\(id)|\(size.rawValue)"
        if let hit = Self.memory.images.object(forKey: key as NSString) { return hit }
        if let task = running[key] { return await task.value.image }
        if misses.contains(id) || sessionMisses.contains(id) { return nil }

        let originals = originals, thumbnails = thumbnails
        let file = track.url
        let task = Task.detached(priority: .userInitiated) {
            await Self.load(file, meta: meta, id: id, size: size, originals: originals, thumbnails: thumbnails)
        }
        running[key] = task
        let loaded = await task.value
        running[key] = nil
        if let image = loaded.image {
            store(image, key: key)
        } else if loaded.nothingFound {
            misses.insert(id)
            saveMissesSoon()
        } else {
            sessionMisses.insert(id)
        }
        return loaded.image
    }

    /// A catalogue cover from the web, shrunk and cached like the rest.
    func remoteImage(_ url: URL, size: Size = .large) async -> UIImage? {
        let key = "\(url.absoluteString)|\(size.rawValue)"
        if let hit = Self.memory.images.object(forKey: key as NSString) { return hit }
        if let task = running[key] { return await task.value.image }
        let originals = originals
        let task = Task.detached(priority: .userInitiated) {
            Loaded(image: await Self.remote(url, size: size, originals: originals), nothingFound: false)
        }
        running[key] = task
        let loaded = await task.value
        running[key] = nil
        if let image = loaded.image { store(image, key: key) }
        return loaded.image
    }

    private func store(_ image: UIImage, key: String) {
        let pixels = Int(image.size.width * image.scale) * Int(image.size.height * image.scale)
        Self.memory.images.setObject(image, forKey: key as NSString, cost: pixels * 4)
    }

    private func saveMissesSoon() {
        missSave?.cancel()
        missSave = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.saveMisses()
        }
    }

    private func saveMisses() {
        if let data = try? JSONEncoder().encode(["songs": Array(misses)]) {
            try? data.write(to: missesURL, options: .atomic)
        }
    }

    private func acquireLookup() async {
        if lookupSlots > 0 {
            lookupSlots -= 1
            return
        }
        await withCheckedContinuation { lookupWaiters.append($0) }
    }

    private func releaseLookup() {
        if lookupWaiters.isEmpty { lookupSlots += 1 } else { lookupWaiters.removeFirst().resume() }
    }

    // MARK: Finding and shrinking (off the main thread and off this actor)

    /// Album folder plus file name: the same after the app is reinstalled,
    /// when the container's full path changes.
    private static func songID(_ url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func load(_ file: URL, meta: TrackMeta?, id: String, size: Size,
                             originals: URL, thumbnails: URL) async -> Loaded {
        let thumbnail = thumbnails.appendingPathComponent("\(digest(id))-\(size.rawValue).jpg")
        if let image = shrink(contentsOf: thumbnail, to: size) {
            return Loaded(image: image, nothingFound: false)
        }

        var image: UIImage?
        if let url = meta?.artworkURL { image = await remote(url, size: size, originals: originals) }
        if image == nil, let cover = folderCover(near: file) { image = shrink(contentsOf: cover, to: size) }
        if image == nil, let data = await embeddedCover(in: file) { image = shrink(data, to: size) }
        // Without the song's details the lookup is a guess; don't treat a
        // failed guess as final.
        var certain = meta != nil
        if image == nil {
            let term = [meta?.artist, meta?.title ?? MusicText.clean(file.deletingPathExtension().lastPathComponent)]
                .compactMap { $0 }.joined(separator: " ")
            if term.isEmpty {
                certain = false
            } else {
                await shared.acquireLookup()
                do {
                    if let url = try await ITunesCatalog.search(term, entity: "song", limit: 1).first?.artworkURL(size: 1000) {
                        image = await remote(url, size: size, originals: originals)
                        if image == nil { certain = false }
                    }
                } catch {
                    // Offline or rate limited: try again another time.
                    certain = false
                }
                await shared.releaseLookup()
            }
        }

        if let image, let data = image.jpegData(compressionQuality: 0.86) {
            try? data.write(to: thumbnail, options: .atomic)
        }
        return Loaded(image: image, nothingFound: image == nil && certain)
    }

    /// Downloads a cover once (kept in Caches/Artwork) and shrinks it.
    private static func remote(_ url: URL, size: Size, originals: URL) async -> UIImage? {
        let file = originals.appendingPathComponent(digest(url.absoluteString) + ".jpg")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            try? data.write(to: file, options: .atomic)
        }
        return shrink(contentsOf: file, to: size)
    }

    private static func folderCover(near url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let images = files.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        return images.first { name in
            ["cover", "folder", "front"].contains { name.lastPathComponent.lowercased().contains($0) }
        } ?? images.first
    }

    private static func embeddedCover(in url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    private static func shrink(contentsOf file: URL, to size: Size) -> UIImage? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, options) else { return nil }
        return shrink(source, to: size)
    }

    private static func shrink(_ data: Data, to size: Size) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return shrink(source, to: size)
    }

    /// Decodes straight to the wanted size (never the full image), here and
    /// now, so the main thread only has to draw it.
    private static func shrink(_ source: CGImageSource, to size: Size) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size.rawValue
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
