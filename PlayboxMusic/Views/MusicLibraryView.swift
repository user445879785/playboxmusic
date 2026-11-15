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
    @State private var creatingPlaylist = false
    /// Which chip is on; nil shows everything.
    @State private var chip: LibraryFilter?
    @State private var sortByName = false

    private struct FilterKey: Equatable {
        let text: String
        let songs: Int
    }

    var body: some View {
        // Each list is worked out once per redraw, and only the rows on
        // screen are built: a player change no longer rebuilds 5,000 rows.
        let searching = !filter.isEmpty
        let showSongs = searching || chip == .songs
        let visible = hits?.map(\.track) ?? library.tracks
        let lyricLines = Dictionary((hits ?? []).compactMap { hit in hit.lyric.map { (hit.track.url, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        List {
            if !searching {
                chips
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
            }
            if showSongs {
                if !searching, !library.tracks.isEmpty {
                    LibraryHeader(mix: player.mix, tracks: library.tracks)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                }
                ForEach(visible) { track in
                    LibrarySongRow(track: track, lyric: lyricLines[track.url]) {
                        player.play(visible, startAt: visible.firstIndex(of: track) ?? 0)
                    } onNewPlaylist: {
                        newPlaylistTrack = track
                        namingPlaylist = true
                    }
                    .listRowSeparator(.hidden)
                }
            } else if library.loaded, !library.tracks.isEmpty || !library.playlists.isEmpty {
                sortRow
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .listRowSeparator(.hidden)
                ForEach(entries) { entry in
                    // A hidden link: the row opens its page without the
                    // list's chevron.
                    ZStack {
                        NavigationLink(value: entry.link) { EmptyView() }.opacity(0)
                        LibraryEntryRow(entry: entry)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                    .listRowSeparator(.hidden)
                    .swipeActions {
                        if case .playlist(let id) = entry.link {
                            Button("Delete", role: .destructive) { library.deletePlaylist(id) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.loaded, library.tracks.isEmpty, library.playlists.isEmpty {
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
                Menu {
                    Button { creatingPlaylist = true } label: {
                        Label("New Playlist", systemImage: "music.note.list")
                    }
                    Button { importing = true } label: {
                        Label("Add Songs from Files", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
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
        .sensoryFeedback(.selection, trigger: chip)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, artists or a line of lyrics")
        .navigationTitle("Your Library")
        .navigationDestination(for: LibraryCollection.self) { collection in
            if case .playlist(let id) = collection {
                PlaylistView(id: id)
            } else {
                CollectionView(collection: collection)
            }
        }
        .modifier(NewPlaylistAlert(isPresented: $namingPlaylist, track: newPlaylistTrack))
        .modifier(NewPlaylistAlert(isPresented: $creatingPlaylist, track: nil))
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

    // MARK: Chips and sorting

    /// Playlists, Songs, Albums, Artists. Tap one to show only that; the
    /// cross (or a second tap) shows everything again.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if chip != nil {
                    Button { withAnimation(.snappy(duration: 0.2)) { chip = nil } } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold))
                            .frame(width: 34, height: 34)
                            .background(Color(white: 0.17), in: Circle())
                    }
                    .accessibilityLabel("Show everything")
                    .transition(.scale.combined(with: .opacity))
                }
                ForEach(LibraryFilter.allCases.filter { chip == nil || chip == $0 }) { option in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { chip = chip == option ? nil : option }
                    } label: {
                        Text(option.rawValue).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16).frame(height: 34)
                            .foregroundStyle(chip == option ? Color.black : Color.primary)
                            .background(chip == option ? Color.brand : Color(white: 0.17), in: Capsule())
                    }
                }
            }
            .buttonStyle(PressScaleStyle())
            .padding(.horizontal, 20)
        }
    }

    private var sortRow: some View {
        Button { sortByName.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down").font(.footnote.weight(.semibold))
                Text(sortByName ? "A to Z" : "Recents").font(.subheadline.weight(.medium))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort: \(sortByName ? "A to Z" : "Recents")")
    }

    /// The big rows: All Songs and Starred pinned on top, then your
    /// playlists, Made for You, albums and artists, as the chips allow.
    private var entries: [LibraryEntry] {
        var pinned: [LibraryEntry] = []
        var rest: [LibraryEntry] = []
        func songs(_ count: Int) -> String { "\(count) song\(count == 1 ? "" : "s")" }

        if chip == nil || chip == .playlists {
            if !library.tracks.isEmpty {
                pinned.append(LibraryEntry(id: "all", title: "All Songs",
                                           subtitle: "Playlist • " + songs(library.tracks.count),
                                           cover: .symbol("music.note"), link: .allSongs, pinned: true))
            }
            let starred = library.favourites.count
            if starred > 0 {
                pinned.append(LibraryEntry(id: "starred", title: "Starred", subtitle: "Playlist • " + songs(starred),
                                           cover: .symbol("star.fill"), link: .starred, pinned: true))
            }
            for playlist in library.playlists {
                let tracks = library.tracks(in: playlist)
                rest.append(LibraryEntry(id: playlist.id.uuidString, title: playlist.name,
                                         subtitle: "Playlist • " + songs(tracks.count),
                                         cover: .tracks(tracks), link: .playlist(playlist.id), date: playlist.created))
            }
            if !library.tracks.isEmpty {
                for kind in SmartPlaylist.allCases {
                    rest.append(LibraryEntry(id: "smart." + kind.rawValue, title: kind.name,
                                             subtitle: "Playlist • Made for you",
                                             cover: .symbol(kind.symbol), link: .smart(kind)))
                }
            }
        }
        if chip == nil || chip == .albums {
            for album in library.albums() where chip == .albums || album.tracks.count > 1 {
                rest.append(LibraryEntry(id: "album." + album.name, title: album.name,
                                         subtitle: album.artist.isEmpty ? "Album" : "Album • " + album.artist,
                                         cover: .tracks(Array(album.tracks.prefix(1))), link: .album(album.name),
                                         date: album.newest))
            }
        }
        if chip == .artists {
            for artist in library.artists() {
                rest.append(LibraryEntry(id: "artist." + artist.name, title: artist.name,
                                         subtitle: "Artist • " + songs(artist.tracks.count),
                                         cover: .artist(artist.tracks.first), link: .artist(artist.name),
                                         date: artist.newest))
            }
        }
        rest.sort { first, second in
            sortByName
                ? first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
                : first.date > second.date
        }
        return pinned + rest
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

/// Songs header: song count, Mix and Shuffle chips and the
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
