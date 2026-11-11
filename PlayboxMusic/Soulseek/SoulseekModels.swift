import Foundation

struct SlskSearchResult: Identifiable, Hashable, Sendable {
    let username: String
    let filename: String
    let size: UInt64
    let bitrate: UInt32?
    let duration: UInt32?
    let sampleRate: UInt32?
    let bitDepth: UInt32?
    let freeSlots: Bool
    let uploadSpeed: UInt32
    let queueLength: UInt32

    var id: String { username + "\u{1F}" + filename }

    /// Soulseek paths use backslashes regardless of the sharer's platform.
    private var components: [String] {
        filename.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
    }

    var title: String {
        let name = components.last ?? filename
        return (name as NSString).deletingPathExtension
    }

    var folder: String {
        components.dropLast().suffix(2).joined(separator: " / ")
    }

    var fileExtension: String {
        ((components.last ?? filename) as NSString).pathExtension.lowercased()
    }

    var isAudio: Bool { SlskAudio.extensions.contains(fileExtension) }

    var qualityText: String {
        var parts = [fileExtension.uppercased()]
        if let bitDepth, let sampleRate, bitDepth > 0, sampleRate > 0 {
            parts.append("\(bitDepth)-bit/\(String(format: "%g", Double(sampleRate) / 1000)) kHz")
        } else if let bitrate, bitrate > 0 {
            parts.append("\(bitrate) kbps")
        }
        if let duration, duration > 0 {
            parts.append(String(format: "%d:%02d", duration / 60, duration % 60))
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

enum SlskAudio {
    static let extensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "alac", "ogg", "oga", "opus", "wav", "aif", "aiff", "wma", "ape", "wv"
    ]
}

struct SlskTransfer: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case connecting
        case requested
        case queued(position: UInt32?)
        case transferring
        case completed(URL)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .completed, .failed: false
            default: true
            }
        }
    }

    let id = UUID()
    let result: SlskSearchResult
    var state: State = .connecting
    var token: UInt32?
    var size: UInt64
    var received: UInt64 = 0
    var bytesPerSecond: Double = 0
    var playWhenFinished: Bool

    var progress: Double {
        size > 0 ? min(Double(received) / Double(size), 1) : 0
    }

    var statusText: String {
        switch state {
        case .connecting: "Connecting to \(result.username)…"
        case .requested: "Requested"
        case .queued(let position):
            position.map { "Queued · position \($0)" } ?? "Queued by \(result.username)"
        case .transferring:
            "\(String(format: "%.1f%%", progress * 100)) · \(Self.bytes(received)) of \(Self.bytes(size)) · \(Self.bytes(UInt64(max(0, bytesPerSecond))))/s"
        case .completed: "Downloaded"
        case .failed(let reason): reason
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

/// Quality groups for choosing what to download, best first.
enum SlskQuality: String, CaseIterable, Identifiable, Comparable, Sendable {
    case hiRes = "Hi-Res Lossless"
    case lossless = "Lossless"
    case mp3_320 = "MP3 320"
    case high = "High"
    case standard = "Standard"
    case low = "Low"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .hiRes: "24-bit or above 48 kHz FLAC/ALAC"
        case .lossless: "CD quality FLAC, ALAC or WAV"
        case .mp3_320: "320 kbps MP3"
        case .high: "256 kbps and up, V0, AAC"
        case .standard: "160–255 kbps"
        case .low: "Below 160 kbps"
        }
    }

    var symbol: String {
        switch self {
        case .hiRes: "waveform.badge.plus"
        case .lossless: "waveform"
        case .mp3_320, .high: "music.note"
        case .standard, .low: "music.note.list"
        }
    }

    static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    static func of(_ result: SlskSearchResult) -> SlskQuality {
        let lossless: Set<String> = ["flac", "alac", "wav", "aif", "aiff", "ape", "wv"]
        let ext = result.fileExtension
        // An .m4a with a very high bitrate is ALAC.
        if lossless.contains(ext) || (ext == "m4a" && (result.bitrate ?? 0) > 500) {
            if (result.bitDepth ?? 16) > 16 || (result.sampleRate ?? 44_100) > 48_000 { return .hiRes }
            return .lossless
        }
        let bitrate = result.bitrate ?? 0
        if ext == "mp3", bitrate >= 315 { return .mp3_320 }
        if bitrate >= 250 { return .high }
        if bitrate == 0 { return .standard }
        return bitrate >= 160 ? .standard : .low
    }
}

/// Word-for-word matching: every word of the query must appear as a whole
/// word (accents and case ignored), so "star" doesn't match "starboy".
enum SlskMatch {
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func containsAll(_ query: String, in text: String, exact: Bool = true) -> Bool {
        let needles = words(query)
        guard !needles.isEmpty else { return true }
        if exact {
            let hay = Set(words(text))
            return needles.allSatisfy(hay.contains)
        }
        let hay = words(text).joined(separator: " ")
        return needles.allSatisfy { hay.contains($0) }
    }
}
