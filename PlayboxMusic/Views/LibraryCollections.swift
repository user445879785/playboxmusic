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
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        let playing = player.current == track
        HStack(spacing: 12) {
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
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 10))
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
        List {
            CollectionHeader(title: title, tracks: tracks)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                let starred = library.isFavourite(track)
                CollectionSongRow(track: track) {
                    player.play(tracks, startAt: offset)
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
        // Worked out when the page opens (and when songs or stars change),
        // so the list doesn't reshuffle under your finger.
        .onAppear { tracks = library.tracks(in: collection) }
        .onChange(of: library.tracks.count) { _, _ in tracks = library.tracks(in: collection) }
        .onChange(of: library.favourites) { _, _ in
            if collection == .starred { tracks = library.tracks(in: collection) }
        }
    }
}
