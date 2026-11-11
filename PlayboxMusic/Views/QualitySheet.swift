import SwiftUI

/// "GET" on a catalog song or album: the qualities shared on Soulseek,
/// each with its best source already found, then Download.
struct QualitySheet: View {
    enum Kind {
        case song(ITunesItem)
        case album(ITunesItem)
    }

    @EnvironmentObject private var client: SoulseekClient
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let key: String
    @State private var selected: SlskQuality?

    private var item: ITunesItem {
        switch kind {
        case .song(let song): song
        case .album(let album): album
        }
    }

    private var isAlbum: Bool {
        if case .album = kind { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        CatalogArtwork(url: item.artworkURL(size: 300), size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isAlbum ? item.collectionName ?? "" : item.trackName ?? "")
                                .font(.headline).tracking(-0.2).lineLimit(2)
                            Text(item.artistName ?? "").font(.subheadline).foregroundStyle(.secondary)
                            if isAlbum, let count = item.trackCount {
                                Text("\(count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                content
            }
            .navigationTitle("Choose Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .animation(.snappy, value: client.availability[key])
            .animation(.snappy, value: selected)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
        .task { await check() }
        .onChange(of: client.availability[key]) { _, state in
            if case .available(let qualities) = state, selected == nil { selected = qualities.first }
        }
        .onAppear {
            if case .available(let qualities) = client.availability[key] { selected = qualities.first }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch client.availability[key] {
        case .available:
            Section("Quality") {
                if isAlbum {
                    ForEach(client.albumOptions(key)) { option in
                        optionRow(option.quality, best: option.files[0],
                                  extra: "\(option.files.count) files · \(Self.size(option.files.map(\.size).reduce(0, +)))",
                                  sources: option.sources)
                    }
                } else {
                    ForEach(client.songOptions(key)) { option in
                        optionRow(option.quality, best: option.files[0], extra: option.files[0].qualityText,
                                  sources: option.sources)
                    }
                }
            }
            if isAlbum, let selected, let files = client.albumOptions(key).first(where: { $0.quality == selected })?.files {
                Section("Ready to download · \(files[0].folder)") {
                    ForEach(files) { file in
                        HStack {
                            Text(file.title).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text(file.qualityText.components(separatedBy: " · ").prefix(2).joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        case .unavailable:
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No one is sharing this right now").font(.headline)
                    Text("Sharers come and go. Try again later.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Search Again") {
                        client.forgetCheck(key)
                        Task { await check() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        default:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(isAlbum ? "Finding full albums on Soulseek…" : "Finding the best files on Soulseek…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func optionRow(_ quality: SlskQuality, best: SlskSearchResult, extra: String, sources: Int) -> some View {
        Button {
            selected = quality
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == quality ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected == quality ? Color.brand : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(quality.rawValue).font(.subheadline.weight(.semibold))
                        if quality <= .lossless {
                            Image(systemName: quality.symbol).font(.caption).foregroundStyle(Color.brand)
                        }
                    }
                    Text(extra).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(best.freeSlots ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(best.freeSlots ? "Starts now" : "Queued")
                        Text("· \(sources) source\(sources == 1 ? "" : "s")")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { start(play: false) } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button { start(play: true) } label: {
                Label("Download & Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.black)
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(selected == nil)
        .opacity(selected == nil ? 0.4 : 1)
        .padding(.horizontal)
        .padding(.top, 8)
        .background(.bar)
    }

    private func start(play: Bool) {
        guard let selected else { return }
        switch kind {
        case .song(let song):
            Task { await client.downloadSong(key: key, quality: selected, meta: song.trackMeta(), play: play) }
        case .album(let album):
            var meta = album.trackMeta()
            meta.title = album.collectionName ?? ""
            Task { await client.downloadAlbum(key: key, quality: selected, meta: meta, play: play) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    private func check() async {
        switch kind {
        case .song(let song):
            await client.checkSong(key: key, artist: song.artistName, title: song.trackName ?? "",
                                   durationSeconds: song.durationSeconds)
        case .album(let album):
            await client.checkAlbum(key: key, artist: album.artistName, album: album.collectionName ?? "",
                                    trackCount: album.trackCount)
        }
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
