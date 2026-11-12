import AVKit
import MediaPlayer
import SwiftUI

/// Full-screen player: artwork-tinted background, a large cover that
/// slides in the direction you skip and settles back when paused, title
/// with tempo and key, transport, volume and quick access to lyrics, the
/// transition editor, EQ and Up Next. Fast-changing parts (time, lyrics,
/// mix progress, cover drag) are separate views so only they redraw.
struct NowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.soulseek) private var soulseek
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Closes without the system animation, after a swipe already moved the page away.
    var onSwipeClose: (() -> Void)?
    @State private var sheet: Sheet?
    @State private var lyricsFrame: CGRect?
    @StateObject private var swipe = SwipeDownState()
    @State private var namingPlaylist = false
    @State private var showLyrics = false
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false

    enum Sheet: String, Identifiable {
        case queue, mix, equalizer, album
        var id: String { rawValue }
    }

    private var isFavourite: Bool { player.current.map(library.isFavourite) ?? false }

    private var slide: AnyTransition {
        if reduceMotion { return .opacity }
        let distance: CGFloat = player.skipDirection >= 0 ? 360 : -360
        return .asymmetric(
            insertion: .offset(x: distance).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
            removal: .offset(x: -distance).combined(with: .opacity).combined(with: .scale(scale: 0.92))
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 48, proxy.size.height * 0.42)
            VStack(spacing: 0) {
              // Swipe down here (top bar, artwork, title) to close. The bars
              // and buttons below have no competing gesture.
              VStack(spacing: 0) {
                topBar
                Spacer(minLength: 20)
                ZStack {
                    if showLyrics {
                        LyricsPanel(lyrics: lyrics, loading: lyricsLoading, clock: player.clock) { time in
                            if player.duration > 0 { player.seek(to: time / player.duration) }
                        }
                        .frame(width: proxy.size.width - 48, height: side)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lyricsFrame = $0 }
                        .onDisappear { lyricsFrame = nil }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        CoverView(side: side, coverMenu: { coverMenu }, onLike: like)
                            .id(player.current)
                            .transition(slide)
                    }
                }
                .frame(height: side)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86),
                           value: player.current)
                Spacer(minLength: 20)
                titleRow
              }
              .contentShape(Rectangle())
              .modifier(SwipeDownArea(swipe: swipe, blocked: showLyrics ? lyricsFrame : nil) {
                  if let onSwipeClose { onSwipeClose() } else { dismiss() }
              })
                TimeBar(clock: player.clock) { player.seek(to: $0) }
                    .padding(.top, 12)
                transport
                    .padding(.top, 10)
                VolumeBar()
                    .padding(.top, 14)
                HeadphoneChip(monitor: player.headphones, equalizer: player.equalizer)
                    .padding(.top, 6)
                bottomBar
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
            .frame(width: proxy.size.width)
        }
        .background { backdrop }
        .foregroundStyle(.white)
        .modifier(SwipeDownPage(swipe: swipe))
        .modifier(NewPlaylistAlert(isPresented: $namingPlaylist, track: player.current))
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .overlay(alignment: .top) { noticeBanner }
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        .sensoryFeedback(.selection, trigger: player.current)
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .queue: QueueView()
                case .mix:
                    if let from = player.current, let to = player.upcoming {
                        TransitionEditorView(pair: TransitionPair(from: from, to: to))
                    } else {
                        NavigationStack {
                            Form { MixSettingsForm(mix: player.mix) }
                                .navigationTitle("Mix")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                        .presentationDetents([.medium, .large])
                    }
                case .equalizer: EqualizerView()
                case .album: AlbumLookupView(meta: player.currentMeta, fallbackTitle: player.title)
                }
            }
            .environmentObject(player)
            .environmentObject(library)
            .soulseekObjects(soulseek)
        }
        .task(id: player.current) { await loadLyrics() }
    }

    // MARK: Sections

    private var backdrop: some View {
        let tint = player.artworkColor ?? Color(white: 0.22)
        return ZStack {
            Color.black
            LinearGradient(stops: [
                .init(color: tint, location: 0),
                .init(color: tint.opacity(0.55), location: 0.45),
                .init(color: .black, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: player.artworkColor)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { TopBarIcon(symbol: "chevron.down") }
                .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Close Now Playing")
            Spacer()
            MixStatusPill(clock: player.clock) { sheet = .mix }
            Spacer()
            Menu {
                coverMenu
            } label: {
                TopBarIcon(symbol: "ellipsis")
            }
            // iOS 26 gives a Menu its own glass disc and drops the label's
            // colour, leaving an empty bubble. The disc and icon are drawn here.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
        }
    }

    @ViewBuilder
    private var coverMenu: some View {
        Button { sheet = .album } label: { Label("Go to Album", systemImage: "square.stack") }
        if let track = player.current {
            Button { player.playNext(track) } label: { Label("Play Again Next", systemImage: "text.insert") }
            Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.append") }
            AddToPlaylistMenu(track: track) { namingPlaylist = true }
        }
        Button { sheet = .queue } label: { Label("Up Next", systemImage: "list.bullet") }
        Menu {
            ForEach([10, 20, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) Minutes") { player.setSleepTimer(minutes: minutes) }
            }
            Button("End of This Song") { player.sleepAtEndOfSong() }
            if player.sleepTimer != .off {
                Button("Turn Off", role: .destructive) { player.setSleepTimer(minutes: nil) }
            }
        } label: {
            Label(sleepLabel, systemImage: player.sleepTimer == .off ? "moon" : "moon.fill")
        }
        if player.upcoming != nil {
            Button { sheet = .mix } label: { Label("Edit Transition", systemImage: "slider.horizontal.3") }
        }
        Button { toggleFavourite() } label: {
            Label(isFavourite ? "Unstar" : "Star", systemImage: isFavourite ? "star.slash" : "star")
        }
        if let track = player.current {
            Divider()
            // Spotify's 30-day Snooze: a break from a song, not goodbye.
            Button {
                library.snooze(track)
                player.notice = "Snoozed for 30 days"
                player.skipForGood()
            } label: { Label("Snooze for 30 Days", systemImage: "moon.zzz") }
            Button(role: .destructive) {
                library.setHidden(track, true)
                player.notice = "Hidden. Find it in Library to bring it back."
                player.skipForGood()
            } label: { Label("Hide Song", systemImage: "eye.slash") }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.title)
                        .font(.title2.weight(.bold))
                        .tracking(-0.4)
                        .lineLimit(1)
                    if isFavourite { StarMark(size: 14) }
                }
                Text(player.subtitle)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                if let track = player.current {
                    NowPlayingFacts(track: track, lossless: player.isLossless)
                        .padding(.top, 2)
                }
            }
            .id(player.current)
            .transition(.blurReplace)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { toggleFavourite() } label: {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .font(.title2)
                    .foregroundStyle(isFavourite ? Color.brand : .white.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: isFavourite)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(isFavourite ? "Unstar" : "Star")
        }
        .animation(.snappy(duration: 0.35), value: player.current)
    }

    private var transport: some View {
        HStack {
            toggleButton("shuffle", on: player.shuffle) { player.toggleShuffle() }
                .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 30)) }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Previous track")
            Spacer()
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(.white, in: Circle())
                    .shadow(color: (player.artworkColor ?? .black).opacity(0.6), radius: 16, y: 6)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 30)) }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Next track")
            Spacer()
            toggleButton(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) {
                player.cycleRepeat()
            }
            .accessibilityLabel("Repeat \(player.repeatMode.rawValue)")
        }
        .sensoryFeedback(.selection, trigger: player.shuffle)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
    }

    /// Shuffle and repeat: green with a dot underneath when on, like Spotify.
    private func toggleButton(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                Circle().frame(width: 4, height: 4).opacity(on ? 1 : 0)
            }
            .foregroundStyle(on ? Color.brand : .white.opacity(0.75))
            .frame(width: 44, height: 50)
            .animation(.snappy(duration: 0.2), value: on)
        }
        .buttonStyle(PressScaleStyle())
    }

    private var bottomBar: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showLyrics.toggle() }
            } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .foregroundStyle(showLyrics ? Color.brand : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(showLyrics ? "Hide lyrics" : "Show lyrics")
            Spacer()
            RoutePicker().frame(width: 44, height: 44)
            Spacer()
            Button { sheet = .equalizer } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(player.equalizer.enabled ? Color.brand : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Equalizer")
            Spacer()
            Button { sheet = .mix } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(player.mix.isOn ? Color.brand : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Edit transition")
            Spacer()
            Button { sheet = .queue } label: {
                Image(systemName: "list.bullet").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Up next")
        }
        .font(.title3)
        .buttonStyle(PressScaleStyle())
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = player.notice {
            Text(notice)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.15), in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { player.notice = nil }
                }
        }
    }

    private var sleepLabel: String {
        switch player.sleepTimer {
        case .off: return "Sleep Timer"
        case .endOfSong: return "Sleep Timer · End of Song"
        case .until(let end):
            return "Sleep Timer · \(max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))) min"
        }
    }

    // MARK: Actions

    private func like() {
        guard let track = player.current else { return }
        library.setFavourite(track, true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func toggleFavourite() {
        guard let track = player.current else { return }
        library.setFavourite(track, !library.isFavourite(track))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func loadLyrics() async {
        lyrics = []
        guard player.current != nil else { return }
        lyricsLoading = true
        defer { lyricsLoading = false }
        let meta = player.currentMeta
        let title = meta?.title ?? MusicText.clean(player.title)
        lyrics = await LyricsService.shared.lyrics(
            title: title, artist: meta?.artist, album: meta?.album,
            duration: player.duration > 0 ? player.duration : nil
        )
    }
}

/// Top-of-player status: what's mixing in (with live progress), the next
/// transition, or just "Now Playing". Tap to open the transition editor.
private struct MixStatusPill: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @ObservedObject var clock: PlaybackClock
    let onTap: () -> Void

    var body: some View {
        Group {
            if player.isMixing, let next = player.upcoming {
                pill(progress: clock.mixProgress) {
                    PlayingBars(active: true, color: .black)
                    Text("Mixing into \(library.title(of: next))").lineLimit(1)
                }
                .foregroundStyle(.black)
                .background(Color.brand, in: Capsule())
            } else if player.mix.isOn, let plan = player.nextPlan, !plan.isGapless {
                pill(progress: nil) {
                    Image(systemName: "sparkles")
                    Text("Next: \(plan.preset?.rawValue ?? "Custom") · \(plan.bars) bars")
                }
                .foregroundStyle(.white)
                .background(.white.opacity(0.14), in: Capsule())
            } else {
                Text("NOW PLAYING")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .animation(.snappy, value: player.isMixing)
        .onTapGesture { if player.upcoming != nil { onTap() } }
    }

    private func pill<Content: View>(progress: Double?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: 230)
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    GeometryReader { proxy in
                        Capsule().fill(.black.opacity(0.35))
                            .frame(width: proxy.size.width * progress, height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
                }
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// Tempo and key under the title, plus a lossless mark.
private struct NowPlayingFacts: View {
    let track: Track
    let lossless: Bool
    @State private var analysis: TrackAnalysis?

    var body: some View {
        HStack(spacing: 8) {
            if let bpm = analysis?.bpm {
                Text("\(Int(bpm.rounded())) BPM")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let key = analysis?.key { KeyBadge(key: key) }
            if lossless {
                Label("Lossless", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.3), value: analysis?.bpm)
        .task(id: track.id) { analysis = await TrackAnalyzer.shared.analysis(for: track.url) }
    }
}

/// The cover keeps a fixed size; it slides with your finger to change
/// tracks, double-tap likes, long-press opens the menu.
private struct CoverView<MenuContent: View>: View {
    @EnvironmentObject private var player: MusicPlayer
    let side: CGFloat
    @ViewBuilder let coverMenu: () -> MenuContent
    let onLike: () -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var heartBurst = false
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                if let artwork = player.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Color(white: 0.12).overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.3, weight: .light))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(player.isPlaying ? 0.55 : 0.3),
                    radius: player.isPlaying ? 26 : 12, y: player.isPlaying ? 14 : 6)
            .animation(.easeInOut(duration: 0.3), value: player.artwork != nil)

            Image(systemName: "star.fill")
                .font(.system(size: 90))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 12)
                .shadow(radius: 10)
                .scaleEffect(heartBurst ? 1 : 0.4)
                .opacity(heartBurst ? 0.95 : 0)
                .allowsHitTesting(false)
        }
        // Settles back slightly while paused, like Apple Music.
        .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.86)
        .animation(.spring(response: 0.45, dampingFraction: 0.68), value: player.isPlaying)
        .offset(x: dragOffset)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(dragOffset) / 40))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onLike()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { heartBurst = true }
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeOut(duration: 0.25)) { heartBurst = false }
            }
        }
        // Runs alongside the page's swipe-down: a sideways drag changes the
        // track, a downward one closes the player, decided after 10 pt.
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if dragAxis == nil {
                        dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                    }
                    guard dragAxis == .horizontal else { return }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    defer { dragAxis = nil }
                    guard dragAxis == .horizontal else { return }
                    // Project where the flick is heading, then decide.
                    let projected = value.translation.width + Fluid.project(value.velocity.width, deceleration: 0.99)
                    let velocity = value.velocity.width
                    withAnimation(.interpolatingSpring(duration: 0.35, bounce: 0.15,
                                                       initialVelocity: Fluid.relative(velocity, from: dragOffset, to: 0))) {
                        dragOffset = 0
                    }
                    if projected < -side * 0.35 { player.next() }
                    else if projected > side * 0.35 { player.previous() }
                }
        )
        .onDragCancelled(touching, stillBusy: { dragAxis != nil }) {
            dragAxis = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
        }
        .contextMenu { coverMenu() }
        .accessibilityElement()
        .accessibilityLabel("Album artwork")
        .accessibilityHint("Swipe left or right to change track. Double-tap to star.")
        .accessibilityAction(named: "Next track") { player.next() }
        .accessibilityAction(named: "Previous track") { player.previous() }
    }
}

