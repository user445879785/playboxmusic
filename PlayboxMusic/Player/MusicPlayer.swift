import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit
import VLCKit

/// One playback lane: player → time-pitch (beat matching) → gain trim
/// (volume matching) → DJ filters → echo → fader (crossfades).
@MainActor
private final class AudioDeck {
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    let trim = AVAudioUnitEQ(numberOfBands: 0)
    /// High-pass, low-pass and a bass-kill shelf for Spotify-style mixes.
    let filter = AVAudioUnitEQ(numberOfBands: 3)
    let delay = AVAudioUnitDelay()
    let fader = AVAudioMixerNode()
    private(set) var file: AVAudioFile?
    private(set) var url: URL?
    private var segmentStart: Double = 0
    private var pausedAt: Double?
    private var generation = 0
    /// The last position the engine reported, kept for when iOS stops the
    /// engine under us (a call, earbuds changing) and it can't be asked.
    private var lastTime: Double = 0

    private var engineRunning: Bool { player.engine?.isRunning == true }
    var isPaused: Bool { pausedAt != nil }

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var isActive: Bool { file != nil && engineRunning && player.isPlaying }

    var currentTime: Double {
        guard file != nil else { return 0 }
        if let pausedAt { return pausedAt }
        guard engineRunning, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: nodeTime) else {
            return lastTime
        }
        // Before a scheduled start the player's own clock is still negative.
        lastTime = min(duration, segmentStart + max(0, Double(time.sampleTime) / time.sampleRate))
        return lastTime
    }

    func attach(to engine: AVAudioEngine, output: AVAudioNode) {
        [player, timePitch, trim, filter, delay, fader].forEach(engine.attach)
        let highPass = filter.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = 20
        highPass.bandwidth = 0.5
        let lowPass = filter.bands[1]
        lowPass.filterType = .lowPass
        lowPass.frequency = 20000
        lowPass.bandwidth = 0.5
        let bass = filter.bands[2]
        bass.filterType = .lowShelf
        bass.frequency = 220
        bass.gain = 0
        delay.feedback = 50
        delay.lowPassCutoff = 6000
        delay.wetDryMix = 0
        resetEffects()
        engine.connect(timePitch, to: trim, format: nil)
        engine.connect(trim, to: filter, format: nil)
        engine.connect(filter, to: delay, format: nil)
        engine.connect(delay, to: fader, format: nil)
        engine.connect(fader, to: output, format: nil)
    }

    func load(_ url: URL, engine: AVAudioEngine) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        engine.connect(player, to: timePitch, format: file.processingFormat)
        self.file = file
        self.url = url
    }

    /// Plays from `seconds`, now or at an exact time on the audio clock.
    /// `onEnd` fires only if this segment reaches its end.
    func play(from seconds: Double, at when: AVAudioTime? = nil, onEnd: @escaping @MainActor () -> Void) {
        // Starting a player while the engine is stopped raises an exception.
        guard let file, engineRunning else { return }
        player.stop()
        generation += 1
        let token = generation
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(seconds, duration - 0.05)) * rate)
        let frames = AVAudioFrameCount(max(1, file.length - startFrame))
        segmentStart = Double(startFrame) / rate
        lastTime = segmentStart
        pausedAt = nil
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                onEnd()
            }
        }
        if let when { player.play(at: when) } else { player.play() }
    }

    /// Sets the high-pass cutoff; below ~25 Hz the filter is bypassed.
    func setHighPass(_ frequency: Float) {
        filter.bands[0].bypass = frequency < 25
        filter.bands[0].frequency = min(20000, max(20, frequency))
    }

    /// Sets the low-pass cutoff; from ~19 kHz up the filter is bypassed.
    func setLowPass(_ frequency: Float) {
        filter.bands[1].bypass = frequency >= 19000
        filter.bands[1].frequency = min(20000, max(40, frequency))
    }

    /// Bass level from 0 (killed, like a DJ mixer's low EQ) to 1 (full).
    func setBass(_ level: Double) {
        filter.bands[2].bypass = level >= 0.999
        filter.bands[2].gain = Float(-30 * (1 - min(max(level, 0), 1)))
    }

    /// Echo amount 0…1 with repeats on a dotted eighth of the beat.
    func setEcho(_ amount: Double, beat: Double = 0.5) {
        delay.bypass = amount <= 0.005
        delay.delayTime = TimeInterval(min(2, max(0.05, beat * 0.75)))
        delay.wetDryMix = Float(50 * min(max(amount, 0), 1))
    }

    func resetEffects() {
        fader.outputVolume = 1
        player.volume = 1
        setHighPass(0)
        setLowPass(20000)
        setBass(1)
        setEcho(0)
    }

    // An idle deck has no connected input; pausing or playing it would
    // raise an exception, so every transport call checks for a file.
    func pause() {
        guard file != nil, pausedAt == nil else { return }
        pausedAt = currentTime
        player.pause()
    }

    func resume() {
        guard file != nil, pausedAt != nil, engineRunning else { return }
        pausedAt = nil
        player.play()
    }

    func stop() {
        generation += 1
        player.stop()
        pausedAt = nil
        segmentStart = 0
        lastTime = 0
        timePitch.rate = 1
        trim.globalGain = 0
        resetEffects()
    }

    func unload() {
        stop()
        file = nil
        url = nil
    }
}

