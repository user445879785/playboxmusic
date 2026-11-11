import AVFoundation
import Foundation

// MARK: Headphone profiles

/// A correction curve for a pair of headphones, applied under every other
/// setting so the music is tuned for what you are actually wearing.
enum HeadphoneProfile: String, CaseIterable, Identifiable, Codable {
    case off, soundcoreK20i, soundcoreP20i, airPods, airPodsPro

    var id: String { rawValue }

    var name: String {
        switch self {
        case .off: "None"
        case .soundcoreK20i: "Soundcore K20i"
        case .soundcoreP20i: "Soundcore P20i"
        case .airPods: "AirPods (open fit)"
        case .airPodsPro: "AirPods Pro"
        }
    }

    var detail: String {
        switch self {
        case .off: "No headphone correction."
        case .soundcoreK20i: "Open fit loses bass and the 3–6 kHz range is sharp. Adds body, softens snare snap and hi-hat ticks."
        case .soundcoreP20i: "Sealed fit is boomy with dull highs. Tightens the bass and opens up the top."
        case .airPods: "Open fit loses deep bass. Adds sub bass gently."
        case .airPodsPro: "Already well tuned. Only a light touch."
        }
    }

    /// Gains for the ten bands, 32 Hz … 16 kHz.
    var gains: [Float] {
        switch self {
        case .off: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .soundcoreK20i: [3, 4, 3, 1, 0, 0, -1, -3, -2, 1]
        case .soundcoreP20i: [-1, -2, -2, -1, 0, 0, 1, 2, 2, 2]
        case .airPods: [3, 3, 1, 0, 0, 0, 0, -1, 0, 0]
        case .airPodsPro: [0, 0, 0, 0, 0, 0, 0, -1, 0, 0]
        }
    }
}

// MARK: Genres

/// A broad genre read from a song's tags or the catalog, used to give each
/// song its own character on top of the measured correction.
enum MusicGenre: String, CaseIterable {
    case hipHop, electronic, rnb, pop, rock, metal, jazz, classical, acoustic, vocal, unknown

    var name: String {
        switch self {
        case .hipHop: "Hip-Hop"
        case .electronic: "Electronic"
        case .rnb: "R&B / Soul"
        case .pop: "Pop"
        case .rock: "Rock"
        case .metal: "Metal"
        case .jazz: "Jazz / Blues"
        case .classical: "Classical"
        case .acoustic: "Acoustic / Folk"
        case .vocal: "Vocal / Raï"
        case .unknown: "Unknown"
        }
    }

    /// Gentle character curves (±3 dB at most).
    var tilt: [Float] {
        switch self {
        case .hipHop: [3, 3, 2, 0, -1, 0, 0, 0, 1, 1]
        case .electronic: [3, 2, 1, 0, -1, 0, 0, 1, 2, 2]
        case .rnb: [2, 2, 2, 1, 0, 0, 0, 0, 0, 1]
        case .pop: [1, 1, 1, 0, 0, 0, 0, 0, 1, 1]
        case .rock: [1, 1, 0, -1, -1, 0, 1, 1, 1, 1]
        case .metal: [1, 1, 0, -1, -2, 0, 1, 0, 0, 0]
        case .jazz: [1, 1, 0, 1, 0, 0, 0, 0, 1, 1]
        case .classical: [1, 1, 0, 0, 0, 0, 0, 0, 1, 1]
        case .acoustic: [0, 1, 1, 1, 0, 0, 0, 0, 1, 1]
        case .vocal: [0, 1, 1, 0, 0, 1, 1, 0, 0, 0]
        case .unknown: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        }
    }

    static func from(_ text: String?) -> MusicGenre {
        guard let text, !text.isEmpty else { return .unknown }
        let value = " " + text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9&ïé]+"#, with: " ", options: .regularExpression) + " "
        func has(_ words: [String]) -> Bool { words.contains { value.contains(" \($0) ") } }
        if has(["hip hop", "hiphop", "rap", "trap", "drill", "grime", "boom bap"]) { return .hipHop }
        if has(["r&b", "rnb", "r b", "soul", "funk", "neo soul"]) { return .rnb }
        if has(["metal", "metalcore", "hardcore"]) { return .metal }
        if has(["house", "techno", "edm", "electronic", "electronica", "electro", "dance", "dubstep",
                "trance", "drum and bass", "dnb", "garage", "ambient", "synthwave", "phonk"]) { return .electronic }
        if has(["rock", "punk", "grunge", "indie", "alternative", "alt"]) { return .rock }
        if has(["jazz", "blues", "swing", "bossa nova"]) { return .jazz }
        if has(["classical", "orchestra", "orchestral", "opera", "soundtrack", "score", "piano"]) { return .classical }
        if has(["acoustic", "folk", "country", "singer songwriter"]) { return .acoustic }
        if has(["raï", "rai", "chaabi", "arabic", "maghreb", "andalous", "gnawa", "kabyle", "vocal", "chanson"]) { return .vocal }
        if has(["pop", "k pop", "kpop", "j pop", "latin", "reggaeton", "afrobeats", "afrobeat"]) { return .pop }
        return .unknown
    }
}

// MARK: Auto EQ

/// What Auto EQ chose for one song.
struct AutoEQResult: Equatable {
    var gains: [Float]
    var genre: MusicGenre
    var measured: Bool
    /// One line for the UI, such as "Bass +2 · Mids 0 · Highs −2".
    var summary: String
}