/// Synced lyrics in place of the cover, following the song.
private struct LyricsPanel: View {
    let lyrics: [LyricLine]
    let loading: Bool
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void
    @State private var currentIndex: Int?

    private struct SyncKey: Equatable {
        let lyrics: [LyricLine]
        let running: Bool
        let jumps: Int
    }

    private func index(at time: Double) -> Int? {
        lyrics.lastIndex { ($0.time ?? .infinity) <= time + 0.25 }
    }

    var body: some View {
        content
            // Looks ten times a second for the line being sung, but only
            // redraws when it moves on (it used to redraw 20 times a second).
            .task(id: SyncKey(lyrics: lyrics, running: clock.running, jumps: clock.jumps)) {
                currentIndex = index(at: clock.elapsed(at: Date()))
                guard clock.running else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    let now = index(at: clock.elapsed(at: Date()))
                    if now != currentIndex { currentIndex = now }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if lyrics.isEmpty {
            VStack(spacing: 10) {
                if loading { ProgressView() } else {
                    Image(systemName: "quote.bubble").font(.largeTitle).foregroundStyle(.white.opacity(0.3))
                    Text("No lyrics found for this song").foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { reader in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(lyrics) { line in
                            Text(line.text)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white.opacity(line.id == currentIndex ? 1 : 0.3))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                                .onTapGesture { if let time = line.time { onSeek(time) } }
                        }
                    }
                    .padding(.vertical, 40)
                }
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88), .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom))
                .onChange(of: currentIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { reader.scrollTo(index, anchor: .center) }
                }
            }
        }
    }
}

