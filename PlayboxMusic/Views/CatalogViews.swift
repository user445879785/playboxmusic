import AVFoundation
import Combine
import SwiftUI

/// Plays Apple's free 30-second previews.
@MainActor
final class PreviewPlayer: ObservableObject {
    static let shared = PreviewPlayer()
    @Published private(set) var playingID: Int?
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?

    func toggle(_ item: ITunesItem) {
        if playingID == item.id {
            stop()
            return
        }
        guard let string = item.previewUrl, let url = URL(string: string) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        playingID = item.id
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        playingID = nil
    }
}

/// Catalog home: recent searches, charts, new releases and genres.
struct CatalogHomeView: View {
    let recentSearches: [String]
    let onSearch: (String) -> Void
    @State private var topSongs: [ITunesItem] = []
    @State private var topAlbums: [ITunesItem] = []
    @State private var newReleases: [ITunesItem] = []

    var body: some View {
        if !recentSearches.isEmpty {
            Section("Recent Searches") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentSearches, id: \.self) { term in
                            Button(term) { onSearch(term) }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color(white: 0.15), in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        }

        AlbumCarousel(title: "Top Albums", albums: topAlbums)
        AlbumCarousel(title: "New Releases", albums: newReleases)

        if !topSongs.isEmpty {
            Section("Top Songs") {
                ForEach(Array(topSongs.prefix(15).enumerated()), id: \.element.id) { rank, song in
                    SongRow(song: song, leading: "\(rank + 1)")
                }
            }
        }

        Section("Genres") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(ITunesCatalog.genres.indices, id: \.self) { index in
                    let genre = ITunesCatalog.genres[index]
                    NavigationLink(value: GenreRoute(id: genre.id, name: genre.name)) {
                        HStack {
                            Image(systemName: genre.symbol)
                            Text(genre.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .task {
            guard topSongs.isEmpty else { return }
            async let songs = try? ITunesCatalog.chart("topsongs", limit: 30)
            async let albums = try? ITunesCatalog.chart("topalbums", limit: 30)
            async let releases = try? ITunesCatalog.newReleases()
            let (s, a, r) = await (songs, albums, releases)
            topSongs = s ?? []
            topAlbums = a ?? []
            newReleases = Array((r ?? []).prefix(20))
        }
    }
}

struct GenreRoute: Hashable {
    let id: Int
    let name: String
}

struct GenreView: View {
    let route: GenreRoute
    @State private var albums: [ITunesItem] = []
    @State private var songs: [ITunesItem] = []
    @State private var loading = true

    var body: some View {
        List {
            AlbumCarousel(title: "Top Albums", albums: albums)
            if !songs.isEmpty {
                Section("Top Songs") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { rank, song in
                        SongRow(song: song, leading: "\(rank + 1)")
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(route.name)
        .task {
            async let a = try? ITunesCatalog.chart("topalbums", genre: route.id, limit: 25)
            async let s = try? ITunesCatalog.chart("topsongs", genre: route.id, limit: 40)
            let (albumResults, songResults) = await (a, s)
            albums = albumResults ?? []
            songs = songResults ?? []
            loading = false
        }
    }
}

/// iTunes-catalog search results: albums as covers, songs as rows.
struct CatalogResultsView: View {
    let albums: [ITunesItem]
    let songs: [ITunesItem]

    var body: some View {
        AlbumCarousel(title: "Albums", albums: albums)
        if !songs.isEmpty {
            Section("Songs") {
                ForEach(songs) { song in SongRow(song: song) }
            }
        }
    }
}

struct AlbumCarousel: View {
    let title: String
    let albums: [ITunesItem]

    var body: some View {
        if !albums.isEmpty {
            Section(title) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { album in
                            AlbumTile(album: album)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
        }
    }
}

/// An album cover in a carousel. Checked on Soulseek as it scrolls into
/// view and left out when no one shares it.
private struct AlbumTile: View {
    @EnvironmentObject private var client: SoulseekClient
    let album: ITunesItem

    private var key: String { "album-\(album.id)" }

    var body: some View {
        if client.availability[key] != .unavailable {
            NavigationLink(value: album) {
                VStack(alignment: .leading, spacing: 4) {
                    CatalogArtwork(url: album.artworkURL(size: 400), size: 140)
                        .overlay(alignment: .bottomTrailing) {
                            AvailabilityBadge(state: client.availability[key]).padding(6)
                        }
                    Text(album.collectionName ?? "")
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(album.artistName ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 140, alignment: .leading)
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .task(id: client.isConnected) {
                await client.checkAlbum(key: key, artist: album.artistName, album: album.collectionName ?? "",
                                        trackCount: album.trackCount)
            }
        }
    }
}

/// A tiny mark on covers and rows: spinner while checking, the best
/// quality once found.
struct AvailabilityBadge: View {
    let state: SoulseekClient.Availability?

    var body: some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.mini).tint(.white)
                .padding(4).background(.ultraThinMaterial, in: Circle())
        case .available(let qualities):
            if let best = qualities.first, best <= .lossless {
                Text(best == .hiRes ? "HI-RES" : "LOSSLESS")
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        default:
            EmptyView()
        }
    }
}

/// A song with cover, preview on tap, downloaded mark and GET button.
/// Checked on Soulseek as it appears, and left out when no one shares it.
struct SongRow: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var client: SoulseekClient
    @ObservedObject private var preview = PreviewPlayer.shared
    let song: ITunesItem
    var leading: String?
    var showsArtwork = true
    /// Off while an album page is still checking the whole album, which
    /// answers for its songs without one search each.
    var probe = true

    private var key: String { "song-\(song.id)" }

    var body: some View {
        if client.availability[key] == .unavailable && downloadedCopy == nil {
            EmptyView()
        } else {
            row
                .task(id: probe && client.isConnected) {
                    guard probe, downloadedCopy == nil else { return }
                    await client.checkSong(key: key, artist: song.artistName, title: song.trackName ?? "",
                                           durationSeconds: song.durationSeconds)
                }
        }
    }

    private var downloadedCopy: Track? { library.downloaded(title: song.trackName, artist: song.artistName) }

    private var row: some View {
        HStack(spacing: 12) {
            if let leading {
                Text(leading)
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
            }
            if showsArtwork {
                CatalogArtwork(url: song.artworkURL(size: 200), size: 48)
                    .overlay {
                        if preview.playingID == song.id {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(song.trackName ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                    if let copy = downloadedCopy {
                        if library.isFavourite(copy) { StarMark() }
                        DownloadedMark()
                    } else if case .checking = client.availability[key] {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text([song.artistName, showsArtwork ? song.collectionName : song.durationText]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            GetSongButton(song: song)
        }
        .contentShape(Rectangle())
        .onTapGesture { PreviewPlayer.shared.toggle(song) }
        .accessibilityAction(named: preview.playingID == song.id ? "Stop preview" : "Play preview") {
            PreviewPlayer.shared.toggle(song)
        }
    }
}

/// Album page modelled on the iTunes Store layout.
struct AlbumDetailView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var client: SoulseekClient
    let album: ITunesItem
    @State private var albumChecked = false
    @State private var tracks: [ITunesItem] = []
    @State private var moreByArtist: [ITunesItem] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Songs") {
                if loading { ProgressView().frame(maxWidth: .infinity) }
                ForEach(tracks) { track in
                    SongRow(song: track, leading: "\(track.trackNumber ?? 0)", showsArtwork: false, probe: albumChecked)
                }
            }

            AlbumCarousel(title: "More by \(album.artistName ?? "Artist")", albums: moreByArtist)
        }
        .navigationTitle(album.collectionName ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { PreviewPlayer.shared.stop() }
        .task {
            guard let id = album.collectionId else { return }
            async let songs = try? ITunesCatalog.albumTracks(id)
            async let more = otherAlbums()
            let (songResults, moreResults) = await (songs, more)
            tracks = songResults ?? []
            moreByArtist = (moreResults ?? []).filter { $0.collectionId != album.collectionId }.prefix(15).map { $0 }
            loading = false
        }
        .task(id: client.isConnected) {
            // Check the album once, credit its songs from the same folders,
            // then let any song still unknown look for itself.
            let key = "album-\(album.id)"
            await client.checkAlbum(key: key, artist: album.artistName, album: album.collectionName ?? "",
                                    trackCount: album.trackCount)
            while loading { try? await Task.sleep(for: .milliseconds(200)) }
            client.adoptAlbumSongs(albumKey: key, songs: tracks.map { ("song-\($0.id)", $0.trackName ?? "") })
            albumChecked = true
        }
    }

    private func otherAlbums() async -> [ITunesItem]? {
        guard let artistId = album.artistId else { return nil }
        return try? await ITunesCatalog.artistAlbums(artistId)
    }

    private var header: some View {
        ZStack {
            // Blurred cover behind the header, fading into the page.
            CatalogArtwork(url: album.artworkURL(size: 300), size: 420)
                .blur(radius: 50)
                .opacity(0.45)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom))

            HStack(alignment: .top, spacing: 16) {
                CatalogArtwork(url: album.artworkURL(size: 600), size: 150)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(album.collectionName ?? "").font(.title3.bold()).lineLimit(3)
                        if album.isExplicit { ExplicitBadge() }
                    }
                    if let artistId = album.artistId, let name = album.artistName {
                        NavigationLink(value: ITunesItem.artist(id: artistId, name: name)) {
                            HStack(spacing: 2) {
                                Text(name).lineLimit(1)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 4)
                    Group {
                        if let genre = album.primaryGenreName { Text(genre) }
                        if let count = album.trackCount { Text("\(count) Songs") }
                        if let released = album.releaseText { Text(released) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    GetAlbumButton(album: album).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

/// Artist page: top songs, albums and singles.
struct ArtistView: View {
    let artist: ITunesItem
    @State private var songs: [ITunesItem] = []
    @State private var albums: [ITunesItem] = []
    @State private var loading = true

    var body: some View {
        List {
            if !songs.isEmpty {
                Section("Top Songs") {
                    ForEach(songs.prefix(10)) { song in SongRow(song: song) }
                }
            }
            AlbumCarousel(title: "Albums", albums: albums.filter { !$0.isSingle })
            AlbumCarousel(title: "Singles & EPs", albums: albums.filter(\.isSingle))
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(artist.artistName ?? "Artist")
        .onDisappear { PreviewPlayer.shared.stop() }
        .task {
            guard let id = artist.artistId else { return }
            async let s = try? ITunesCatalog.artistSongs(id)
            async let a = try? ITunesCatalog.artistAlbums(id)
            let (songResults, albumResults) = await (s, a)
            songs = songResults ?? []
            albums = albumResults ?? []
            loading = false
        }
    }
}

/// Outlined capsule like the iTunes price button. Finds the song on
/// Soulseek, downloads the best file and plays it.
private struct GetSongButton: View {
    @EnvironmentObject private var client: SoulseekClient
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let song: ITunesItem
    @State private var choosing = false

    private var key: String { "song-\(song.id)" }

    var body: some View {
        button
            .sheet(isPresented: $choosing) {
                QualitySheet(kind: .song(song), key: key)
                    .environmentObject(client)
            }
    }

    private var button: some View {
        FetchButton(state: client.fetches[key], transfers: client.transfers, label: "GET") {
            guard client.isConnected else { return }
            PreviewPlayer.shared.stop()
            choosing = true
        } onPlay: { url in
            library.reload()
            player.play([library.track(for: url)], startAt: 0)
        }
        .disabled(!client.isConnected)
    }
}

private struct GetAlbumButton: View {
    @EnvironmentObject private var client: SoulseekClient
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let album: ITunesItem
    @State private var choosing = false

    private var key: String { "album-\(album.id)" }

    var body: some View {
        Group {
            if client.availability[key] == .unavailable {
                Label("Not shared on Soulseek right now", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                button
            }
        }
        .sheet(isPresented: $choosing) {
            QualitySheet(kind: .album(album), key: key)
                .environmentObject(client)
        }
    }

    private var button: some View {
        FetchButton(state: client.fetches[key], transfers: client.transfers, label: "GET ALBUM") {
            guard client.isConnected else { return }
            choosing = true
        } onPlay: { url in
            library.reload()
            player.play([library.track(for: url)], startAt: 0)
        }
        .disabled(!client.isConnected)
    }
}

private struct FetchButton: View {
    let state: SoulseekClient.FetchState?
    let transfers: [SlskTransfer]
    let label: String
    let onGet: () -> Void
    let onPlay: (URL) -> Void

    private var owned: [SlskTransfer] {
        guard case .downloading(let ids) = state else { return [] }
        return transfers.filter { ids.contains($0.id) }
    }

    var body: some View {
        switch state {
        case .searching:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 64, minHeight: 28)
                .overlay(Capsule().stroke(.tint, lineWidth: 1))
                .accessibilityLabel("Finding on Soulseek")
        case .downloading:
            downloading
        case .notFound:
            Button(action: onGet) { capsule("RETRY") }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .accessibilityLabel("Not found on Soulseek. Retry")
        case nil:
            Button(action: onGet) { capsule(label) }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private var downloading: some View {
        let completed = owned.compactMap { transfer -> URL? in
            if case .completed(let url) = transfer.state { return url }
            return nil
        }
        if !owned.isEmpty, owned.allSatisfy({ if case .failed = $0.state { return true } else { return false } }) {
            Button(action: onGet) { capsule("RETRY") }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        } else if let first = completed.first, completed.count == owned.count {
            Button { onPlay(first) } label: {
                Text("PLAY")
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 64, minHeight: 28)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else {
            let progress = owned.isEmpty ? 0 : owned.map(\.progress).reduce(0, +) / Double(owned.count)
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.03, progress))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.tint)
            }
            .frame(width: 28, height: 28)
            .frame(minWidth: 64)
            .accessibilityLabel("Downloading \(Int(progress * 100)) percent")
        }
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .frame(minWidth: 64, minHeight: 28)
            .overlay(Capsule().stroke(.tint, lineWidth: 1))
            .contentShape(Capsule())
    }
}

struct CatalogArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color(white: 0.14).overlay {
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.05))
    }
}

private struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 13, height: 13)
            .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
            .accessibilityLabel("Explicit")
    }
}
