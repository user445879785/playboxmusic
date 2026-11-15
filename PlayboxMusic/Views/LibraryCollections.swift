import SwiftUI

/// Something in the Library you can open: a playlist, or a list that
/// builds itself (all songs, starred, an album, an artist, Made for You).
enum LibraryCollection: Hashable {
    case allSongs
    case starred
    case playlist(UUID)
    case smart(SmartPlaylist)
    case album(String)
    case artist(String)
}

/// The Library's filter chips.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"

    var id: String { rawValue }
}

/// One big row on the Library page.
struct LibraryEntry: Identifiable {
    enum Cover {
        case tracks([Track])
        case symbol(String)
        case artist(Track?)
    }

    let id: String
    let title: String
    let subtitle: String
    let cover: Cover
    let link: LibraryCollection
    var pinned = false
    var date = Date.distantPast
}

struct LibraryEntryRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if entry.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.brand)
                            .accessibilityLabel("Pinned")
                    }
                    Text(entry.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        switch entry.cover {
        case .tracks(let tracks):
            PlaylistCover(tracks: tracks, size: 64)
        case .symbol(let symbol):
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color.brand, Color.brand.opacity(0.35)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(.white))
        case .artist(let track):
            if let track {
                ArtworkThumbnail(track: track, size: 64, cornerRadius: 32)
            } else {
                Circle().fill(Color(white: 0.16)).frame(width: 64, height: 64)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            }
        }
    }
}

/// The transition between two songs in a list, like Spotify's mixed
/// playlists: tap it to open the editor. Nothing shows while mixing is off,
/// so the next song simply follows.
struct ListTransitionChip: View {
    @ObservedObject var mix: MixSettings
    let from: Track
    let to: Track
    let onTap: (TransitionPair) -> Void

    var body: some View {
        if mix.isOn {
            TransitionChip(label: mix.label(from: from, to: to), progress: nil,
                           onReset: mix.transitionOverride(from: from, to: to).isEmpty ? nil : {
                               withAnimation(.snappy) { mix.setOverride(nil, from: from, to: to) }
                           }) {
                onTap(TransitionPair(from: from, to: to))
            }
            .padding(.leading, 18)
        }
    }
}

extension View {
    /// Puts the transition to the next song under a song row.
    func mixChip(to next: Track?, from track: Track, mix: MixSettings,
                    onTap: @escaping (TransitionPair) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            self
            if let next { ListTransitionChip(mix: mix, from: track, to: next, onTap: onTap) }
        }
    }
}

/// The accent colour glowing down from the top of a list page.
struct CollectionBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color.brand.opacity(0.85), Color.brand.opacity(0.3), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 380)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
    }
}

/// The top of a list page: big title, song count, then covers on the left
/// and Shuffle and a round Play button on the right.
struct CollectionHeader: View {
    @EnvironmentObject private var player: MusicPlayer
    let title: String
    let tracks: [Track]

    private var playingThis: Bool {
        guard let current = player.current else { return false }
        return tracks.contains(current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.6)
                .lineLimit(2).minimumScaleFactor(0.7)
            Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                PlaylistCover(tracks: tracks, size: 44)
                Spacer()
                Button { player.play(tracks.shuffled(), startAt: 0) } label: {
                    Image(systemName: "shuffle").font(.title2.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Shuffle")
                Button {
                    if playingThis { player.togglePlayback() } else { player.play(tracks, startAt: 0) }
                } label: {
                    Circle().fill(Color.brand).frame(width: 58, height: 58)
                        .overlay(
                            Image(systemName: playingThis && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2).foregroundStyle(.black)
                                .contentTransition(.symbolEffect(.replace))
                        )
                }
                .accessibilityLabel(playingThis && player.isPlaying ? "Pause" : "Play")
            }
            .buttonStyle(PressScaleStyle())
            .disabled(tracks.isEmpty)
            .padding(.top, 10)
        }
        .padding(.top, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 10, trailing: 20))
    }
}

/// A song on a list page: cover, title (accent while it plays), artist,
/// and a "more" button.
struct CollectionSongRow<MenuItems: View>: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let track: Track
    var detail: String?
    var next: Track?
    var onTransition: (TransitionPair) -> Void = { _ in }
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        row.mixChip(to: next, from: track, mix: player.mix, onTap: onTransition)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 10))
    }

    private var row: some View {
        let playing = player.current == track
        return HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    ArtworkThumbnail(track: track, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if playing { PlayingBars(active: player.isPlaying) }
                            Text(library.title(of: track)).font(.body).lineLimit(1)
                                .foregroundStyle(playing ? Color.brand : .primary)
                        }
                        Text(detail ?? library.meta(for: track)?.artist ?? library.subtitle(of: track))
                            .font(.subheadline).foregroundStyle(detail == nil ? Color.secondary : Color.brand)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { menu() } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
    }
}