/// Scrubber and times. Draws every frame (120 Hz on ProMotion) from the
/// playback clock without redrawing the rest of the page.
private struct TimeBar: View {
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.animation(paused: !clock.running || scrub != nil)) { context in
            let elapsed = clock.elapsed(at: context.date)
            let progress = scrub ?? (clock.duration > 0 ? elapsed / clock.duration : 0)
            let position = progress * clock.duration
            VStack(spacing: 6) {
                Scrubber(
                    progress: progress,
                    enabled: clock.duration > 0,
                    onChange: { scrub = $0 },
                    onCommit: {
                        if let scrub { onSeek(scrub) }
                        scrub = nil
                    },
                    onCancel: { scrub = nil }
                )
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("-" + Self.format(max(0, clock.duration - position)))
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Buttons shrink slightly while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A thin capsule progress bar that thickens while dragging.
struct Scrubber: View {
    let progress: Double
    let enabled: Bool
    let onChange: (Double) -> Void
    let onCommit: () -> Void
    /// Called when iOS cancels the drag instead of ending it.
    var onCancel: () -> Void = {}
    @State private var dragging = false
    @GestureState private var touching = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(dragging ? 1 : 0.85))
                    .frame(width: max(0, min(1, progress)) * proxy.size.width)
            }
            .frame(height: dragging ? 9 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        guard enabled else { return }
                        dragging = true
                        onChange(min(max(value.location.x / max(proxy.size.width, 1), 0), 1))
                    }
                    .onEnded { _ in
                        guard enabled else { return }
                        dragging = false
                        onCommit()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        // Tall enough to grab without aiming.
        .frame(height: 32)
        .onDragCancelled(touching, stillBusy: { dragging }) {
            dragging = false
            onCancel()
        }
        .sensoryFeedback(.selection, trigger: dragging)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            onChange(min(max(progress + (direction == .increment ? 0.05 : -0.05), 0), 1))
            onCommit()
        }
    }
}

