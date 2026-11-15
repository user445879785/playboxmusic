import SwiftUI

// MARK: - Store

/// Settings › Add-ons: a small store of optional services. Adding one
/// switches it on; its page says what it sends and where.
struct AddOnStoreView: View {
    @ObservedObject private var store = AddOnStore.shared
    @State private var opened: AddOn?

    /// The best-known free services of each kind, shown first.
    private let featured: [AddOn] = [.internetArchive, .smartSearch, .lrclib]

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(featured) { addOn in
                            Button { opened = addOn } label: { FeaturedCard(addOn: addOn) }
                                .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)
            }

            ForEach(AddOn.Kind.allCases) { kind in
                Section(kind.rawValue) {
                    if kind == .sources {
                        IncludedRow(name: "Soulseek", detail: "Peer-to-peer search and downloads", symbol: "arrow.down.circle.fill")
                    }
                    if kind == .search {
                        IncludedRow(name: "iTunes Catalogue", detail: "Browse albums, artists and charts", symbol: "music.note.house.fill")
                    }
                    ForEach(AddOn.allCases.filter { $0.kind == kind }) { addOn in
                        Button { opened = addOn } label: { AddOnRow(addOn: addOn) }
                            .buttonStyle(.plain)
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("Add-ons are part of the app and use free, public services with no account. Nothing about your library, stars or listening is ever sent.")
            }
        }
        .navigationTitle("Add-ons")
        .sheet(item: $opened) { AddOnDetail(addOn: $0) }
    }
}

/// Square tile with the add-on's symbol on an accent gradient.
private struct AddOnIcon: View {
    let symbol: String
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color.brand, Color.brand.opacity(0.45)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
    }
}

/// The App Store style "Get" / "Added" button.
private struct GetButton: View {
    @ObservedObject private var store = AddOnStore.shared
    let addOn: AddOn

    var body: some View {
        let on = store.isOn(addOn)
        Button {
            withAnimation(.snappy(duration: 0.2)) { store.set(addOn, !on) }
        } label: {
            Text(on ? "Added" : "Get")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? Color.secondary : Color.black)
                .frame(minWidth: 72, minHeight: 30)
                .background(on ? Color(white: 0.2) : Color.brand, in: Capsule())
                .contentTransition(.opacity)
        }
        .buttonStyle(PressScaleStyle())
        .sensoryFeedback(.success, trigger: on) { _, new in new }
        .accessibilityLabel(on ? "Remove \(addOn.name)" : "Get \(addOn.name)")
    }
}

private struct AddOnRow: View {
    let addOn: AddOn

    var body: some View {
        HStack(spacing: 14) {
            AddOnIcon(symbol: addOn.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(addOn.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(addOn.tagline).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            GetButton(addOn: addOn)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct IncludedRow: View {
    let name: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            AddOnIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("Included").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct FeaturedCard: View {
    let addOn: AddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(addOn.kind.rawValue.uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(Color.brand)
            Text(addOn.name).font(.title3.weight(.bold)).lineLimit(1)
            Text(addOn.tagline).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            HStack {
                AddOnIcon(symbol: addOn.symbol, size: 40)
                Spacer()
                GetButton(addOn: addOn)
            }
        }
        .padding(16)
        .frame(width: 260, height: 190, alignment: .leading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// One add-on's page: what it does and what it sends.
private struct AddOnDetail: View {
    let addOn: AddOn
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        AddOnIcon(symbol: addOn.symbol, size: 84)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(addOn.name).font(.title2.weight(.bold))
                            Text(addOn.maker).font(.subheadline).foregroundStyle(.secondary)
                            GetButton(addOn: addOn).padding(.top, 6)
                        }
                    }
                    Text(addOn.about).font(.body)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("What it sends", systemImage: "arrow.up.right.circle")
                            .font(.subheadline.weight(.semibold))
                        Text(addOn.sends).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Internet Archive

/// Archive results inside the Search tab.
struct ArchiveResultsSection: View {
    let query: String
    @State private var items: [InternetArchive.Item] = []
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Section {
            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                Text("Search millions of free recordings: live shows, netlabels, public domain and Creative Commons music.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if loading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if failed {
                Text("The Internet Archive didn't answer. Try again in a moment.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("Nothing found.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    NavigationLink(value: item) { ArchiveItemRow(item: item) }
                }
            }
        } header: {
            Text("Internet Archive")
        }
        // Searches a moment after you stop typing.
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2 else {
                items = []
                return
            }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            loading = true
            failed = false
            do {
                let found = try await InternetArchive.search(term)
                if !Task.isCancelled { items = found }
            } catch {
                if !Task.isCancelled { failed = true }
            }
            loading = false
        }
    }
}

private struct ArchiveItemRow: View {
    let item: InternetArchive.Item

    var body: some View {
        HStack(spacing: 12) {
            CatalogArtwork(url: item.artworkURL, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([item.creator, item.downloads > 0 ? "\(item.downloads.formatted(.number.notation(.compactName))) downloads" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// One archive item: its songs, in MP3 or FLAC, each with a download button.
struct ArchiveItemView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let item: InternetArchive.Item
    @State private var files: [InternetArchive.File] = []
    @State private var lossless = false
    @State private var loading = true
    @State private var states: [String: DownloadState] = [:]

    enum DownloadState: Equatable {
        case downloading
        case done(URL)
        case failed
    }

    /// One file per song in the chosen format, falling back to the other.
    private var songs: [InternetArchive.File] {
        let groups = Dictionary(grouping: files) { ($0.name as NSString).deletingPathExtension }
        return groups.values.compactMap { versions in
            versions.first { $0.isLossless == lossless } ?? versions.first
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let list = songs
        List {
            Section {
                HStack(spacing: 14) {
                    CatalogArtwork(url: item.artworkURL, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).lineLimit(3)
                        if let creator = item.creator {
                            Text(creator).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                if files.contains(where: \.isLossless) && files.contains(where: { !$0.isLossless }) {
                    Picker("Format", selection: $lossless) {
                        Text("MP3").tag(false)
                        Text("FLAC").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Button {
                    list.forEach(download)
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle.fill").font(.headline)
                }
                .disabled(list.isEmpty || list.allSatisfy { states[$0.id] != nil && states[$0.id] != .failed })
            }
            Section {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if list.isEmpty {
                    Text("This item has no songs to download.").foregroundStyle(.secondary)
                }
                ForEach(list) { file in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text([file.format, file.length.map(TrackFacts.format), file.size.map {
                                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                            }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        stateButton(file)
                    }
                }
            }
        }
        .navigationTitle("Internet Archive")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            files = (try? await InternetArchive.files(of: item)) ?? []
            loading = false
        }
    }

    @ViewBuilder
    private func stateButton(_ file: InternetArchive.File) -> some View {
        switch states[file.id] {
        case .downloading:
            ProgressView()
        case .done(let url):
            Button {
                player.play([library.track(for: url)], startAt: 0)
            } label: {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Color.brand)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")
        case .failed:
            Button { download(file) } label: {
                Image(systemName: "arrow.clockwise.circle").font(.title2).foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Try again")
        case nil:
            Button { download(file) } label: {
                Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(Color.brand)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download")
        }
    }

    private func download(_ file: InternetArchive.File) {
        guard states[file.id] == nil || states[file.id] == .failed else { return }
        states[file.id] = .downloading
        let root = library.root
        Task {
            do {
                let url = try await InternetArchive.download(file, of: item, into: root)
                states[file.id] = .done(url)
                await library.refresh()
            } catch {
                states[file.id] = .failed
            }
        }
    }
}
