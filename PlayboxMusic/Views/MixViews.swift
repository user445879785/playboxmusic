import SwiftUI

struct TransitionPair: Identifiable {
    let from: Track
    let to: Track
    var id: String { MixSettings.pairKey(from, to) }
}

/// Up Next as a Spotify-style mixed playlist: cover collage, glowing play
/// button, Mix / Edit / Sort chips, tempo and key per song, and a
/// transition chip between songs that opens the editor.
struct QueueView: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        MixQueueList(mix: player.mix)
    }
}

private struct MixQueueList: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var mix: MixSettings
    @State private var editing: TransitionPair?
    @State private var editMode: EditMode = .inactive
    @State private var sorting = false
    @State private var totalDuration: Double?

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                // Each row is known by its song (and which copy of it, when a
                // song is queued twice), so dragging one moves that row
                // instead of redrawing them all. Press and hold a row to drag it.
                ForEach(queueRows) { item in
                    row(item.track, offset: item.offset)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { player.moveQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }

                Text("When the queue ends, similar songs from your library keep playing.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 12)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(backdrop)
            .environment(\.editMode, $editMode)
            .animation(.snappy, value: isEditing)
            .animation(.snappy, value: mix.isOn)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.headline)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { pair in
                TransitionEditorView(pair: pair)
                    .environmentObject(player)
                    .environmentObject(library)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
        .task(id: player.queue) { await loadTotalDuration() }
    }

    private struct QueueRow: Identifiable {
        let offset: Int
        let track: Track
        let copy: Int
        var id: String { "\(track.url.path)#\(copy)" }
    }

    private var queueRows: [QueueRow] {
        var seen: [URL: Int] = [:]
        return player.queue.enumerated().map { offset, track in
            let copy = seen[track.url, default: 0]
            seen[track.url] = copy + 1
            return QueueRow(offset: offset, track: track, copy: copy)
        }
    }

    // MARK: Header

    private var backdrop: some View {
        LinearGradient(colors: [(player.artworkColor ?? Color(white: 0.2)).opacity(0.9), .black],
                       startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Collage(tracks: Array(player.queue.dropFirst(player.index).prefix(4)))
                .frame(width: 230, height: 230)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            Text("Up Next")
                .font(.title.weight(.bold))
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(Color.brand, in: Circle())
                Text(mix.isOn ? "Mixed by Playbox" : "Playing back to back")
                    .font(.subheadline.weight(.semibold))
            }
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 22) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(player.shuffle ? Color.brand : .white.opacity(0.8))
                }
                .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")
                Spacer()
                GlowPlayButton(isPlaying: player.isPlaying) { player.togglePlayback() }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy) { mix.mode = mix.isOn ? .off : .auto }
                    } label: {
                        ChipLabel(title: "Mix", symbol: "slider.horizontal.3", ring: mix.isOn)
                    }
                    Button {
                        withAnimation(.snappy) { editMode = isEditing ? .inactive : .active }
                    } label: {
                        ChipLabel(title: isEditing ? "Done" : "Edit", symbol: "line.3.horizontal", selected: isEditing)
                    }
                    Menu {
                        ForEach(MusicPlayer.QueueOrder.allCases) { order in
                            Button(order.rawValue) {
                                sorting = true
                                Task {
                                    await player.sortUpcoming(order)
                                    sorting = false
                                }
                            }
                        }
                    } label: {
                        ChipLabel(title: sorting ? "Sorting…" : "Sort", symbol: "arrow.up.arrow.down")
                    }
                    if mix.isOn {
                        Menu {
                            Picker("Default transition", selection: $mix.defaultPreset) {
                                ForEach(MixPreset.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            ChipLabel(title: mix.defaultPreset.rawValue, symbol: "sparkles")
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .sensoryFeedback(.selection, trigger: mix.isOn)
        }
    }

    private var summary: String {
        let count = player.queue.count - player.index
        var parts = ["\(count) song\(count == 1 ? "" : "s")"]
        if let totalDuration, totalDuration > 0 {
            let minutes = Int(totalDuration / 60)
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        return parts.joined(separator: " • ")
    }

    private func loadTotalDuration() async {
        // Lengths come from the files' headers. (This used to decode every
        // song in the queue, the whole library when playing from Library.)
        var total = 0.0
        for track in player.queue.dropFirst(player.index) {
            if Task.isCancelled { return }
            total += await TrackAnalyzer.shared.duration(for: track.url) ?? 0
        }
        totalDuration = total
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ track: Track, offset: Int) -> some View {
        let isCurrent = offset == player.index
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ArtworkThumbnail(track: track, size: 54)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                            PlayingBars(active: player.isPlaying)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.title(of: track))
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.brand : .white)
                        .lineLimit(1)
                    Text(library.meta(for: track)?.artist ?? library.subtitle(of: track))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                TrackFacts(track: track)
                if !isEditing {
                    Menu {
                        Button { player.play(player.queue, startAt: offset) } label: {
                            Label("Play Now", systemImage: "play")
                        }
                        if let next = player.queue[safe: offset + 1] {
                            Button { editing = TransitionPair(from: track, to: next) } label: {
                                Label("Edit Transition", systemImage: "slider.horizontal.3")
                            }
                        }
                        Button(role: .destructive) { player.removeFromQueue(at: IndexSet(integer: offset)) } label: {
                            Label("Remove from Queue", systemImage: "minus.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 30, height: 44)
                    }
                    .accessibilityLabel("More for \(library.title(of: track))")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { player.play(player.queue, startAt: offset) }
            .opacity(offset < player.index ? 0.45 : 1)

            if mix.isOn, !isEditing, offset >= player.index, let next = player.queue[safe: offset + 1] {
                TransitionChip(
                    label: transitionLabel(from: track, to: next, offset: offset),
                    progress: isCurrent && player.isMixing ? player.clock : nil,
                    onReset: mix.transitionOverride(from: track, to: next).isEmpty ? nil : {
                        withAnimation(.snappy) { mix.setOverride(nil, from: track, to: next) }
                    }
                ) {
                    editing = TransitionPair(from: track, to: next)
                }
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func transitionLabel(from: Track, to: Track, offset: Int) -> String {
        if offset == player.index, let plan = player.nextPlan, !plan.isGapless {
            return plan.preset?.rawValue ?? "Custom"
        }
        let custom = mix.transitionOverride(from: from, to: to)
        if custom.volume != nil || custom.eq != nil || custom.effect != nil {
            if let volume = custom.volume, let eq = custom.eq, let effect = custom.effect,
               let preset = MixPreset.matching(volume, eq, effect) {
                return preset.rawValue
            }
            return "Custom"
        }
        return (custom.preset ?? mix.defaultPreset).rawValue
    }
}

/// 2×2 artwork collage for the queue header, with a soft glow.
private struct Collage: View {
    let tracks: [Track]

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width / 2
            Group {
                if tracks.count >= 4 {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ArtworkThumbnail(track: tracks[0], size: side, cornerRadius: 0)
                            ArtworkThumbnail(track: tracks[1], size: side, cornerRadius: 0)
                        }
                        HStack(spacing: 0) {
                            ArtworkThumbnail(track: tracks[2], size: side, cornerRadius: 0)
                            ArtworkThumbnail(track: tracks[3], size: side, cornerRadius: 0)
                        }
                    }
                } else if let first = tracks.first {
                    ArtworkThumbnail(track: first, size: proxy.size.width, cornerRadius: 0)
                } else {
                    Color(white: 0.15)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .overlay(alignment: .top) {
                // A light catching the top edge, as on the Spotify cover.
                Capsule()
                    .fill(.white)
                    .frame(width: 60, height: 3)
                    .blur(radius: 3)
                    .opacity(0.7)
                    .offset(y: -1)
            }
        }
    }
}

/// The small "✦ Auto ›" chip between two songs.
struct TransitionChip: View {
    let label: String
    let progress: PlaybackClock?
    /// Shown as an × when this transition was changed: back to the default.
    var onReset: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1.5, height: 34)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "square.split.diagonal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.brand)
                    Text(label).font(.subheadline.weight(.medium))
                    if let progress {
                        MixProgressLabel(clock: progress)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Transition: \(label). Edit")
            if let onReset {
                Button(action: onReset) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(Color(white: 0.16), in: Circle())
                }
                .buttonStyle(PressScaleStyle())
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Use the default transition")
            }
        }
        .animation(.snappy(duration: 0.2), value: onReset == nil)
    }
}