// MARK: Fluid motion helpers (Apple's "Designing Fluid Interfaces")

enum Fluid {
    /// Where a flick will come to rest, from its release velocity (pt/s).
    /// 0.998 feels like a scroll view, 0.99 is snappier.
    static func project(_ velocity: CGFloat, deceleration: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * deceleration / (1 - deceleration)
    }

    /// Resistance past an edge: follows less the further you pull.
    static func rubberband(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let sign: CGFloat = overshoot < 0 ? -1 : 1
        let distance = abs(overshoot)
        return sign * (distance * dimension * constant) / (dimension + constant * distance)
    }

    /// Release velocity relative to the distance left, for spring hand-off.
    static func relative(_ velocity: CGFloat, from current: CGFloat, to target: CGFloat) -> Double {
        let distance = target - current
        guard abs(distance) > 1 else { return 0 }
        return Double(min(30, max(-30, velocity / distance)))
    }
}

extension View {
    /// Runs `reset` when a drag stops without its usual ending: iOS cancels
    /// drags for calls, alerts and other gestures, and a bar or page that
    /// only tidied up in `onEnded` was left stuck half-way.
    /// `active` is a `@GestureState` that is true while the finger is down.
    func onDragCancelled(_ active: Bool, stillBusy: @escaping () -> Bool, reset: @escaping () -> Void) -> some View {
        onChange(of: active) { _, isDown in
            guard !isDown else { return }
            // One turn later, so a normal ending has had its say first.
            Task { @MainActor in
                if stillBusy() { reset() }
            }
        }
    }
}

