import SwiftUI

/// Library › Playlists: make a new one or open one you made.
struct PlaylistsSection: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Section("Playlists") {
            Button {
                name = ""
                naming = true
            } label: {
                Label("New Playlist", systemImage: "plus.rectangle.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
            ForEach(library.playlists) { playlist in
                NavigationLink(value: playlist) {
                    PlaylistRow(playlist: playlist)
                }
            }
            .onDelete { offsets in
                offsets.map { library.playlists[$0].id }.forEach(library.deletePlaylist)
            }
        }
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { library.createPlaylist(name) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct PlaylistRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let playlist: Playlist

    var body: some View {
        let tracks = library.tracks(in: playlist)
        HStack(spacing: 12) {
            PlaylistCover(tracks: tracks, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Four covers in a square, or one when there are fewer songs.
struct PlaylistCover: View {
    let tracks: [Track]
    let size: CGFloat

    var body: some View {
        let picks = Array(tracks.prefix(4))
        Group {
            if picks.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkThumbnail(track: picks[0], size: size / 2)
                        ArtworkThumbnail(track: picks[1], size: size / 2)
                    }
                    HStack(spacing: 0) {
                        ArtworkThumbnail(track: picks[2], size: size / 2)
                        ArtworkThumbnail(track: picks[3], size: size / 2)
                    }
                }
            } else if let first = picks.first {
                ArtworkThumbnail(track: first, size: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .fill(Color(white: 0.16))
                    .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }
}

/// One playlist: play, shuffle, reorder, remove, rename, add songs.
struct PlaylistView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var renaming = false
    @State private var name = ""
    @State private var adding = false

    private var playlist: Playlist? { library.playlists.first { $0.id == id } }

    var body: some View {
        if let playlist {
            let tracks = library.tracks(in: playlist)
            List {
                Section {
                    VStack(spacing: 14) {
                        PlaylistCover(tracks: tracks, size: 200)
                            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                        Text(playlist.name).font(.title2.weight(.bold)).tracking(-0.4)
                        Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button { player.play(tracks, startAt: 0) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                guard !tracks.isEmpty else { return }
                                player.play(tracks.shuffled(), startAt: 0)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                        .disabled(tracks.isEmpty)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                        Button { player.play(tracks, startAt: offset) } label: {
                            HStack(spacing: 12) {
                                ArtworkThumbnail(track: track, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(library.title(of: track)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                            .foregroundStyle(player.current == track ? Color.brand : .primary)
                                        if library.isFavourite(track) { StarMark() }
                                    }
                                    Text(library.subtitle(of: track)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        // The same song can be in a playlist as often as you like.
                        .swipeActions(edge: .leading) {
                            Button { library.add([track], to: id) } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(.brand)
                        }
                    }
                    .onDelete { library.removeFromPlaylist(id, at: $0) }
                    .onMove { library.movePlaylistItems(id, from: $0, to: $1) }
                    Button {
                        adding = true
                    } label: {
                        Label("Add Songs", systemImage: "plus").foregroundStyle(Color.brand)
                    }
                }
            }
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { adding = true } label: { Label("Add Songs", systemImage: "plus") }
                        Button {
                            name = playlist.name
                            renaming = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) {
                            library.deletePlaylist(id)
                            dismiss()
                        } label: { Label("Delete Playlist", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Save") { library.renamePlaylist(id, to: name) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $adding) {
                AddSongsSheet(playlistID: id)
                    .environmentObject(library)
            }
        } else {
            ContentUnavailableView("Playlist deleted", systemImage: "music.note.list")
        }
    }
}

/// Pick songs from the library to add to a playlist.
private struct AddSongsSheet: View {
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var picked: Set<URL> = []
    @State private var filter = ""

    private var visible: [Track] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return library.tracks }
        return library.tracks.filter {
            library.title(of: $0).localizedCaseInsensitiveContains(needle)
                || library.subtitle(of: $0).localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(visible) { track in
                Button {
                    if picked.contains(track.url) { picked.remove(track.url) } else { picked.insert(track.url) }
                } label: {
                    HStack(spacing: 12) {
                        ArtworkThumbnail(track: track, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(library.title(of: track)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(library.subtitle(of: track)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: picked.contains(track.url) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(picked.contains(track.url) ? Color.brand : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter library")
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        library.add(library.tracks.filter { picked.contains($0.url) }, to: playlistID)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}

/// "Add to Playlist" for menus: each playlist, plus a new one.
struct AddToPlaylistMenu: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: Track
    let onNew: () -> Void

    var body: some View {
        Menu {
            Button(action: onNew) { Label("New Playlist…", systemImage: "plus") }
            ForEach(library.playlists) { playlist in
                Button {
                    library.add([track], to: playlist.id)
                } label: {
                    Label(playlist.name, systemImage: library.contains(track, in: playlist) ? "checkmark" : "music.note.list")
                }
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }
}

/// The name prompt behind "New Playlist…" in a menu; creates it with the song.
struct NewPlaylistAlert: ViewModifier {
    @EnvironmentObject private var library: MusicLibrary
    @Binding var isPresented: Bool
    let track: Track?
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("New Playlist", isPresented: $isPresented) {
            TextField("Name", text: $name)
            Button("Create") {
                library.createPlaylist(name, with: track.map { [$0] } ?? [])
                name = ""
            }
            Button("Cancel", role: .cancel) { name = "" }
        }
    }
}