private struct MixProgressLabel: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        if let progress = clock.mixProgress {
            Text("Mixing \(Int(progress * 100))%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.brand)
        }
    }
}

// MARK: - Transition editor

/// Spotify's transition editor: the two songs' waveforms overlap where they
/// blend, with Volume, EQ and Effects curves drawn on top. Drag a waveform
/// to move it on the beat grid, pick the length in bars, choose each
/// automation lane or a preset, and preview the result.
struct TransitionEditorView: View {
    @EnvironmentObject private var player: MusicPlayer
    let pair: TransitionPair

    var body: some View {
        TransitionEditor(pair: pair, mix: player.mix)
    }
}

private struct TransitionEditor: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    let pair: TransitionPair
    @ObservedObject var mix: MixSettings

    @State private var outgoing: TrackAnalysis?
    @State private var incoming: TrackAnalysis?
    @State private var loaded = false
    @State private var showSettings = false
    /// True while a waveform is being dragged, so the page holds still.
    @State private var timelineHeld = false
    /// Plays the transition on its own, away from the real player.
    @StateObject private var preview = TransitionPreview()

    private var custom: TransitionOverride { mix.transitionOverride(from: pair.from, to: pair.to) }

    private var plan: TransitionPlan? {
        guard let outgoing else { return nil }
        return mix.plan(from: pair.from, outgoing, to: pair.to, incoming,
                        outDuration: outgoing.duration, force: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !loaded {
                Spacer()
                ProgressView("Analysing songs…").tint(.white)
                Spacer()
            } else if let outgoing, let incoming, let plan {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        if !mix.isOn { mixOffBanner }
                        MixTimeline(preview: preview, outgoing: outgoing, incoming: incoming, plan: plan, pair: pair,
                                    held: $timelineHeld,
                                    onMoveStart: { setStart($0) }, onMoveEntry: { setEntry($0, start: plan.mixStart) },
                                    onPreview: { startPreview(plan, at: $0) })
                            .frame(height: 380)
                            .overlay { previewButton(plan) }
                            .padding(.horizontal, 16)
                        // Below the waveform and its slider, clear of both.
                        barsMenu(plan)

                        VStack(spacing: 12) {
                            MixTrackRow(track: pair.from, analysis: outgoing, lane: "Out")
                            MixTrackRow(track: pair.to, analysis: incoming, lane: "In")
                        }
                        .padding(.horizontal, 16)

                        controls(plan)
                            .padding(.horizontal, 16)
                        presets(plan)
                    }
                    .padding(.vertical, 12)
                }
                .scrollDisabled(timelineHeld)
            } else {
                Spacer()
                ContentUnavailableView("Can't Edit This Transition", systemImage: "waveform.slash",
                                       description: Text("One of these files can't be analysed."))
                Spacer()
            }
        }
        .background(Color(white: 0.09).ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationBackground(Color(white: 0.09))
        .sensoryFeedback(.selection, trigger: plan?.preset)
        .sensoryFeedback(.selection, trigger: plan?.bars)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form { MixSettingsForm(mix: mix) }
                    .navigationTitle("Mix Settings")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .interactiveDismissDisabled(timelineHeld)
        .task { await load() }
        .onDisappear { preview.stop() }
        // A changed transition is heard straight away if it is playing.
        .onChange(of: plan.map { [$0.mixStart, $0.entry, Double($0.bars)] }) { _, _ in
            guard preview.isPlaying, let plan, let position = preview.position(at: Date()) else { return }
            startPreview(plan, at: position)
        }
    }

    /// The real song pauses where it is (press Play later and it carries on
    /// from there); only the transition plays.
    private func startPreview(_ plan: TransitionPlan, at position: Double) {
        if player.isPlaying { player.togglePlayback() }
        preview.play(plan, from: pair.from, to: pair.to, at: position)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            Text("Transition").font(.headline)
            Spacer()
            Menu {
                Button { showSettings = true } label: { Label("Mix Settings", systemImage: "gearshape") }
                Button(role: .destructive) {
                    withAnimation(.snappy) { mix.setOverride(nil, from: pair.from, to: pair.to) }
                } label: {
                    Label("Reset to Auto", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 8)
    }

    private var mixOffBanner: some View {
        HStack {
            Text("Mixing is off, so songs play back to back.")
                .font(.footnote)
            Spacer()
            Button("Turn On") { withAnimation { mix.mode = .auto } }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.brand)
        }
        .padding(12)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    private func previewButton(_ plan: TransitionPlan) -> some View {
        let previewing = preview.isPlaying
        return Button {
            if previewing {
                preview.stop()
            } else {
                startPreview(plan, at: -min(TransitionPreview.lead, max(plan.beat * 8, 2)))
            }
        } label: {
            Image(systemName: previewing ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 40)
                .background(.black.opacity(0.75), in: Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(previewing ? "Pause preview" : "Preview transition")
    }

    private func barsMenu(_ plan: TransitionPlan) -> some View {
        Menu {
            Picker("Length", selection: Binding(get: { plan.bars }, set: { setBars($0) })) {
                ForEach(MixSettings.barChoices, id: \.self) { bars in
                    Text("\(bars) bar\(bars == 1 ? "" : "s")").tag(bars)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(plan.bars) bar\(plan.bars == 1 ? "" : "s")")
                    .contentTransition(.numericText())
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }

    private func controls(_ plan: TransitionPlan) -> some View {
        HStack(spacing: 0) {
            lane("Volume", color: MixColor.volume, value: plan.volume, all: MixVolume.allCases) { value in
                edit(plan) { $0.volume = value }
            }
            lane("EQ", color: MixColor.eq, value: plan.eq, all: MixEQ.allCases) { value in
                edit(plan) { $0.eq = value }
            }
            lane("Effects", color: MixColor.effects, value: plan.effect, all: MixEffect.allCases) { value in
                edit(plan) { $0.effect = value }
            }
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25)))
    }

    private func lane<Value: Hashable & Identifiable & RawRepresentable>(
        _ title: String, color: Color, value: Value, all: [Value], set: @escaping (Value) -> Void
    ) -> some View where Value.RawValue == String {
        Menu {
            Picker(title, selection: Binding(get: { value }, set: set)) {
                ForEach(all) { Text($0.rawValue).tag($0) }
            }
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.footnote).foregroundStyle(color)
                HStack(spacing: 3) {
                    Text(value.rawValue).lineLimit(1).minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
    }

    private func presets(_ plan: TransitionPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MixPreset.allCases) { preset in
                    let selected = plan.preset == preset
                    Button { choose(preset) } label: {
                        HStack(spacing: 6) {
                            if let symbol = preset.symbol { Image(systemName: symbol) }
                            Text(preset.rawValue)
                        }
                        .font(.body.weight(.medium))
                        .foregroundStyle(selected ? .black : .white)
                        .frame(minWidth: 84)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 10)
                        .background(selected ? Color.white : Color(white: 0.2),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .animation(.snappy(duration: 0.2), value: selected)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Editing

    /// Changing one lane pins all three, so the others stay as shown.
    private func edit(_ plan: TransitionPlan, _ change: (inout TransitionOverride) -> Void) {
        var value = custom
        value.volume = plan.volume
        value.eq = plan.eq
        value.effect = plan.effect
        change(&value)
        commit(value)
    }

    private func choose(_ preset: MixPreset) {
        var value = custom
        if preset == .auto {
            value = TransitionOverride()
            value.preset = .auto
        } else {
            value.preset = preset
            value.volume = nil
            value.eq = nil
            value.effect = nil
        }
        commit(value)
    }

    private func setBars(_ bars: Int) {
        var value = custom
        value.bars = bars
        commit(value)
    }

    private func setStart(_ seconds: Double) {
        var value = custom
        value.mixStart = seconds
        commit(value)
    }

    private func setEntry(_ seconds: Double, start: Double) {
        var value = custom
        // A first song moved past its end is stored as a later entry for the
        // next one; pin the start where it is shown so that isn't counted twice.
        if value.mixStart != nil { value.mixStart = start }
        value.entry = seconds
        commit(value)
    }

    private func commit(_ value: TransitionOverride) {
        withAnimation(.snappy(duration: 0.3)) {
            mix.setOverride(value, from: pair.from, to: pair.to)
        }
    }

    private func load() async {
        async let out = TrackAnalyzer.shared.analysis(for: pair.from.url)
        async let into = TrackAnalyzer.shared.analysis(for: pair.to.url)
        let (outValue, inValue) = await (out, into)
        outgoing = outValue
        incoming = inValue
        withAnimation(.easeOut(duration: 0.3)) { loaded = true }
    }
}

/// One song in the editor: cover, title, artist, tempo, key and length.
private struct MixTrackRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: Track
    let analysis: TrackAnalysis
    let lane: String

    var body: some View {
        HStack(spacing: 14) {
            ArtworkThumbnail(track: track, size: 56)
                .overlay(alignment: .bottomLeading) {
                    Text(lane)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.white, in: Capsule())
                        .padding(3)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(library.title(of: track)).font(.title3).lineLimit(1)
                Text(library.meta(for: track)?.artist ?? library.subtitle(of: track))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(analysis.bpm.map { "\(Int($0.rounded())) bpm" } ?? "– bpm")
                    .font(.subheadline)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    if let key = analysis.key { KeyBadge(key: key) }
                    Text(TrackFacts.format(analysis.duration))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

/// The overlapping waveforms with automation curves. The top lane is the
/// outgoing song, the bottom lane the incoming one, aligned as they will
/// play. Drag the top lane to move where the blend starts, the bottom
/// lane to change where the next song comes in; both snap to beats.
private struct MixTimeline: View {
    @EnvironmentObject private var player: MusicPlayer
    @ObservedObject var preview: TransitionPreview
    let outgoing: TrackAnalysis
    let incoming: TrackAnalysis
    let plan: TransitionPlan
    let pair: TransitionPair
    @Binding var held: Bool
    let onMoveStart: (Double) -> Void
    let onMoveEntry: (Double) -> Void
    /// Plays the preview from a position relative to the blend's start.
    let onPreview: (Double) -> Void

    // Everything is drawn relative to the start of the blend, which stays
    // put on screen. Each song is a strip that slides under it on its own:
    // moving the top song never moves the bottom one, and the reverse.

    @State private var drag: DragState?
    /// The finger is going up or down: that's the page scrolling, not us.
    @State private var scrolling = false
    /// A strip still sliding after you let go of it.
    @State private var glide: Task<Void, Never>?
    @GestureState private var touching = false
    @GestureState private var seekTouching = false
    @State private var seeking: Double?

    private enum Lane { case outgoing, incoming }

    private struct DragState {
        var lane: Lane
        var window: ClosedRange<Double>
        var origin: Double
        /// Where the moved song is now. Drawn straight away and saved once
        /// it stops, so moving isn't slowed by re-planning the mix.
        var value: Double?
    }

    /// The plan with the strip being moved applied.
    private var shown: TransitionPlan {
        var p = plan
        if let drag, let value = drag.value {
            switch drag.lane {
            case .outgoing: p.mixStart = value
            case .incoming: p.entry = value
            }
        }
        return p
    }

    private var inRate: Double { Double(max(0.25, plan.inRate)) }

    /// The span shown, in seconds from the blend's start. It only changes
    /// when nothing is moving, so strips slide against a still frame.
    private var window: ClosedRange<Double> {
        if let drag { return drag.window }
        let pad = max(plan.length * 0.3, plan.beat * 4, 2)
        let inStarts = max(0, -plan.entry / inRate)
        return -pad...(max(plan.length, inStarts + plan.beat * 4) + pad)
    }

    var body: some View {
        VStack(spacing: 6) {
            // The times sit outside the waveforms, as plain text.
            HStack {
                Text("Out  \(Self.stamp(shown.mixStart))")
                Spacer()
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(MixColor.volume.opacity(0.9))

            GeometryReader { proxy in
                let size = proxy.size
                TimelineView(.animation(paused: !player.isPlaying && !preview.isPlaying)) { context in
                    Canvas { canvas, _ in
                        draw(in: &canvas, size: size, playhead: seeking ?? playhead(at: context.date))
                    }
                }
                .contentShape(Rectangle())
                // Alongside the page's scrolling: a sideways drag moves a
                // song (and holds the page still), an up or down one scrolls.
                .simultaneousGesture(dragGesture(size: size))
                .overlay { nudges }
            }
            .onDragCancelled(touching, stillBusy: { (drag != nil && glide == nil) || scrolling || held }) {
                if glide == nil { finish() }
                scrolling = false
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                Text("In  \(Self.stamp(shown.entry))")
                    .foregroundStyle(MixColor.volume.opacity(0.9))
                if shown.entry < -0.005 {
                    // The next song was pushed later: say so, and offer to undo it.
                    Text("waits \(String(format: "%.1f", -shown.entry / inRate)) s")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Remove Gap") { onMoveEntry(0) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brand)
                } else {
                    Spacer()
                }
            }
            .font(.caption.monospacedDigit().weight(.medium))

            seekBar
        }
        .onDisappear { glide?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transition waveform, \(plan.bars) bars")
        .accessibilityHint("Drag the top song or the bottom song to move it on its own.")
    }

    // MARK: Fine moves

    /// One step of the arrows: 10 milliseconds.
    private static let step = 0.01

    /// Two arrows on each song. Each tap moves only that song 10 ms the way
    /// the arrow points; hold an arrow to keep moving.
    private var nudges: some View {
        VStack(spacing: 0) {
            nudgeRow(.outgoing)
            nudgeRow(.incoming)
        }
        .padding(.vertical, 6)
        .opacity(drag == nil ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: drag == nil)
    }

    private func nudgeRow(_ lane: Lane) -> some View {
        HStack(spacing: 0) {
            arrow(lane, direction: -1)
            Spacer(minLength: 0)
            arrow(lane, direction: 1)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 6)
    }

    private func arrow(_ lane: Lane, direction: Double) -> some View {
        Button { nudge(lane, direction: direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .buttonRepeatBehavior(.enabled)
        .sensoryFeedback(.selection, trigger: lane == .outgoing ? plan.mixStart : plan.entry)
        .accessibilityLabel("\(lane == .outgoing ? "First" : "Second") song \(direction < 0 ? "left" : "right") by 10 milliseconds")
    }

    /// Moving a song right on screen means its part of the blend comes from
    /// earlier in it.
    private func nudge(_ lane: Lane, direction: Double) {
        switch lane {
        case .outgoing: onMoveStart(clamp(plan.mixStart - direction * Self.step, .outgoing))
        case .incoming: onMoveEntry(clamp(plan.entry - direction * Self.step * inRate, .incoming))
        }
    }

    private func clamp(_ value: Double, _ lane: Lane) -> Double {
        switch lane {
        case .outgoing: min(max(0, value), outgoing.duration + 30)
        case .incoming: min(max(-60, value), max(0, incoming.duration - 0.5))
        }
    }

    /// 1:52.340
    static func stamp(_ seconds: Double) -> String {
        let sign = seconds < -0.0005 ? "−" : ""
        let value = abs(seconds)
        let minutes = Int(value / 60)
        return sign + String(format: "%d:%06.3f", minutes, value - Double(minutes) * 60)
    }

    // MARK: Listening

    /// Drag along this bar to hear the transition from that point.
    private var seekBar: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let span = window.upperBound - window.lowerBound
                let head = seeking ?? playhead(at: context.date)
                let fraction = head.map { min(max(($0 - window.lowerBound) / max(span, 0.001), 0), 1) }
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15)).frame(height: 6)
                    if let fraction {
                        Capsule().fill(.white.opacity(0.8))
                            .frame(width: proxy.size.width * fraction, height: 6)
                        Circle().fill(.white)
                            .frame(width: seeking == nil ? 14 : 20, height: seeking == nil ? 14 : 20)
                            .offset(x: proxy.size.width * fraction - (seeking == nil ? 7 : 10))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($seekTouching) { _, state, _ in state = true }
                    .onChanged { value in
                        let span = window.upperBound - window.lowerBound
                        let fraction = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                        seeking = window.lowerBound + fraction * span
                    }
                    .onEnded { _ in
                        if let seeking { onPreview(seeking) }
                        seeking = nil
                    }
            )
        }
        .frame(height: 28)
        .onDragCancelled(seekTouching, stillBusy: { seeking != nil }) { seeking = nil }
        .animation(.snappy(duration: 0.15), value: seeking == nil)
        .accessibilityLabel("Preview position in the transition")
    }

    /// Where the sound is, in seconds from the blend's start: the preview
    /// first, else the real player if it is playing this pair.
    private func playhead(at date: Date) -> Double? {
        if let position = preview.position(at: date) { return position }
        let plan = shown
        let elapsed = player.clock.elapsed(at: date)
        if player.current == pair.from { return elapsed - plan.mixStart }
        if player.current == pair.to { return (elapsed - plan.entry) / inRate }
        return nil
    }

    // MARK: Drawing

    private func draw(in canvas: inout GraphicsContext, size: CGSize, playhead: Double?) {
        let plan = shown
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return }
        let start = window.lowerBound
        let x: (Double) -> CGFloat = { CGFloat(($0 - start) / span) * size.width }
        let laneHeight = size.height * 0.42
        let topLane = CGRect(x: 0, y: size.height * 0.05, width: size.width, height: laneHeight)
        let bottomLane = CGRect(x: 0, y: size.height * 0.53, width: size.width, height: laneHeight)
        let regionStart = x(0), regionEnd = x(plan.length)

        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.13)))
        let region = CGRect(x: regionStart, y: 0, width: max(2, regionEnd - regionStart), height: size.height)
        canvas.fill(Path(roundedRect: region, cornerRadius: 10), with: .color(Color(white: 0.24)))

        // Bar lines on each song's own grid, so they slide with it.
        func bars(_ analysis: TrackAnalysis, lane: CGRect, toSong: (Double) -> Double, toScreen: (Double) -> Double) {
            guard let first = analysis.firstBeat, let beat = analysis.beatLength else { return }
            let bar = beat * 4
            let from = toSong(window.lowerBound), to = toSong(window.upperBound)
            var line = first + ((from - first) / bar).rounded(.up) * bar
            while line < to {
                canvas.fill(Path(CGRect(x: x(toScreen(line)), y: lane.minY, width: 1, height: lane.height)),
                            with: .color(.white.opacity(0.07)))
                line += bar
            }
        }
        bars(outgoing, lane: topLane, toSong: { plan.mixStart + $0 }, toScreen: { $0 - plan.mixStart })
        bars(incoming, lane: bottomLane, toSong: { plan.entry + $0 * inRate }, toScreen: { ($0 - plan.entry) / inRate })

        // Waveforms, brighter inside the blend.
        let columns = Int(size.width / 3)
        for column in 0..<columns {
            let px = CGFloat(column) * 3
            let r = start + Double(px / size.width) * span
            let inside = r >= 0 && r <= plan.length
            let outTime = plan.mixStart + r
            let outPeak = outTime >= 0 && outTime <= outgoing.duration ? outgoing.peak(at: outTime) : 0
            let inTime = plan.entry + r * inRate
            let inPeak = inTime >= 0 && inTime <= incoming.duration ? incoming.peak(at: inTime) : 0
            for (peak, lane, playing) in [(outPeak, topLane, r <= plan.length), (inPeak, bottomLane, r >= 0)] where peak > 0 {
                let height: CGFloat = max(1.5, CGFloat(peak.squareRoot()) * lane.height)
                let bar = CGRect(x: px, y: lane.midY - height / 2, width: 2, height: height)
                let opacity: Double = inside ? 0.85 : (playing ? 0.55 : 0.18)
                canvas.fill(Path(bar), with: .color(.white.opacity(opacity)))
            }
        }

        // Automation curves across the blend: volume, bass EQ and effect.
        let steps = 80
        func curve(_ lane: CGRect, inset: CGFloat, _ value: (Double) -> Double) -> Path {
            let usable = lane.height - inset * 2
            func y(_ level: Double) -> CGFloat {
                lane.minY + inset + CGFloat(1 - min(max(level, 0), 1)) * usable
            }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(value(0))))
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let px: CGFloat = regionStart + CGFloat(t) * (regionEnd - regionStart)
                path.addLine(to: CGPoint(x: px, y: y(value(t))))
            }
            path.addLine(to: CGPoint(x: size.width, y: y(value(1))))
            return path
        }
        let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        let beatFraction = plan.length > 0 ? plan.beat / plan.length : 0.1
        if plan.eq != MixEQ.none {
            canvas.stroke(curve(topLane, inset: 3) { plan.eq.bass($0, beatFraction: beatFraction).out },
                          with: .color(MixColor.eq), style: style)
            canvas.stroke(curve(bottomLane, inset: 3) { plan.eq.bass($0, beatFraction: beatFraction).in },
                          with: .color(MixColor.eq), style: style)
        }
        if plan.effect != MixEffect.none {
            let lane = plan.effect.onIncoming ? bottomLane : topLane
            let effect = plan.effect
            canvas.stroke(curve(lane, inset: 6) { effect == .echo ? effect.amount($0) : 1 - effect.amount($0) },
                          with: .color(MixColor.effects), style: style)
        }
        canvas.stroke(curve(topLane, inset: 0) { Double(plan.volume.gains($0).out) },
                      with: .color(MixColor.volume), style: style)
        canvas.stroke(curve(bottomLane, inset: 0) { Double(plan.volume.gains($0).in) },
                      with: .color(MixColor.volume), style: style)

        if let playhead, window.contains(playhead) {
            let px = x(playhead)
            canvas.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            canvas.fill(Path(ellipseIn: CGRect(x: px - 5, y: -5, width: 10, height: 10)), with: .color(.white))
        }
    }

    // MARK: Moving a song

    /// Seconds of the song per point of finger travel.
    private func secondsPerPoint(_ lane: Lane, width: CGFloat, window: ClosedRange<Double>) -> Double {
        let span = window.upperBound - window.lowerBound
        return span / Double(max(width, 1)) * (lane == .outgoing ? 1 : inRate)
    }

    /// Clicks onto a beat only when it passes close to one, and onto the
    /// song's very start for the bottom strip, so a gap is easy to undo.
    private func magnet(_ raw: Double, _ lane: Lane) -> Double {
        if lane == .incoming, abs(raw) < 0.12 { return 0 }
        let analysis = lane == .outgoing ? outgoing : incoming
        let beat = analysis.snapToBeat(raw)
        return abs(beat - raw) < 0.06 ? beat : raw
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if drag == nil || glide != nil {
                    guard !scrolling else { return }
                    if drag == nil, abs(value.translation.height) > abs(value.translation.width) {
                        scrolling = true
                        return
                    }
                    let lane: Lane = value.startLocation.y < size.height / 2 ? .outgoing : .incoming
                    // Catching a strip that is still sliding: stop it where it is.
                    if glide != nil {
                        glide?.cancel()
                        glide = nil
                        if let current = drag, current.lane != lane { finish() }
                    }
                    held = true
                    let still = drag.flatMap { $0.lane == lane ? $0.value : nil }
                    drag = DragState(lane: lane, window: drag?.window ?? window,
                                     origin: (still ?? (lane == .outgoing ? plan.mixStart : plan.entry))
                                        + Double(value.translation.width) * secondsPerPoint(lane, width: size.width, window: drag?.window ?? window))
                }
                guard let current = drag else { return }
                let seconds = Double(value.translation.width) * secondsPerPoint(current.lane, width: size.width, window: current.window)
                // Follows the finger exactly; dragging right pulls earlier music under the blend.
                drag?.value = magnet(clamp(current.origin - seconds, current.lane), current.lane)
            }
            .onEnded { value in
                scrolling = false
                guard let current = drag, glide == nil else { return }
                // Keeps the speed it was let go with, then slows to a stop,
                // like a carousel.
                let perPoint = secondsPerPoint(current.lane, width: size.width, window: current.window)
                var speed = -Double(value.velocity.width) * perPoint
                guard abs(speed) > 0.3 else { return finish() }
                glide = Task { @MainActor in
                    var last = Date()
                    while !Task.isCancelled, abs(speed) > 0.05 {
                        try? await Task.sleep(for: .milliseconds(8))
                        let now = Date()
                        let dt = now.timeIntervalSince(last)
                        last = now
                        let value = drag?.value ?? current.origin
                        let wanted = value + speed * dt
                        let next = clamp(wanted, current.lane)
                        drag?.value = next
                        // Hit the end of the song: stop there.
                        if next != wanted { break }
                        // UIScrollView's normal deceleration.
                        speed *= pow(0.998, dt * 1000)
                    }
                    guard !Task.isCancelled else { return }
                    if let value = drag?.value { drag?.value = magnet(value, current.lane) }
                    glide = nil
                    finish()
                }
            }
    }

    /// Saves where the moved song ended up.
    private func finish() {
        if let current = drag, let value = current.value {
            switch current.lane {
            case .outgoing: if abs(value - plan.mixStart) > 0.0005 { onMoveStart(value) }
            case .incoming: if abs(value - plan.entry) > 0.0005 { onMoveEntry(value) }
            }
        }
        drag = nil
        held = false
    }
}

// MARK: - Settings

/// Mix options, in Account and behind the editor's menu.
struct MixSettingsForm: View {
    @ObservedObject var mix: MixSettings

    var body: some View {
        Section {
            Toggle("Mix between songs", isOn: Binding(get: { mix.isOn }, set: { mix.mode = $0 ? .auto : .off }))
                .tint(.brand)
            Picker("Default transition", selection: $mix.defaultPreset) {
                ForEach(MixPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(!mix.isOn)
        } footer: {
            Text("Like Spotify's mixed playlists: Auto plans every transition from the songs' tempo, key and outro. Tap a transition in Up Next to change its length, volume, EQ and effects.")
        }

        if mix.isOn {
            Section {
                Toggle("Match tempo and beats", isOn: $mix.matchBeats).tint(.brand)
                Toggle("Match volume", isOn: $mix.matchVolume).tint(.brand)
                Toggle("Skip silence", isOn: $mix.skipSilence).tint(.brand)
            } header: {
                Text("Matching")
            } footer: {
                Text("Songs within 8% of each other's tempo are beat-matched and blended on the bar. Keys are detected so clashing songs get a shorter, filtered blend.")
            }
        }
    }
}