/// Shared between the page (which moves) and the area you grab.
@MainActor
final class SwipeDownState: ObservableObject {
    @Published var offset: CGFloat = 0
    var height: CGFloat = 800
}

/// Moves the whole player with the swipe and dims what's behind it.
struct SwipeDownPage: ViewModifier {
    @ObservedObject var swipe: SwipeDownState

    func body(content: Content) -> some View {
        let progress = max(0, min(1, swipe.offset / max(1, swipe.height)))
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { swipe.height = $0 }
            .offset(y: swipe.offset)
            .shadow(color: .black.opacity(swipe.offset > 1 ? 0.45 : 0), radius: 24, y: -4)
            .background {
                Color.black.opacity(swipe.offset > 1 ? 0.5 * (1 - progress) : 0).ignoresSafeArea()
            }
    }
}

/// Swipe down to close: follows the finger 1:1, rubber-bands when pulled
/// up, and on release continues at the finger's speed, away if the flick is
/// heading far enough down, back into place otherwise.
struct SwipeDownArea: ViewModifier {
    @ObservedObject var swipe: SwipeDownState
    /// A region that scrolls on its own (lyrics), where the swipe is ignored.
    let blocked: CGRect?
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var axis: Axis?
    @State private var ignored = false
    @State private var settling = false
    @GestureState private var touching = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if axis == nil {
                        ignored = blocked?.contains(value.startLocation) ?? false
                        axis = abs(value.translation.height) > abs(value.translation.width) ? .vertical : .horizontal
                    }
                    guard axis == .vertical, !ignored else { return }
                    let dy = value.translation.height
                    swipe.offset = dy >= 0 ? dy : Fluid.rubberband(dy, dimension: swipe.height)
                }
                .onEnded { value in
                    defer {
                        axis = nil
                        ignored = false
                    }
                    guard axis == .vertical, !ignored else { return }
                    let velocity = value.velocity.height
                    let projected = swipe.offset + Fluid.project(velocity)
                    let height = swipe.height
                    let start = swipe.offset
                    settling = true
                    if start > 0, velocity > -50, projected > height * 0.3 {
                        if reduceMotion {
                            swipe.offset = 0
                            onDismiss()
                            return
                        }
                        withAnimation(.interpolatingSpring(duration: 0.25, bounce: 0,
                                                           initialVelocity: Fluid.relative(velocity, from: start, to: height))) {
                            swipe.offset = height
                        } completion: {
                            onDismiss()
                        }
                    } else {
                        withAnimation(.interpolatingSpring(duration: 0.35, bounce: abs(velocity) > 300 ? 0.2 : 0,
                                                           initialVelocity: Fluid.relative(velocity, from: start, to: 0))) {
                            swipe.offset = 0
                        }
                    }
                }
        )
        .onDragCancelled(touching, stillBusy: { !settling && (axis != nil || swipe.offset != 0) }) {
            axis = nil
            ignored = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { swipe.offset = 0 }
        }
        .onChange(of: touching) { _, isDown in
            if isDown { settling = false }
        }
    }
}

