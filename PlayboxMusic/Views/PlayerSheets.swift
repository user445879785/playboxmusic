import SwiftUI

/// Ten-band equalizer with presets, Auto EQ and headphone correction.
struct EqualizerView: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        EqualizerForm(equalizer: player.equalizer, songTitle: player.current == nil ? nil : player.title)
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
    }
}

private struct EqualizerForm: View {
    @ObservedObject var equalizer: EqualizerSettings
    let songTitle: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Toggle("Equalizer", isOn: $equalizer.enabled)

                    Picker("Mode", selection: $equalizer.mode) {
                        ForEach(EqualizerSettings.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: equalizer.mode) { _, _ in equalizer.enabled = true }

                    headphonePicker

                    if let match = equalizer.savedMatch {
                        savedCard(match)
                    } else if equalizer.mode == .auto {
                        autoCard
                    } else {
                        presetPicker
                    }

                    bands
                        .disabled(!equalizer.enabled)
                        .opacity(equalizer.enabled ? 1 : 0.4)

                    if equalizer.enabled, equalizer.preamp < 0 {
                        Text(String(format: "Headroom %.1f dB so boosts never distort.", equalizer.preamp))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    rememberMenu
                        .disabled(!equalizer.enabled || songTitle == nil)
                }
                .padding()
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var headphonePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(HeadphoneProfile.allCases) { profile in
                    Button(profile.name) {
                        equalizer.headphone = profile
                        equalizer.enabled = true
                    }
                }
            } label: {
                HStack {
                    Text("Headphones")
                    Spacer()
                    Text(equalizer.headphone.name).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(equalizer.headphone.detail).font(.caption).foregroundStyle(.secondary)
            Toggle("Switch automatically when earbuds connect", isOn: $equalizer.autoDetectHeadphones)
                .font(.caption)
                .tint(.brand)
        }
    }

    /// Saves what you hear now for the song, its album or its genre.
    private var rememberMenu: some View {
        Menu {
            ForEach(EqualizerSettings.Scope.allCases) { scope in
                Button(scope.rawValue) { equalizer.remember(scope) }
                    .disabled(!equalizer.canRemember(scope))
            }
        } label: {
            Label("Remember This Sound For…", systemImage: "bookmark")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func savedCard(_ match: EqualizerSettings.SavedMatch) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill").foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remembered for \(match.scope.rawValue.lowercased())").font(.subheadline.weight(.semibold))
                Text("Your saved sound beats Auto and Manual here. Drag bands to adjust it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Forget") { withAnimation(.snappy) { equalizer.forgetSaved() } }
                .font(.subheadline)
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var presetPicker: some View {
        Menu {
            ForEach(EqualizerSettings.presets.map { $0.0 }, id: \.self) { name in
                Button(name) { equalizer.apply(preset: name) }
            }
        } label: {
            HStack {
                Text("Preset")
                Spacer()
                Text(equalizer.presetName).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var autoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "wand.and.stars")
                Text("Auto EQ").font(.headline)
                Spacer()
                if let result = equalizer.autoResult {
                    Text(result.genre == .unknown ? "Genre unknown" : result.genre.name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
            if let songTitle { Text(songTitle).font(.subheadline).lineLimit(1) }
            if let result = equalizer.autoResult {
                Text(result.summary).font(.caption).monospacedDigit()
                Text(result.measured
                     ? "Tuned from this song's measured sound and its genre."
                     : "Tuned from the genre only; the sound is still being measured.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(songTitle == nil ? "Play a song to tune it." : "Measuring this song…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Strength").font(.caption)
                Slider(value: $equalizer.autoIntensity, in: 0...1.5)
                Text("\(Int((equalizer.autoIntensity * 100).rounded()))%")
                    .font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Manual mode edits the curve; Auto mode shows what it chose.
    private var bands: some View {
        let curve = equalizer.activeCurve
        let editable = equalizer.mode == .manual || equalizer.savedMatch != nil
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<10, id: \.self) { band in
                VStack(spacing: 6) {
                    Text(String(format: "%+.0f", curve[band]))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(curve[band]) },
                        set: { equalizer.setBand(band, Float($0)) }
                    ), in: -12...12)
                    .tint(editable ? Color.brand : .white.opacity(0.6))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 170, height: 28)
                    .frame(width: 30, height: 170)
                    .accessibilityLabel("\(label(EqualizerSettings.frequencies[band])) band")
                    Text(label(EqualizerSettings.frequencies[band]))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func label(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}

/// Finds the catalog album for the playing song and shows its page.
struct AlbumLookupView: View {
    let meta: TrackMeta?
    let fallbackTitle: String
    @State private var album: ITunesItem?
    @State private var searched = false

    var body: some View {
        NavigationStack {
            Group {
                if let album {
                    AlbumDetailView(album: album)
                } else if searched {
                    ContentUnavailableView("Album Not Found", systemImage: "square.stack",
                                           description: Text("No catalog album matched this song."))
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: ITunesItem.self) { item in
                if item.wrapperType == "artist" { ArtistView(artist: item) } else { AlbumDetailView(album: item) }
            }
        }
        .task {
            let term = [meta?.artist, meta?.album ?? meta?.title ?? MusicText.clean(fallbackTitle)]
                .compactMap { $0 }.joined(separator: " ")
            album = try? await ITunesCatalog.search(term, entity: "album", limit: 1).first
            searched = true
        }
    }
}