/// Playback time lives in its own object so only the views that show it
/// (scrubber, times, lyrics) redraw as it advances.
@MainActor
final class PlaybackClock: ObservableObject {
    /// Not published: bars and lyrics read the time themselves through
    /// `elapsed(at:)`, so nothing is redrawn 20 times a second just because
    /// time passed.
    fileprivate(set) var elapsed: Double = 0
    @Published fileprivate(set) var duration: Double = 0
    @Published fileprivate(set) var running = false
    /// Progress 0…1 through the transition while two songs are mixing.
    @Published fileprivate(set) var mixProgress: Double?
    /// Goes up when the position jumps (a seek, a new song), so views that
    /// are paused know to look again.
    @Published fileprivate(set) var jumps = 0
    fileprivate(set) var updatedAt = Date()

    var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }

    /// Smooth position between 50 ms updates, for 120 Hz drawing.
    func elapsed(at date: Date) -> Double {
        guard running else { return elapsed }
        return min(duration, elapsed + date.timeIntervalSince(updatedAt))
    }

    fileprivate func set(elapsed: Double, duration: Double, running: Bool, jumped: Bool = false) {
        self.elapsed = elapsed
        updatedAt = Date()
        if self.duration != duration { self.duration = duration }
        if self.running != running { self.running = running }
        if jumped { jumps += 1 }
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

/// Plays local audio with AVAudioEngine (MP3, AAC, ALAC, FLAC, WAV, AIFF):
/// two decks for Spotify-style mixing, 10-band EQ, loudness matching and
/// beat-matched blends. Formats AVFoundation cannot read (Ogg, Opus, APE,
/// WMA) fall back to VLCKit without mixing or EQ.
@MainActor
final class MusicPlayer: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    let clock = PlaybackClock()
    var elapsed: Double { clock.elapsed }
    var duration: Double { clock.duration }
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var artwork: UIImage?
    /// A deep colour taken from the artwork, for backgrounds.
    @Published private(set) var artworkColor: Color?
    /// +1 when moving forward through the queue, -1 when going back, so
    /// covers and titles slide the right way.
    @Published private(set) var skipDirection = 1
    @Published private(set) var currentMeta: TrackMeta?
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isMixing = false
    @Published private(set) var nextPlan: TransitionPlan?
    @Published var notice: String?

    /// Supplies saved catalog details (title, artist, cover) for a track.
    var metaProvider: ((Track) -> TrackMeta?)?
    /// Snoozed or hidden songs, left out of queues (tapping one still plays it).
    var skipProvider: ((Track) -> Bool)?
    /// Supplies songs to continue with when the queue runs out.
    var similarProvider: ((Track, [Track]) -> [Track])?
    /// Told once a song has been half heard, for play counts.
    var playedProvider: ((Track) -> Void)?

    /// Stops the music after a while, or when the current song ends.
    enum SleepTimer: Equatable {
        case off
        case until(Date)
        case endOfSong
    }

    @Published private(set) var sleepTimer: SleepTimer = .off

    let mix = MixSettings()
    let equalizer = EqualizerSettings()
    let headphones = HeadphoneMonitor()

    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let decks = [AudioDeck(), AudioDeck()]
    private var active = 0
    private var vlc: VLCMediaPlayer?
    private var vlcStarted = false
    private var userPaused = false
    /// True while a call or another app has taken the sound from us.
    private var interrupted = false
    private var countedPlay = false
    private var lockScreenArtwork: (image: UIImage, item: MPMediaItemArtwork)?
    /// How far ahead of a blend the next song is lined up on the audio clock.
    private static let mixLead = 0.3
    private var originalOrder: [Track]?
    private var tickTask: Task<Void, Never>?
    private var mixStartedAt: Date?
    private var mixPlan: TransitionPlan?
    private var rateRestore: (from: Float, startedAt: Date)?
    private var planTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// The song Auto EQ last measured, and the jobs that measure and fade.
    private var autoTrack: Track?
    private var autoTask: Task<Void, Never>?
    private var rampTask: Task<Void, Never>?

    private var deck: AudioDeck { decks[active] }
    private var otherDeck: AudioDeck { decks[1 - active] }

    var progress: Double { clock.progress }
    var hasNext: Bool { index + 1 < queue.count || repeatMode == .all }
    var upcoming: Track? { index + 1 < queue.count ? queue[index + 1] : nil }
    var isLossless: Bool {
        ["flac", "alac", "wav", "aif", "aiff", "ape", "wv"].contains(current?.url.pathExtension.lowercased() ?? "")
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        engine.attach(bus)
        engine.attach(eq)
        decks.forEach { $0.attach(to: engine, output: bus) }
        engine.connect(bus, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        for (band, frequency) in zip(eq.bands, EqualizerSettings.frequencies) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.bypass = false
        }
        applyEqualizer()
        equalizer.objectWillChange
            .sink { [weak self] in Task { @MainActor in self?.applyEqualizer() } }
            .store(in: &cancellables)
        mix.objectWillChange
            .sink { [weak self] in Task { @MainActor in self?.preparePlan() } }
            .store(in: &cancellables)
        // Earbuds connecting pick their own correction curve.
        headphones.$routeName
            .removeDuplicates()
            .sink { [weak self] name in
                Task { @MainActor in
                    guard let self, self.equalizer.autoDetectHeadphones,
                          let profile = HeadphoneProfile.detect(name),
                          self.equalizer.headphone != profile else { return }
                    self.equalizer.headphone = profile
                    self.notice = "Tuned for \(profile.name)"
                }
            }
            .store(in: &cancellables)
        configureRemoteCommands()
        observeSession()
    }

    // MARK: Queue

    func play(_ tracks: [Track], startAt start: Int) {
        guard tracks.indices.contains(start) else { return }
        skipDirection = 1
        // Keep the song you tapped; leave out the snoozed and hidden ones.
        // Its place is counted, not looked up by name: a playlist can hold
        // the same song twice.
        var kept: [Track] = []
        var chosen = 0
        for (offset, track) in tracks.enumerated() {
            if offset == start {
                chosen = kept.count
            } else if skipProvider?(track) ?? false {
                continue
            }
            kept.append(track)
        }
        queue = kept
        index = chosen
        // Remember the list's own order so turning Shuffle off puts it back.
        originalOrder = shuffle ? kept : nil
        if shuffle { shuffleUpcoming() }
        startCurrent(from: 0)
    }

    /// Turns Shuffle on and starts from a random song.
    func playShuffled(_ tracks: [Track]) {
        let playable = tracks.filter { !(skipProvider?($0) ?? false) }
        let list = playable.isEmpty ? tracks : playable
        guard !list.isEmpty else { return }
        shuffle = true
        play(list, startAt: Int.random(in: list.indices))
    }

    func playNext(_ track: Track) {
        guard current != nil else { return play([track], startAt: 0) }
        cancelMix()
        queue.insert(track, at: min(index + 1, queue.count))
        preparePlan()
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { return play([track], startAt: 0) }
        queue.append(track)
        preparePlan()
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        cancelMix()
        // Follow the playing song by its place, not its name: the same
        // song can be in the queue twice.
        var order = Array(queue.indices)
        order.move(fromOffsets: source, toOffset: destination)
        let moved = order.map { queue[$0] }
        queue = moved
        index = order.firstIndex(of: index) ?? index
        preparePlan()
    }

    func removeFromQueue(at offsets: IndexSet) {
        cancelMix()
        let removingCurrent = offsets.contains(index)
        let removedBefore = offsets.filter { $0 < index }.count
        queue.remove(atOffsets: offsets)
        guard !queue.isEmpty else { return stop() }
        index = max(0, min(index - removedBefore, queue.count - 1))
        if removingCurrent {
            startCurrent(from: 0)
        } else {
            preparePlan()
        }
    }

    func toggleShuffle() {
        cancelMix()
        shuffle.toggle()
        if shuffle {
            originalOrder = queue
            shuffleUpcoming()
        } else if let original = originalOrder, let playing = current {
            queue = original
            index = original.firstIndex(of: playing) ?? 0
            originalOrder = nil
        }
        preparePlan()
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
        preparePlan()
    }

    private func shuffleUpcoming() {
        guard index + 1 < queue.count else { return }
        let rest = queue[(index + 1)...].shuffled()
        queue.replaceSubrange((index + 1)..., with: rest)
    }

    // MARK: Transport

    func togglePlayback() {
        guard current != nil else { return }
        if isPlaying {
            pause()
        } else {
            userPaused = false
            interrupted = false
            if let vlc {
                vlc.play()
            } else if deck.file != nil {
                try? AVAudioSession.sharedInstance().setActive(true)
                if engine.isRunning, deck.isPaused {
                    // Nothing was lost while paused: carry on.
                    decks.forEach { $0.resume() }
                } else if deck.isPaused || deck.currentTime > 0 {
                    // iOS stopped the engine meanwhile; bring it back.
                    recoverEngine(resume: true)
                } else {
                    startCurrent(from: 0)
                }
            } else {
                startCurrent(from: 0)
            }
        }
        refresh()
    }

    private func pause() {
        userPaused = true
        if mixPlan != nil {
            // A blend runs on the clock and can't be frozen half-way; it
            // is planned again and re-joined in time when you press Play.
            cancelMix()
            preparePlan()
        }
        // Keep the engine running: scheduling on a paused engine throws.
        if let vlc { vlc.pause() } else { decks.forEach { $0.pause() } }
    }

    /// Brings sound back after iOS stopped the audio engine (earbuds
    /// changed, a call, a long time in the background): restart it and put
    /// the song back where it was, playing or paused.
    private func recoverEngine(resume: Bool) {
        guard vlc == nil, current != nil, deck.file != nil else { return }
        let position = deck.currentTime
        cancelMix()
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        guard engine.isRunning else { return }
        deck.play(from: position) { [weak self] in self?.trackEnded() }
        if !resume { deck.pause() }
        clock.set(elapsed: position, duration: deck.duration, running: resume, jumped: true)
        refresh()
        if nextPlan == nil { preparePlan() }
    }

    /// Call when the app comes back on screen: if the sound was taken away
    /// while it was suspended, show the song as paused, ready to continue.
    func sceneActive() {
        guard current != nil, vlc == nil else { return }
        if interrupted || (!userPaused && !engine.isRunning) {
            interrupted = false
            userPaused = true
            decks.forEach { $0.pause() }
            refresh()
        }
    }

    // MARK: Sleep timer

    /// Minutes until the music stops, or nil to turn the timer off.
    func setSleepTimer(minutes: Int?) {
        engine.mainMixerNode.outputVolume = 1
        sleepTimer = minutes.map { .until(Date().addingTimeInterval(Double($0) * 60)) } ?? .off
    }

    func sleepAtEndOfSong() {
        engine.mainMixerNode.outputVolume = 1
        sleepTimer = .endOfSong
    }

    private func finishSleep() {
        sleepTimer = .off
        if isPlaying { pause() }
        engine.mainMixerNode.outputVolume = 1
        notice = "Sleep timer ended"
        refresh()
    }

    /// Snoozes the playing song for 30 days (or hides it) and moves on.
    func skipForGood() {
        guard current != nil else { return }
        queue.remove(at: index)
        if index >= queue.count {
            index = max(0, queue.count - 1)
            if queue.isEmpty { stop(); return }
        }
        startCurrent(from: 0)
    }

    func next() {
        cancelMix()
        skipDirection = 1
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
        } else if !appendSimilar() {
            return
        } else {
            index += 1
        }
        startCurrent(from: 0)
    }

    func previous() {
        cancelMix()
        if elapsed > 3 || index == 0 {
            seek(to: 0)
        } else {
            skipDirection = -1
            index -= 1
            startCurrent(from: 0)
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        cancelMix()
        let target = min(max(fraction, 0), 0.999) * duration
        if let vlc {
            vlc.position = target / duration
        } else {
            if !engine.isRunning { try? engine.start() }
            guard engine.isRunning else { return }
            deck.play(from: target) { [weak self] in self?.trackEnded() }
            if userPaused { deck.pause() }
        }
        clock.set(elapsed: target, duration: duration, running: isPlaying, jumped: true)
        updateNowPlaying()
        // A started (or cancelled) mix used up the plan; plan it again.
        if nextPlan == nil { preparePlan() }
    }

    /// Plays a transition from two bars before it starts, so it can be heard.
    func previewTransition(from: Track, to: Track, at seconds: Double) {
        let start = max(0, seconds)
        if current == from, upcoming == to, vlc == nil, deck.file != nil, deck.duration > 0 {
            userPaused = false
            if !engine.isRunning { try? engine.start() }
            seek(to: start / deck.duration)
            if !deck.isActive { decks.forEach { $0.resume() } }
            refresh()
            return
        }
        if let position = queue.firstIndex(of: from), queue[safe: position + 1] == to {
            index = position
        } else {
            originalOrder = nil
            queue = [from, to]
            index = 0
        }
        startCurrent(from: start)
    }

    enum QueueOrder: String, CaseIterable, Identifiable {
        case tempo = "Tempo (BPM)"
        case key = "Key"
        case harmonic = "Smart mix order"
        var id: String { rawValue }
    }

    /// Reorders the songs after the current one, like a DJ planning a set.
    func sortUpcoming(_ order: QueueOrder) async {
        guard index + 1 < queue.count else { return }
        let before = queue
        let start = queue[index]
        let rest = Array(queue[(index + 1)...])
        var facts: [Track: TrackAnalysis] = [:]
        for track in [start] + rest {
            if let analysis = await TrackAnalyzer.shared.analysis(for: track.url) { facts[track] = analysis }
        }
        guard queue == before else { return }
        cancelMix()
        let sorted: [Track]
        switch order {
        case .tempo:
            sorted = rest.sorted { (facts[$0]?.bpm ?? .infinity) < (facts[$1]?.bpm ?? .infinity) }
        case .key:
            sorted = rest.sorted { a, b in
                let x = facts[a]?.key, y = facts[b]?.key
                return (x?.camelotNumber ?? 99, x?.minor == false ? 1 : 0)
                    < (y?.camelotNumber ?? 99, y?.minor == false ? 1 : 0)
            }
        case .harmonic:
            // Greedy chain: each next song has a compatible key and the
            // closest tempo to the one before it.
            var remaining = rest
            var chain: [Track] = []
            var last = facts[start]
            while !remaining.isEmpty {
                let pick = remaining.indices.min { lhs, rhs in
                    Self.mixCost(last, facts[remaining[lhs]]) < Self.mixCost(last, facts[remaining[rhs]])
                }!
                let track = remaining.remove(at: pick)
                chain.append(track)
                last = facts[track] ?? last
            }
            sorted = chain
        }
        originalOrder = nil
        shuffle = false
        queue.replaceSubrange((index + 1)..., with: sorted)
        preparePlan()
    }

    private static func mixCost(_ a: TrackAnalysis?, _ b: TrackAnalysis?) -> Double {
        guard let b else { return 1000 }
        var cost = 0.0
        if let x = a?.key, let y = b.key, !x.isCompatible(with: y) { cost += 12 }
        if let x = a?.bpm, let y = b.bpm {
            let ratio = max(x, y) / min(x, y)
            cost += min(abs(ratio - 1), abs(ratio - 2)) * 100
        }
        return cost
    }

    private func stop() {
        cancelMix()
        tickTask?.cancel()
        decks.forEach { $0.unload() }
        vlc?.stop()
        vlc = nil
        current = nil
        currentMeta = nil
        artwork = nil
        artworkColor = nil
        isPlaying = false
        clock.set(elapsed: 0, duration: 0, running: false, jumped: true)
        nextPlan = nil
        updateNowPlaying()
    }

    // MARK: Starting tracks

    private func startCurrent(from seconds: Double, attempts: Int = 0) {
        guard queue.indices.contains(index) else { return stop() }
        let track = queue[index]
        cancelMix()
        vlc?.stop()
        vlc = nil
        decks.forEach { $0.unload() }
        userPaused = false
        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            try deck.load(track.url, engine: engine)
            if !engine.isRunning { try engine.start() }
            Task { [weak self] in
                guard let analysis = await TrackAnalyzer.shared.analysis(for: track.url),
                      let self, self.current == track, self.mixPlan == nil else { return }
                if self.mix.matchVolume { self.deck.trim.globalGain = self.mix.loudnessTrims(analysis, nil).0 }
            }
            deck.play(from: seconds) { [weak self] in self?.trackEnded() }
        } catch {
            // AVFoundation cannot read this format; let VLC try.
            guard startVLC(track.url) else {
                return skipBroken(track, attempts: attempts)
            }
        }

        setCurrent(track)
        startTicking()
        preparePlan()
    }

    private func setCurrent(_ track: Track, playing: Bool = true) {
        current = track
        currentMeta = metaProvider?(track)
        countedPlay = false
        if equalizer.enabled { updateAutoEQ(track) }
        clock.set(elapsed: vlc == nil ? deck.currentTime : 0, duration: vlc == nil ? deck.duration : 0,
                  running: playing, jumped: true)
        isPlaying = playing
        // A cover already in memory shows at once, with no empty flash.
        artwork = ArtworkResolver.cached(track, size: .large)
        loadArtwork(for: track)
        updateNowPlaying()
    }

    private func startVLC(_ url: URL) -> Bool {
        guard let media = VLCMedia(url: url) else { return false }
        let player = VLCMediaPlayer()
        player.media = media
        player.play()
        vlc = player
        vlcStarted = false
        return true
    }

    private func skipBroken(_ track: Track, attempts: Int) {
        notice = "Skipped \u{201C}\(metaProvider?(track)?.title ?? track.title)\u{201D}: the file can't be played."
        guard attempts < queue.count, index + 1 < queue.count else { return stop() }
        index += 1
        startCurrent(from: 0, attempts: attempts + 1)
    }

    private func trackEnded() {
        guard mixPlan == nil else { return }
        skipDirection = 1
        if sleepTimer == .endOfSong {
            // Stop here, with the next song lined up for when you press Play.
            sleepTimer = .off
            vlc?.stop()
            vlc = nil
            decks.forEach { $0.unload() }
            userPaused = true
            if index + 1 < queue.count {
                index += 1
                setCurrent(queue[index], playing: false)
                preparePlan()
            } else {
                isPlaying = false
                clock.set(elapsed: 0, duration: duration, running: false, jumped: true)
                updateNowPlaying()
            }
            notice = "Sleep timer ended"
            return
        }
        if repeatMode == .one {
            startCurrent(from: 0)
        } else if index + 1 < queue.count {
            index += 1
            startCurrent(from: 0)
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            startCurrent(from: 0)
        } else if appendSimilar() {
            index += 1
            startCurrent(from: 0)
        } else {
            // Unload so Play starts the last song again from the top.
            decks.forEach { $0.unload() }
            isPlaying = false
            userPaused = true
            clock.set(elapsed: 0, duration: duration, running: false, jumped: true)
            updateNowPlaying()
        }
    }

    /// Autoplay: continue with similar downloaded songs when the queue ends.
    @discardableResult
    private func appendSimilar() -> Bool {
        guard let current, let more = similarProvider?(current, queue), !more.isEmpty else { return false }
        queue.append(contentsOf: more)
        return true
    }

    // MARK: Mixing

    /// Plans the transition into the upcoming song once both are analysed.
    private func preparePlan() {
        planTask?.cancel()
        nextPlan = nil
        guard vlc == nil, repeatMode != .one, let from = current, let to = upcoming,
              Self.engineReadable(to.url) else { return }
        let outDuration = deck.duration
        let mixing = mix.isOn
        planTask = Task { [weak self] in
            async let outAnalysis = TrackAnalyzer.shared.analysis(for: from.url)
            async let inAnalysis = TrackAnalyzer.shared.analysis(for: to.url)
            let (out, incoming) = await (outAnalysis, inAnalysis)
            guard let self, !Task.isCancelled, self.current == from, self.upcoming == to else { return }
            // With Mix off the songs still hand over without a gap.
            self.nextPlan = mixing
                ? self.mix.plan(from: from, out, to: to, incoming, outDuration: outDuration)
                : TransitionPlan.gapless(at: outDuration, inGain: self.mix.loudnessTrims(nil, incoming).1)
        }
    }

    private static func engineReadable(_ url: URL) -> Bool {
        !["ogg", "oga", "opus", "ape", "wma", "wv"].contains(url.pathExtension.lowercased())
    }

    private func beginMix(_ plan: TransitionPlan) {
        guard let next = upcoming, engine.isRunning else { return }
        let incoming = otherDeck
        do { try incoming.load(next.url, engine: engine) } catch { return }
        incoming.trim.globalGain = plan.inGain
        incoming.timePitch.rate = plan.inRate
        mixPlan = plan
        if plan.isGapless {
            incoming.resetEffects()
        } else {
            deck.trim.globalGain = plan.outGain
            deck.setEcho(0, beat: plan.beat)
            isMixing = true
            applyAutomation(plan, at: 0)
        }
        // The next song starts on an exact time on the audio clock, not
        // "now": timers run tens of milliseconds late, enough to hear two
        // kick drums land apart. `ahead` is how long until the blend point
        // (negative if playback is already past it, after a seek).
        let rate = Double(max(0.5, deck.timePitch.rate))
        let ahead = (plan.mixStart - deck.currentTime) / rate
        let late = max(0, -ahead)
        mixStartedAt = Date().addingTimeInterval(ahead)
        let when = ahead > 0.02
            ? AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: ahead))
            : nil
        incoming.play(from: plan.entry + late * Double(plan.inRate), at: when) { [weak self] in self?.trackEnded() }
    }

    /// Sets volume, bass EQ and effects for both decks at progress t.
    private func applyAutomation(_ plan: TransitionPlan, at t: Double) {
        let outgoing = deck, incoming = otherDeck
        let gains = plan.volume.gains(t)
        let amount = plan.effect.amount(t)
        if plan.effect == .echo {
            // Cut the dry signal but keep the echoes ringing, then fade them.
            outgoing.player.volume = gains.out
            outgoing.fader.outputVolume = Float(1 - smoothstep(0.75, 1, t))
            outgoing.setEcho(amount, beat: plan.beat)
        } else {
            outgoing.fader.outputVolume = gains.out
        }
        incoming.fader.outputVolume = gains.in
        let bass = plan.eq.bass(t, beatFraction: plan.length > 0 ? plan.beat / plan.length : 0.1)
        outgoing.setBass(bass.out)
        incoming.setBass(bass.in)
        switch plan.effect {
        case .lowPass:
            // Opens from 250 Hz to the full range: the incoming song rises in.
            incoming.setLowPass(Float(250 * pow(80, 1 - amount)))
        case .highPass:
            outgoing.setHighPass(Float(20 * pow(100, amount)))
        case .echo, .none:
            break
        }
    }

    private func advanceMix(now: Date) {
        guard let plan = mixPlan, let started = mixStartedAt else { return }
        let since = now.timeIntervalSince(started)
        let t = plan.length > 0 ? since / plan.length : (since >= 0 ? 1 : 0)
        if !plan.isGapless {
            applyAutomation(plan, at: t)
            let shown = (min(max(t, 0), 1) * 50).rounded() / 50
            if clock.mixProgress != shown { clock.mixProgress = shown }
        }
        guard t >= 1 else { return }

        // Hand over to the incoming deck.
        deck.unload()
        active = 1 - active
        deck.resetEffects()
        clock.mixProgress = nil
        skipDirection = 1
        index += 1
        isMixing = false
        mixPlan = nil
        mixStartedAt = nil
        if plan.inRate != 1 { rateRestore = (plan.inRate, now) }
        if let track = queue[safe: index] { setCurrent(track) }
        preparePlan()
    }

    private func cancelMix() {
        guard mixPlan != nil else { return }
        otherDeck.unload()
        deck.resetEffects()
        clock.mixProgress = nil
        isMixing = false
        mixPlan = nil
        mixStartedAt = nil
    }

    // MARK: Clock

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // Automation runs finer while two songs are blending, and
                // there is little to do while paused.
                let interval = self?.mixPlan != nil ? 20 : (self?.isPlaying == true ? 50 : 250)
                do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
            }
        }
    }

    private func tick() {
        let now = Date()
        if mixPlan != nil { advanceMix(now: now) }
        if case .until(let end) = sleepTimer {
            // Fade out over the last ten seconds, then pause.
            let left = end.timeIntervalSince(now)
            if left <= 0 {
                finishSleep()
            } else if left < 10 {
                engine.mainMixerNode.outputVolume = Float(left / 10)
            }
        }
        if !countedPlay, isPlaying, let current, clock.duration > 0,
           clock.elapsed >= min(clock.duration * 0.5, 240) {
            countedPlay = true
            playedProvider?(current)
        }
        if let restore = rateRestore {
            // Ease a beat-matched song back to its natural speed over 8 s.
            let t = min(1, now.timeIntervalSince(restore.startedAt) / 8)
            deck.timePitch.rate = restore.from + (1 - restore.from) * Float(t)
            if t >= 1 { rateRestore = nil }
        }
        if mixPlan == nil, !userPaused, sleepTimer != .endOfSong, let plan = nextPlan, vlc == nil,
           deck.isActive, deck.currentTime >= plan.mixStart - Self.mixLead {
            nextPlan = nil
            beginMix(plan)
        }
        refresh()
    }

    private func refresh() {
        // Assign only on change: every @Published write redraws its observers.
        if let vlc {
            let playing = vlc.isPlaying
            let changed = isPlaying != playing
            if changed { isPlaying = playing }
            clock.set(elapsed: Double(max(0, vlc.time.intValue)) / 1000,
                      duration: Double(max(0, vlc.media?.length.intValue ?? 0)) / 1000,
                      running: playing)
            // The Lock Screen keeps its own clock; tell it about pause and play.
            if changed { updateNowPlaying() }
            if isPlaying { vlcStarted = true }
            if vlc.state == .error, let track = current {
                self.vlc = nil
                vlc.stop()
                return skipBroken(track, attempts: 0)
            }
            if vlcStarted, !userPaused, vlc.state == .stopped {
                vlcStarted = false
                trackEnded()
            }
        } else {
            let playing = !userPaused && deck.file != nil && deck.isActive
            let changed = isPlaying != playing
            if changed { isPlaying = playing }
            clock.set(elapsed: deck.currentTime, duration: deck.duration, running: playing)
            if changed { updateNowPlaying() }
        }
    }

    // MARK: Equalizer

    /// Applies the curve plus headphone correction, with a pre-gain cut so
    /// boosts never clip. Changes fade over about 300 ms, so a new song's
    /// Auto EQ curve slides in instead of clicking.
    private func applyEqualizer() {
        if equalizer.enabled, let current, autoTrack != current {
            updateAutoEQ(current)
        }
        eq.bypass = !equalizer.enabled
        let targets = equalizer.finalGains
        let preamp = equalizer.preamp
        let starts = eq.bands.map(\.gain)
        let startPreamp = eq.globalGain
        rampTask?.cancel()
        rampTask = Task { [weak self] in
            let steps = 10
            for step in 1...steps {
                guard let self, !Task.isCancelled else { return }
                let t = Float(step) / Float(steps)
                for (index, band) in self.eq.bands.enumerated() where index < targets.count {
                    band.gain = starts[index] + (targets[index] - starts[index]) * t
                }
                self.eq.globalGain = startPreamp + (preamp - startPreamp) * t
                if step < steps { try? await Task.sleep(for: .milliseconds(30)) }
            }
        }
    }

    /// Reads the song's genre and measured spectrum, then builds its Auto
    /// curve and looks up any curve remembered for the song, album or genre.
    private func updateAutoEQ(_ track: Track) {
        autoTrack = track
        autoTask?.cancel()
        let url = track.url
        let artist = currentMeta?.artist
        let album = currentMeta?.album
        let title = currentMeta?.title ?? track.title
        // The song and album are known now; the genre follows.
        equalizer.context = .init(song: url.lastPathComponent, album: album, genre: .unknown)
        autoTask = Task { [weak self] in
            async let analysis = TrackAnalyzer.shared.analysis(for: url)
            async let genre = GenreResolver.shared.genre(for: url, artist: artist, title: title)
            let (facts, kind) = await (analysis, genre)
            guard let self, !Task.isCancelled, self.current == track else { return }
            self.equalizer.context = .init(song: url.lastPathComponent, album: album, genre: kind)
            self.equalizer.autoResult = AutoEqualizer.result(bands: facts?.bands, genre: kind)
        }
    }

    // MARK: Now Playing

    /// Picks up details read after the song started (tags, catalog).
    func refreshMeta() {
        guard let current else { return }
        let meta = metaProvider?(current)
        if meta != currentMeta {
            currentMeta = meta
            updateNowPlaying()
        }
    }

    var title: String { currentMeta?.title ?? current?.title ?? "Not Playing" }

    var subtitle: String {
        if let meta = currentMeta, meta.artist != nil || meta.album != nil {
            return [meta.artist, meta.album].compactMap { $0 }.joined(separator: " — ")
        }
        return current?.folder ?? ""
    }

    private func loadArtwork(for track: Track) {
        let meta = currentMeta
        Task { [weak self] in
            let image = await ArtworkResolver.shared.image(for: track, meta: meta, size: .large)
            let color = await Task.detached(priority: .userInitiated) { image.flatMap(ArtworkPalette.color) }.value
            guard let self, self.current == track else { return }
            self.artwork = image
            self.artworkColor = color
            self.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard current != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.elapsed(at: Date()),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count
        ]
        if let artist = currentMeta?.artist { info[MPMediaItemPropertyArtist] = artist }
        info[MPMediaItemPropertyAlbumTitle] = currentMeta?.album ?? current?.folder
        if let artwork {
            // Built once per cover, not on every update.
            if lockScreenArtwork?.image !== artwork {
                lockScreenArtwork = (artwork, Self.lockScreenItem(artwork))
            }
            info[MPMediaItemPropertyArtwork] = lockScreenArtwork?.item
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// iOS asks for the picture on its own thread, so this is made outside
    /// the main actor.
    nonisolated private static func lockScreenItem(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
                Task { @MainActor in
                    guard let self else { return }
                    if type == .began, self.isPlaying {
                        self.pause()
                        self.interrupted = true
                        self.refresh()
                    }
                    // Only continue what the interruption itself stopped,
                    // never something you had paused yourself.
                    if type == .ended, self.interrupted {
                        self.interrupted = false
                        if options.contains(.shouldResume) { self.togglePlayback() }
                    }
                }
            }
            .store(in: &cancellables)
        // Earbuds taken out or switched off: pause instead of carrying on
        // out loud through the speaker.
        center.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
                guard reason == .oldDeviceUnavailable else { return }
                Task { @MainActor in
                    guard let self, self.isPlaying else { return }
                    self.pause()
                    self.refresh()
                }
            }
            .store(in: &cancellables)
        // The output changed and iOS stopped the engine. Restart it and put
        // the song back in place. (This used to call play on the idle second
        // deck, which crashes.) The short wait lets the pause above go first.
        center.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .sink { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, self.current != nil, self.vlc == nil else { return }
                    self.recoverEngine(resume: !self.userPaused && !self.interrupted)
                }
            }
            .store(in: &cancellables)
        center.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                    self.userPaused = true
                    self.recoverEngine(resume: false)
                }
            }
            .store(in: &cancellables)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayback() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayback() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.seek(to: event.positionTime / self.duration)
            }
            return .success
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