enum AutoEqualizer {
    /// Average octave-band balance of well-mastered modern music, in dB
    /// relative to the mid range. Songs are nudged toward this balance.
    static let reference: [Float] = [3, 8, 7, 4, 2, 0, -3, -6, -10, -18]

    /// Largest cut and boost per band. Deep bass and the top octave get
    /// small boosts: earbuds distort there and lossy files have little to lift.
    private static let maxBoost: [Float] = [3, 4, 4, 3, 3, 3, 3, 3, 3, 2]
    private static let maxCut: [Float] = [-5, -5, -5, -4, -4, -4, -5, -5, -5, -4]

    /// Builds the per-song curve from the measured spectrum and the genre.
    static func result(bands: [Float]?, genre: MusicGenre) -> AutoEQResult {
        var gains = [Float](repeating: 0, count: 10)
        var measured = false
        if let bands, bands.count == 10, bands.allSatisfy({ $0.isFinite }) {
            measured = true
            let target = centred(reference)
            let actual = centred(bands)
            var difference = zip(target, actual).map { $0 - $1 }
            // Smooth neighbours so one odd band does not make a jagged curve.
            difference = difference.indices.map { index in
                let left = difference[max(0, index - 1)]
                let right = difference[min(9, index + 1)]
                return 0.25 * left + 0.5 * difference[index] + 0.25 * right
            }
            // Correct about half the gap: enough to fix a dull or harsh
            // master without flattening the artist's choices.
            gains = difference.enumerated().map { index, value in
                min(maxBoost[index], max(maxCut[index], value * 0.5))
            }
        }
        let tiltScale: Float = measured ? 0.6 : 1
        gains = zip(gains, genre.tilt).map { $0 + $1 * tiltScale }
        gains = gains.map { ($0 * 2).rounded() / 2 }
        return AutoEQResult(gains: gains, genre: genre, measured: measured, summary: summary(gains))
    }

    static func summary(_ gains: [Float]) -> String {
        func average(_ range: ClosedRange<Int>) -> Float {
            range.map { gains[$0] }.reduce(0, +) / Float(range.count)
        }
        func text(_ value: Float) -> String {
            let rounded = value.rounded()
            if rounded == 0 { return "0" }
            return (rounded > 0 ? "+" : "−") + String(Int(abs(rounded)))
        }
        return "Bass \(text(average(0...2))) · Mids \(text(average(3...6))) · Highs \(text(average(7...9)))"
    }

    /// Subtracts the mid-range average (250 Hz – 4 kHz).
    private static func centred(_ values: [Float]) -> [Float] {
        let mid = values[3...7].reduce(0, +) / 5
        return values.map { $0 - mid }
    }
}

// MARK: Genre lookup

/// Reads a song's genre from its tags, then from the iTunes catalog if the
/// file has none. Results are remembered between launches.
actor GenreResolver {
    static let shared = GenreResolver()

    private var memory: [String: String]
    private let defaultsKey = "autoeq.genres"

    init() {
        memory = UserDefaults.standard.dictionary(forKey: "autoeq.genres") as? [String: String] ?? [:]
    }

    func genre(for url: URL, artist: String?, title: String?) async -> MusicGenre {
        let key = url.lastPathComponent
        if let known = memory[key] { return MusicGenre.from(known) }
        var text = await Self.tagGenre(url)
        if MusicGenre.from(text) == .unknown, let title, !title.isEmpty {
            let term = [artist, title].compactMap { $0 }.joined(separator: " ")
            text = (try? await ITunesCatalog.search(term, entity: "song", limit: 1).first?.primaryGenreName) ?? text
        }
        // Remember only real answers, so an offline miss is retried later.
        if let text, MusicGenre.from(text) != .unknown {
            memory[key] = text
            UserDefaults.standard.set(memory, forKey: defaultsKey)
        }
        return MusicGenre.from(text)
    }

    /// Looks through every tag format (ID3, iTunes, Vorbis comments).
    private static func tagGenre(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items {
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                let key = (item.key as? String)?.lowercased() ?? ""
                let isGenre = identifier.contains("genre") || identifier.contains("tcon")
                    || identifier.contains("gen") || identifier.contains("gnre") || key == "genre" || key == "tcon"
                guard isGenre else { continue }
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    return id3Genre(value)
                }
                if let number = try? await item.load(.numberValue) {
                    // iTunes "gnre" atoms store the ID3v1 number plus one.
                    return id3Genre(String(number.intValue - 1))
                }
            }
        }
        return nil
    }

    /// Turns old ID3 references such as "(7)" or "17" into names.
    private static func id3Genre(_ value: String) -> String {
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        guard let number = Int(digits) else { return value }
        let table: [Int: String] = [
            0: "Blues", 1: "Rock", 2: "Country", 3: "Dance", 4: "Disco", 5: "Funk", 6: "Grunge",
            7: "Hip-Hop", 8: "Jazz", 9: "Metal", 10: "New Age", 11: "Oldies", 13: "Pop", 14: "R&B",
            15: "Rap", 16: "Reggae", 17: "Rock", 18: "Techno", 20: "Alternative", 24: "Soundtrack",
            26: "Ambient", 32: "Classical", 35: "House", 42: "Soul", 43: "Punk", 52: "Electronic",
            80: "Folk", 98: "Easy Listening", 127: "Drum and Bass", 129: "Hardcore"
        ]
        return table[number] ?? value
    }
}
