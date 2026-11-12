import SwiftUI

struct MusicSearchView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var query = ""
    @State private var audioOnly = true
    @State private var sort: Sort = .best
    @State private var mode: Mode = .catalog
    @State private var field: Field = .title
    @State private var quality: SlskQuality?
    @AppStorage("search.exactWords") private var exactWords = true
    /// What was sent to Soulseek, which the filters match against.
    @State private var submitted = ""
    @State private var albums: [ITunesItem] = []
    @State private var songs: [ITunesItem] = []
    @State private var catalogLoading = false
    @AppStorage("music.recentSearches") private var recentStore = ""

    private var recentSearches: [String] {
        recentStore.split(separator: "\n").map(String.init)
    }

    private func remember(_ term: String) {
        let list = [term] + recentSearches.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        recentStore = list.prefix(10).joined(separator: "\n")
    }

    enum Mode: String, CaseIterable, Identifiable {
        case catalog = "Catalog"
        case soulseek = "Soulseek"
        var id: String { rawValue }
    }

    /// What the words should match: the song's file name, its album
    /// folder, or anywhere (artist folders and names).
    enum Field: String, CaseIterable, Identifiable {
        case title = "Title"
        case album = "Album"
        case artist = "Artist"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case best = "Best match"
        case quality = "Quality"
        case size = "Size"
        var id: String { rawValue }
    }

    private func matches(_ result: SlskSearchResult) -> Bool {
        if let quality, SlskQuality.of(result) != quality { return false }
        let words = submitted
        guard !words.isEmpty else { return true }
        switch field {
        case .title:
            return SlskMatch.containsAll(words, in: result.title, exact: exactWords)
        case .album:
            let folders = result.filename.split(whereSeparator: { $0 == "\\" || $0 == "/" }).dropLast().joined(separator: " ")
            return SlskMatch.containsAll(words, in: folders, exact: exactWords)
        case .artist:
            return SlskMatch.containsAll(words, in: result.filename, exact: exactWords)
        }
    }

    private var visibleResults: [SlskSearchResult] {
        let base = audioOnly ? client.results.filter(\.isAudio) : client.results
        let filtered = base.filter(matches)
        let sorted: [SlskSearchResult]
        switch sort {
        case .best:
            // Prefer users who can start immediately, then fast, short queues.
            sorted = filtered.sorted {
                if $0.freeSlots != $1.freeSlots { return $0.freeSlots }
                if $0.queueLength != $1.queueLength { return $0.queueLength < $1.queueLength }
                return $0.uploadSpeed > $1.uploadSpeed
            }
        case .quality:
            sorted = filtered.sorted { Self.qualityScore($0) > Self.qualityScore($1) }
        case .size:
            sorted = filtered.sorted { $0.size > $1.size }
        }
        return Array(sorted.prefix(400))
    }

    var body: some View {
        List {
            Section {
                Picker("Search", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if !client.isConnected {
                Section {
                    NavigationLink {
                        MusicAccountView()
                    } label: {
                        Label("Sign in to Soulseek to download", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                }
            }

            if mode == .catalog {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    CatalogHomeView(recentSearches: recentSearches) { term in query = term }
                } else {
                    CatalogResultsView(albums: albums, songs: songs)
                }
            } else {
                Section {
                    VStack(spacing: 10) {
                        Picker("Match", selection: $field) {
                            ForEach(Field.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        QualityChips(selection: $quality, counts: qualityCounts)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if !client.results.isEmpty || client.isSearching {
                    Section {
                        if field == .album {
                            ForEach(folderGroups) { group in
                                FolderRow(files: group.files)
                            }
                        } else {
                            ForEach(visibleResults) { result in
                                ResultRow(result: result)
                            }
                        }
                    } header: {
                        HStack {
                            Text(field == .album
                                 ? "\(folderGroups.count) albums · \(visibleResults.count) files"
                                 : "\(visibleResults.count) of \(client.results.count) files")
                            if client.isSearching {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if mode == .catalog {
                if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    if catalogLoading && albums.isEmpty && songs.isEmpty {
                        ProgressView()
                    } else if !catalogLoading && albums.isEmpty && songs.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            } else if client.isConnected && client.results.isEmpty && !client.isSearching {
                ContentUnavailableView(
                    "Search Soulseek",
                    systemImage: "music.magnifyingglass",
                    description: Text("Try an artist and album or track title. Results arrive from peers over a few seconds.")
                )
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artist, album or track")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // Switching modes searches the same words in the new mode, so you
        // never see the other mode's old results.
        .onChange(of: mode) { _, newMode in
            quality = nil
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if newMode == .soulseek, term.count >= 2, term != submitted {
                submitted = term
                Task { await client.search(term) }
            }
        }
        .onSubmit(of: .search) {
            if mode == .soulseek {
                submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await client.search(query) }
            } else {
                remember(query)
            }
        }
        // The catalog is fast, so it searches as you type.
        .task(id: mode == .catalog ? "catalog|" + query : "soulseek") {
            guard mode == .catalog else { return }
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2 else {
                albums = []
                songs = []
                return
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            catalogLoading = true
            defer { catalogLoading = false }
            async let foundAlbums = try? ITunesCatalog.search(term, entity: "album", limit: 20)
            async let foundSongs = try? ITunesCatalog.search(term, entity: "song", limit: 40)
            let (newAlbums, newSongs) = await (foundAlbums ?? [], foundSongs ?? [])
            guard !Task.isCancelled else { return }
            albums = newAlbums
            songs = newSongs
            catalogLoading = false
            // Remember searches the user settled on.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if !newAlbums.isEmpty || !newSongs.isEmpty { remember(term) }
        }
        .navigationDestination(for: ITunesItem.self) { item in
            if item.wrapperType == "artist" { ArtistView(artist: item) } else { AlbumDetailView(album: item) }
        }
        .navigationDestination(for: GenreRoute.self) { GenreView(route: $0) }
        .toolbar {
            // Only in Soulseek mode. Hiding it with opacity left iOS 26's
            // glass bubble on screen with no icon in it.
            if mode == .soulseek {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Audio files only", isOn: $audioOnly)
                        Toggle("Whole words only", isOn: $exactWords)
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Filter and sort")
                }
            }
        }
    }

    private var qualityCounts: [SlskQuality: Int] {
        let base = (audioOnly ? client.results.filter(\.isAudio) : client.results)
        return Dictionary(grouping: base, by: SlskQuality.of).mapValues(\.count)
    }

    /// Album tab: matching files grouped into shared folders, biggest first.
    private struct FolderGroup: Identifiable {
        let id: String
        let files: [SlskSearchResult]
    }

    private var folderGroups: [FolderGroup] {
        let groups = Dictionary(grouping: visibleResults) { result -> String in
            result.username + "\u{1F}" + result.filename.split(whereSeparator: { $0 == "\\" || $0 == "/" }).dropLast().joined(separator: "/")
        }
        return groups.map { FolderGroup(id: $0.key, files: $0.value.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }) }
            .sorted { $0.files.count > $1.files.count }
            .prefix(100)
            .map { $0 }
    }

    private static func qualityScore(_ result: SlskSearchResult) -> Double {
        let lossless: Set<String> = ["flac", "alac", "wav", "aif", "aiff", "ape", "wv"]
        if lossless.contains(result.fileExtension) {
            return 10_000 + Double(result.bitDepth ?? 16) * 100 + Double(result.sampleRate ?? 44_100) / 1000
        }
        return Double(result.bitrate ?? 0)
    }
}

private struct ResultRow: View {
    @EnvironmentObject private var client: SoulseekClient
    let result: SlskSearchResult

    private var transfer: SlskTransfer? {
        client.transfers.first { $0.result.id == result.id }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(result.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let transfer, case .completed = transfer.state { DownloadedMark() }
                }
                Text(result.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(result.freeSlots ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(result.freeSlots ? "Free upload slot" : "Queued uploads")
                    Text(result.username).lineLimit(1)
                    Text("·")
                    Text(result.qualityText).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let transfer, transfer.state.isActive {
                    Text(transfer.statusText).font(.caption2).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
            Button { client.download(result, play: true) } label: {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download and play")
            Button { client.download(result, play: false) } label: {
                Image(systemName: "arrow.down.circle").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download")
        }
    }
}

/// "All" plus each quality that has results, with counts.
private struct QualityChips: View {
    @Binding var selection: SlskQuality?
    let counts: [SlskQuality: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", count: counts.values.reduce(0, +), on: selection == nil) { selection = nil }
                ForEach(SlskQuality.allCases) { quality in
                    if let count = counts[quality], count > 0 {
                        chip(quality.rawValue, count: count, on: selection == quality) {
                            selection = selection == quality ? nil : quality
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .animation(.snappy, value: selection)
    }

    private func chip(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                if count > 0 { Text("\(count)").font(.caption2).monospacedDigit().opacity(0.7) }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(on ? Color.brand.opacity(0.9) : Color.white.opacity(0.1), in: Capsule())
            .foregroundStyle(on ? .black : .primary)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// One shared album folder: name, sharer, quality, and Download All.
private struct FolderRow: View {
    @EnvironmentObject private var client: SoulseekClient
    let files: [SlskSearchResult]
    @State private var expanded = false

    private var first: SlskSearchResult { files[0] }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(files) { ResultRow(result: $0) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(first.folder.isEmpty ? first.title : first.folder)
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Circle().fill(first.freeSlots ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(first.username).lineLimit(1)
                        Text("· \(files.count) files · \(SlskQuality.of(first).rawValue)")
                        Text("· " + ByteCountFormatter.string(fromByteCount: Int64(clamping: files.map(\.size).reduce(0, +)),
                                                             countStyle: .file))
                    }
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    for file in files { client.download(file, play: false) }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Image(systemName: "arrow.down.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download all \(files.count) files")
            }
        }
    }
}