/// The iPhone's volume (same as the side buttons) as a capsule that tracks
/// your finger from where you grab it, thickens while held, stretches past
/// the ends and gives a tick when it hits silent or full. The speaker icons
/// sit outside the track, so nothing ever covers them.
private struct VolumeBar: View {
    @StateObject private var volume = SystemVolume()
    @State private var grabbedAt: Float?
    @State private var stretch: CGFloat = 0
    @State private var width: CGFloat = 1
    @GestureState private var touching = false

    private var held: Bool { grabbedAt != nil }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(held ? 0.9 : 0.5))
                .scaleEffect(stretch < 0 ? 1.2 : 1)
                .frame(width: 18)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(held ? 1 : 0.85))
                    .frame(width: width * CGFloat(volume.level))
            }
            .frame(height: held ? 11 : 6)
            .scaleEffect(x: 1 + abs(stretch) / max(width, 1), anchor: stretch < 0 ? .trailing : .leading)
            .frame(height: 34)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        if grabbedAt == nil { grabbedAt = volume.level }
                        let raw = (grabbedAt ?? 0) + Float(value.translation.width / max(width, 1))
                        volume.set(raw)
                        let overshoot = CGFloat(raw < 0 ? raw : (raw > 1 ? raw - 1 : 0)) * width
                        stretch = Fluid.rubberband(overshoot, dimension: width, constant: 0.2)
                    }
                    .onEnded { _ in
                        grabbedAt = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { stretch = 0 }
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 1), value: held)
            .onDragCancelled(touching, stillBusy: { grabbedAt != nil }) {
                grabbedAt = nil
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { stretch = 0 }
            }
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(held ? 0.9 : 0.5))
                .scaleEffect(stretch > 0 ? 1.2 : 1)
                .frame(width: 22)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stretch != 0)
        .background { HiddenVolumeView(volume: volume).frame(width: 120, height: 30).allowsHitTesting(false) }
        .sensoryFeedback(.impact(weight: .light), trigger: volume.level <= 0 || volume.level >= 1) { _, edge in edge }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume.level * 100)) percent")
        .accessibilityAdjustableAction { direction in
            volume.set(volume.level + (direction == .increment ? 0.0625 : -0.0625))
        }
    }
}

