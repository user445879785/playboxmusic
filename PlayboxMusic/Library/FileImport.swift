import Foundation
import UniformTypeIdentifiers

extension MusicLibrary {
    /// Every audio format the player can open, for the Files picker.
    static var importTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder]
        types += SlskAudio.extensions.compactMap { UTType(filenameExtension: $0) }
        return Array(Set(types))
    }

    /// Copies songs (or whole folders of songs) from Files into the library,
    /// under Music/Imported, and returns how many were added.
    @discardableResult
    func importFiles(_ urls: [URL]) -> Int {
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var count = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                // Keep the album folder's name so artist/album parsing still works.
                let folder = Self.unique(destination.appendingPathComponent(url.lastPathComponent, isDirectory: true))
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let file = files?.nextObject() as? URL {
                    guard SlskAudio.extensions.contains(file.pathExtension.lowercased()) else { continue }
                    if copy(file, into: folder) { count += 1 }
                }
            } else if SlskAudio.extensions.contains(url.pathExtension.lowercased()) {
                if copy(url, into: destination) { count += 1 }
            }
        }
        reload()
        return count
    }

    private func copy(_ file: URL, into folder: URL) -> Bool {
        let target = Self.unique(folder.appendingPathComponent(file.lastPathComponent))
        do {
            try FileManager.default.copyItem(at: file, to: target)
            return true
        } catch {
            return false
        }
    }

    /// "Song.mp3" → "Song 2.mp3" when the name is taken.
    private static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