/// A list page for anything that isn't a hand-made playlist: all songs,
/// starred, an album, an artist or a Made for You list.
struct CollectionView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let collection: LibraryCollection
    @State private var tracks: [Track] = []
    @State private var namingPlaylist = false
    @State private var newPlaylistTrack: Track?
    @State private var editing: TransitionPair?
    @State private var filter: String?
    @State private var labels: [URL: Set<String>] = [:]

    private var title: String {
        switch collection {
        case .allSongs: "All Songs"
        case .starred: "Starred"
        case .smart(let kind): kind.name
        case .album(let name), .artist(let name): name
        case .playlist: ""
        }
    }

    var body: some View {
        // With a filter on, only its songs show and play.
        let shown = filter.map { chosen in tracks.filter { labels[$0.url]?.contains(chosen) == true } } ?? tracks
        List {
            CollectionHeader(title: title, tracks: shown)
            SongFilterBar(tracks: tracks, selected: $filter, labels: $labels)
            ForEach(Array(shown.enumerated()), id: \.element.id) { offset, track in
                let starred = library.isFavourite(track)
                CollectionSongRow(track: track, next: shown[safe: offset + 1], onTransition: { editing = $0 }) {
                    player.play(shown, startAt: offset)
                } menu: {
                    Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
                    Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.append") }
                    AddToPlaylistMenu(track: track) {
                        newPlaylistTrack = track
                        namingPlaylist = true
                    }
                    Button { library.setFavourite(track, !starred) } label: {
                        Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { CollectionBackdrop() }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "music.note.list",
                                       description: Text("This list fills up as you add, star and play music."))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NewPlaylistAlert(isPresented: $namingPlaylist, track: newPlaylistTrack))
        .sheet(item: $editing) { pair in
            TransitionEditorView(pair: pair)
                .environmentObject(player)
                .environmentObject(library)
        }
        // Worked out when the page opens (and when songs or stars change),
        // so the list doesn't reshuffle under your finger.
        .onAppear { tracks = library.tracks(in: collection) }
        .onChange(of: library.tracks.count) { _, _ in tracks = library.tracks(in: collection) }
        .onChange(of: library.favourites) { _, _ in
            if collection == .starred { tracks = library.tracks(in: collection) }
        }
    }
}

// MARK: - Genre and mood filters

/// Spotify-style filter chips for a list of songs: its genres (from the
/// songs' tags or the catalogue) and moods (from tempo, for songs already
/// measured). Tap one to show only those songs; × shows them all again.
struct SongFilterBar: View {
    @EnvironmentObject private var library: MusicLibrary
    let tracks: [Track]
    @Binding var selected: String?
    @Binding var labels: [URL: Set<String>]

    private struct Key: Hashable { let urls: [URL] }

    /// Chips in order of how many songs they hold.
    private var chips: [String] {
        var counts: [String: Int] = [:]
        for track in tracks { for label in labels[track.url] ?? [] { counts[label, default: 0] += 1 } }
        return counts.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    var body: some View {
        let options = chips
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if selected != nil {
                    Button { withAnimation(.snappy(duration: 0.2)) { selected = nil } } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold))
                            .frame(width: 34, height: 34)
                            .background(Color(white: 0.17), in: Circle())
                    }
                    .accessibilityLabel("Show all songs")
                    .transition(.scale.combined(with: .opacity))
                }
                ForEach(options.filter { selected == nil || selected == $0 }, id: \.self) { label in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { selected = selected == label ? nil : label }
                    } label: {
                        Text(label).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16).frame(height: 34)
                            .foregroundStyle(selected == label ? Color.black : Color.primary)
                            .background(selected == label ? Color.brand : Color(white: 0.17), in: Capsule())
                    }
                }
            }
            .buttonStyle(PressScaleStyle())
            .padding(.horizontal, 20)
        }
        .frame(height: options.isEmpty ? 0 : 40)
        .opacity(options.isEmpty ? 0 : 1)
        .sensoryFeedback(.selection, trigger: selected)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Worked out in the background, a song at a time, and kept.
        .task(id: Key(urls: tracks.map(\.url))) {
            for track in tracks where labels[track.url] == nil {
                if Task.isCancelled { return }
                let meta = library.meta(for: track)
                let found = await Self.labels(for: track, artist: meta?.artist, title: meta?.title)
                labels[track.url] = found
            }
        }
    }

    static func labels(for track: Track, artist: String?, title: String?) async -> Set<String> {
        var found = Set<String>()
        let genre = await GenreResolver.shared.genre(for: track.url, artist: artist, title: title)
        if genre != .unknown { found.insert(genre.name) }
        // Mood from tempo, only for songs already measured (measuring a whole
        // playlist here would be slow).
        if let bpm = await TrackAnalyzer.shared.stored(for: track.url)?.bpm {
            found.insert(bpm < 98 ? "Chill" : bpm < 124 ? "Upbeat" : "Energetic")
        }
        return found
    }
}