/// Reads the system volume and sets it through a hidden MPVolumeView, the
/// only way iOS lets apps change it (this also hides the volume HUD).
private final class SystemVolume: ObservableObject {
    @Published private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    /// The hidden system volume view; its slider is looked up when needed,
    /// because iOS builds it only after the view is on screen.
    weak var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?

    private var slider: UISlider? {
        func find(_ view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return volumeView.flatMap(find)
    }

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let value = session.outputVolume
            DispatchQueue.main.async { self?.level = value }
        }
    }

    func set(_ value: Float) {
        let clamped = min(1, max(0, value))
        level = clamped
        guard let slider else { return }
        slider.setValue(clamped, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
    }
}

private struct HiddenVolumeView: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
        view.isUserInteractionEnabled = false
        // Nearly invisible, but still on screen: iOS ignores a fully hidden one.
        view.alpha = 0.011
        volume.volumeView = view
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        volume.volumeView = uiView
    }
}

/// What you're listening on, with the earbuds' battery when they share it.
/// Tap to read the battery (asks for Bluetooth the first time).
private struct HeadphoneChip: View {
    @ObservedObject var monitor: HeadphoneMonitor
    @ObservedObject var equalizer: EqualizerSettings
    @State private var info: String?

    var body: some View {
        if let name = monitor.routeName {
            Button {
                if case .unavailable(let reason) = monitor.battery {
                    info = reason
                } else if monitor.isHeadphones {
                    monitor.refreshBattery()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: monitor.isHeadphones ? "earbuds" : "speaker.wave.2.fill")
                    Text(name).lineLimit(1)
                    if monitor.isHeadphones {
                        battery
                    }
                    if equalizer.enabled, equalizer.headphone != .off, monitor.isHeadphones {
                        Image(systemName: "slider.vertical.3").foregroundStyle(Color.brand)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .animation(.snappy, value: monitor.battery)
            }
            .buttonStyle(PressScaleStyle())
            .alert("Battery", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("Try Again") { monitor.refreshBattery() }
                Button("OK", role: .cancel) {}
            } message: {
                Text(info ?? "")
            }
            .accessibilityLabel("Output: \(name)")
        }
    }

    @ViewBuilder
    private var battery: some View {
        switch monitor.battery {
        case .idle:
            Text("· Battery").foregroundStyle(.white.opacity(0.5))
        case .searching:
            ProgressView().controlSize(.mini).tint(.white)
        case .level(let percent):
            Image(systemName: Self.symbol(percent))
                .foregroundStyle(percent <= 20 ? .red : .white.opacity(0.85))
            Text("\(percent)%").monospacedDigit()
        case .unavailable:
            Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.5))
        }
    }

    private static func symbol(_ percent: Int) -> String {
        switch percent {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

/// AirPlay and Bluetooth output picker.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Square cover for a downloaded track, resolved lazily.
struct ArtworkThumbnail: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: Track
    var size: CGFloat = 48
    var cornerRadius: CGFloat?
    /// The cover, with the song it belongs to: a row reused for another
    /// song must never show the old one.
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        // Shrunk to the size shown, and taken straight from memory when it
        // is there, so scrolling back never flashes the placeholder.
        let bucket = ArtworkResolver.Size.fitting(size)
        let image = loaded?.url == track.url ? loaded?.image : ArtworkResolver.cached(track, size: bucket)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.12, style: .continuous))
        .task(id: track.id) {
            if let image = await ArtworkResolver.shared.image(for: track, meta: library.meta(for: track), size: bucket) {
                loaded = (track.url, image)
            }
        }
    }
}

/// A top-bar button face: a soft disc with a white symbol, drawn by the app
/// so iOS 26 can't swap in an empty glass bubble.
private struct TopBarIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.14), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}
