import SwiftUI

struct MusicLibraryView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @State private var filter = ""
    /// Search results, worked out off the main thread; nil with no filter.
    @State private var hits: [LibraryHit]?
    @State private var importing = false
    @State private var importedCount: Int?
    @State private var namingPlaylist = false
    @State private var newPlaylistTrack: Track?

    private struct FilterKey: Equatable {
        let text: String
        let songs: Int
    }

    var body: some View {
        // Each list is worked out once per redraw, and only the rows on
        // screen are built: a player change no longer rebuilds 5,000 rows.
        let visible = hits?.map(\.track) ?? library.tracks
        let lyricLines = Dictionary((hits ?? []).compactMap { hit in hit.lyric.map { (hit.track.url, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        let starred = filter.isEmpty ? library.favouriteTracks : []
        List {
            if filter.isEmpty, !library.tracks.isEmpty {
                LibraryHeader(mix: player.mix, tracks: library.tracks)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
            }
            if filter.isEmpty {
                PlaylistsSection()
                if !library.tracks.isEmpty { SmartPlaylistsSection() }
            }
            if !starred.isEmpty {
                Section("Starred") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(starred.enumerated()), id: \.element.id) { offset, track in
                                Button { player.play(starred, startAt: offset) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ArtworkThumbnail(track: track, size: 110)
                                        Text(library.title(of: track)).font(.caption.weight(.semibold)).lineLimit(1)
                                    }
                                    .frame(width: 110)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
            }
            ForEach(visible) { track in
                LibrarySongRow(track: track, lyric: lyricLines[track.url]) {
                    player.play(visible, startAt: visible.firstIndex(of: track) ?? 0)
                } onNewPlaylist: {
                    newPlaylistTrack = track
                    namingPlaylist = true
                }
            }
        }
        .overlay {
            if library.loaded, library.tracks.isEmpty {
                ContentUnavailableView(
                    "No Music Yet",
                    systemImage: "music.note.list",
                    description: Text("Downloaded tracks are saved here and in Files › Playbox Music › Music.")
                )
                .overlay(alignment: .bottom) {
                    Button { importing = true } label: {
                        Label("Add Songs from Files", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(Color.brand, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(PressScaleStyle())
                    .padding(.bottom, 120)
                }
            } else if let hits, hits.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add songs from Files")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: MusicLibrary.importTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let count = await library.importFiles(urls)
                withAnimation(.snappy) { importedCount = count }
            }
        }
        .overlay(alignment: .top) {
            if let importedCount {
                Text(importedCount == 0 ? "No playable songs found" :
                        "Added \(importedCount) song\(importedCount == 1 ? "" : "s")")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(.snappy) { self.importedCount = nil }
                    }
            }
        }
        .sensoryFeedback(.success, trigger: importedCount) { _, new in (new ?? 0) > 0 }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, artists or a line of lyrics")
        .navigationTitle("Library")
        .navigationDestination(for: Playlist.self) { PlaylistView(id: $0.id) }
        .navigationDestination(for: SmartPlaylist.self) { SmartPlaylistView(kind: $0) }
        .modifier(NewPlaylistAlert(isPresented: $namingPlaylist, track: newPlaylistTrack))
        .refreshable { await library.refresh() }
        .onAppear { library.reload() }
        // Searching runs off the main thread a moment after you stop typing.
        .task(id: FilterKey(text: filter, songs: library.tracks.count)) {
            let needle = filter.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else {
                hits = nil
                return
            }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let found = await library.search(needle)
            if !Task.isCancelled { hits = found }
        }
    }
}

/// One song in the library list, with its swipes and menu.
private struct LibrarySongRow: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let track: Track
    /// The line of lyrics that matched the search, if that's how it was found.
    let lyric: String?
    let onPlay: () -> Void
    let onNewPlaylist: () -> Void

    var body: some View {
        let starred = library.isFavourite(track)
        let playing = player.current == track
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ArtworkThumbnail(track: track, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(library.title(of: track)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(playing ? Color.brand : .primary)
                        if starred { StarMark() }
                        if let days = library.snoozeDaysLeft(track) {
                            Label("\(days)d", systemImage: "moon.zzz.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Snoozed for \(days) more days")
                        } else if library.isHidden(track) {
                            Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                                .accessibilityLabel("Hidden")
                        }
                    }
                    if let lyric {
                        Label(lyric, systemImage: "quote.bubble")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("\(library.subtitle(of: track)) · \(track.fileExtension)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if playing {
                    PlayingBars(active: player.isPlaying)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: playing)
        .swipeActions {
            Button("Delete", role: .destructive) { library.delete(track) }
        }
        .swipeActions(edge: .leading) {
            Button {
                library.setFavourite(track, !starred)
            } label: {
                Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star")
            }
            .tint(.brand)
            Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
                .tint(.indigo)
            if library.isSkipped(track) {
                Button {
                    library.unsnooze(track)
                    library.setHidden(track, false)
                } label: { Label("Bring Back", systemImage: "arrow.uturn.backward") }
                    .tint(.green)
            } else {
                Button { library.snooze(track) } label: { Label("Snooze 30 Days", systemImage: "moon.zzz") }
                    .tint(.purple)
            }
        }
        .opacity(library.isSkipped(track) ? 0.5 : 1)
        .contextMenu {
            Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.append") }
            AddToPlaylistMenu(track: track, onNew: onNewPlaylist)
            Button {
                library.setFavourite(track, !starred)
            } label: {
                Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star")
            }
        }
    }
}

/// Library › Made for You: lists that fill themselves.
private struct SmartPlaylistsSection: View {
    var body: some View {
        Section("Made for You") {
            ForEach(SmartPlaylist.allCases) { kind in
                NavigationLink(value: kind) {
                    Label {
                        Text(kind.name).font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: kind.symbol).foregroundStyle(Color.brand)
                    }
                }
            }
        }
    }
}

/// One smart playlist: what it is, Play, Shuffle and its songs.
struct SmartPlaylistView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let kind: SmartPlaylist
    @State private var tracks: [Track] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(kind.detail).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { player.play(tracks, startAt: 0) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { player.play(tracks.shuffled(), startAt: 0) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .disabled(tracks.isEmpty)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                    Button { player.play(tracks, startAt: offset) } label: {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(track: track, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.title(of: track)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    .foregroundStyle(player.current == track ? Color.brand : .primary)
                                Text(library.subtitle(of: track)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: kind.symbol,
                                       description: Text("This list fills up as you add, star and play music."))
            }
        }
        .navigationTitle(kind.name)
        .navigationBarTitleDisplayMode(.inline)
        // Worked out when the page opens, so it doesn't reshuffle under you.
        .onAppear { tracks = library.tracks(in: kind) }
    }
}

/// Spotify-style playlist header: song count, Mix and Shuffle chips and the
/// glowing play button that plays the whole library as a mix.
private struct LibraryHeader: View {
    @EnvironmentObject private var player: MusicPlayer
    @ObservedObject var mix: MixSettings
    let tracks: [Track]

    private var playingLibrary: Bool {
        guard let current = player.current else { return false }
        return tracks.contains(current)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) { mix.mode = mix.isOn ? .off : .auto }
                    } label: {
                        ChipLabel(title: "Mix", symbol: "slider.horizontal.3", ring: mix.isOn)
                    }
                    Button {
                        player.playShuffled(tracks)
                    } label: {
                        ChipLabel(title: "Shuffle", symbol: "shuffle")
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            GlowPlayButton(isPlaying: player.isPlaying && playingLibrary) {
                if playingLibrary {
                    player.togglePlayback()
                } else {
                    player.play(tracks, startAt: 0)
                }
            }
            .padding(.trailing, 6)
        }
        .sensoryFeedback(.selection, trigger: mix.isOn)
    }
}
