import Combine
import SwiftUI

/// The app's frame: four pages and the glass dock. It holds the client,
/// library and player as plain references on purpose: watching them here
/// would rebuild every page each time a download ticks or a song changes.
struct MusicContentView: View {
    let client: SoulseekClient
    let library: MusicLibrary
    let player: MusicPlayer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("playbox.music.username") private var username = ""
    @StateObject private var updater = UpdateChecker()

    @AppStorage(Appearance.accentKey) private var accentHex = Appearance.defaultAccent
    @AppStorage(Appearance.transparencyKey) private var dockTransparency = 0.5
    @AppStorage(Appearance.scaleKey) private var dockScale = 1.0
    @State private var tab = "search"

    var body: some View {
        let dockHeight = GlassDock.baseHeight * dockScale
        let safeBottom = Self.deviceBottomInset
        let bottom = max(safeBottom - 8, 10)
        // Apple's TabView switches the pages and keeps each one's place;
        // its own bar is hidden so only the glass dock shows. (Stacking the
        // pages and fading them didn't switch on iOS 26.)
        // Each page keeps clear of the dock, with the mini player just above it.
        let clearance = max(0, dockHeight + bottom - safeBottom + 6)
        // A new accent repaints the music pages. Settings is left alone: it
        // reads the colour live, so the picker isn't torn down mid-drag.
        TabView(selection: $tab) {
            NavigationStack { MusicSearchView() }.withMiniPlayer()
                .dockClearance(clearance).id(accentHex).tag("search")
            NavigationStack { DownloadsView() }.withMiniPlayer()
                .dockClearance(clearance).id(accentHex).tag("downloads")
            NavigationStack { MusicLibraryView() }.withMiniPlayer()
                .dockClearance(clearance).id(accentHex).tag("library")
            NavigationStack { MusicAccountView() }
                .dockClearance(clearance).tag("settings")
        }
        .overlay(alignment: .bottom) {
            DockLayer(selection: $tab, accent: Color(uiColor: UIColor(somaHex: accentHex)),
                      transparency: dockTransparency, scale: dockScale)
                .frame(height: dockHeight)
                .padding(.horizontal, 14)
                .padding(.bottom, bottom)
                .frame(maxHeight: .infinity, alignment: .bottom)
                // Sits on the screen's edge and stays put (behind) when the keyboard opens.
                .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
        .tint(.brand)
        .environmentObject(updater)
        .sheet(item: $updater.prompt) { release in
            UpdateSheet(release: release).environmentObject(updater)
        }
        // "Open in Playbox Music" from Files, Safari downloads or AirDrop.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task { await library.importFiles([url]) }
        }
        .task { await updater.checkAutomatically() }
        .task {
            player.metaProvider = { [library] track in library.meta(for: track) }
            player.similarProvider = { [library] track, played in library.similar(to: track, excluding: played) }
            player.skipProvider = { [library] track in library.isSkipped(track) }
            player.playedProvider = { [library] track in library.recordPlay(track) }
            client.onDownloadFinished = { [library, player] url, play, meta in
                if let meta { library.setMeta(meta, for: url) }
                Task {
                    await library.refresh()
                    guard play else { return }
                    let tracks = library.tracks
                    if let start = tracks.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                        player.play(tracks, startAt: start)
                    } else {
                        player.play([library.track(for: url)], startAt: 0)
                    }
                }
            }
            await reconnectIfNeeded()
        }
        // Details read after a song started (tags, catalog) reach the player.
        .onReceive(library.$metadata.dropFirst().receive(on: DispatchQueue.main)) { _ in player.refreshMeta() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Sound and sockets don't survive a long suspension.
                player.sceneActive()
                client.sceneActive()
                Task { await reconnectIfNeeded() }
            } else if phase == .background {
                library.flush()
            }
        }
    }

    private static var deviceBottomInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom ?? 34
    }

    /// Sockets do not survive long suspensions; sign back in on return.
    private func reconnectIfNeeded() async {
        switch client.connectionState {
        case .connected, .connecting: return
        case .disconnected, .failed: break
        }
        guard !username.isEmpty, let password = CredentialStore.password(for: username) else { return }
        await client.connect(username: username, password: password)
    }
}

/// The dock with its Downloads badge. Only this small view watches the
/// number of running downloads.
private struct DockLayer: View {
    @EnvironmentObject private var badge: DownloadBadge
    @Binding var selection: String
    let accent: Color
    let transparency: Double
    let scale: Double

    var body: some View {
        GlassDock(tabs: [
            ChromeTab(id: "search", title: "Search", symbol: "magnifyingglass"),
            ChromeTab(id: "downloads", title: "Downloads", symbol: "arrow.down.circle", badge: badge.active),
            ChromeTab(id: "library", title: "Library", symbol: "music.note.list"),
            ChromeTab(id: "settings", title: "Settings", symbol: "gearshape")
        ], selection: $selection, accent: accent, transparency: transparency, scale: scale)
    }
}

extension View {
    /// Hands the Soulseek client on to a sheet, without making the view
    /// that presents it redraw on every download update.
    @ViewBuilder
    func soulseekObjects(_ client: SoulseekClient?) -> some View {
        if let client {
            environmentObject(client)
                .environmentObject(client.checks)
                .environmentObject(client.badge)
                .environment(\.soulseek, client)
        } else {
            self
        }
    }
}

/// Floating mini player tinted from the artwork: swipe for next/previous,
/// swipe up or tap to open, star, play and a progress line.
private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.soulseek) private var soulseek
    @State private var showNowPlaying = false
    @State private var dragOffset: CGFloat = 0
    @GestureState private var touching = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let track = player.current {
                    bar(track)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: player.current == nil)
            // Presented from here, not from the bar: the bar goes away when
            // the queue ends, and a sheet must not lose what it hangs on.
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(onSwipeClose: {
                    // The swipe already slid the page off screen; skip the system slide.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showNowPlaying = false }
                })
                    .environmentObject(player)
                    .environmentObject(library)
                    .soulseekObjects(soulseek)
            }
        }
    }

    private func bar(_ track: Track) -> some View {
        let liked = library.isFavourite(track)
        let edge: Edge = player.skipDirection >= 0 ? .trailing : .leading
        return HStack(spacing: 10) {
            Group {
                if let artwork = player.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.16))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(player.isPlaying ? 1 : 0.9)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if player.isMixing {
                        Image(systemName: "sparkles").foregroundStyle(Color.brand)
                    }
                    Text(player.isMixing ? "Mixing into next song" : player.subtitle).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            }
            .id(player.current)
            .transition(.push(from: edge))
            .offset(x: dragOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Button {
                library.setFavourite(track, !liked)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: liked ? "star.fill" : "star")
                    .foregroundStyle(liked ? Color.brand : .white.opacity(0.85))
                    .frame(width: 38, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(liked ? "Unstar" : "Star")
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 38, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: {
                Image(systemName: "forward.fill").frame(width: 34, height: 44)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Next track")
        }
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .background {
            ZStack {
                player.artworkColor ?? Color(white: 0.18)
                Color.black.opacity(0.28)
            }
            .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
        }
        .overlay(alignment: .bottom) {
            MiniProgressLine(clock: player.clock).padding(.horizontal, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.35), value: player.current)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: player.isPlaying)
        .contentShape(Rectangle())
        .onTapGesture { showNowPlaying = true }
        .gesture(
            DragGesture(minimumDistance: 12)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    // Where the flick is heading decides, so a short fast
                    // swipe counts as much as a long slow one.
                    let sideways = abs(value.translation.width) > abs(value.translation.height)
                    let across = value.translation.width + Fluid.project(value.velocity.width, deceleration: 0.99)
                    let up = value.translation.height + Fluid.project(value.velocity.height, deceleration: 0.99)
                    withAnimation(.interpolatingSpring(duration: 0.3, bounce: 0.1,
                                                       initialVelocity: Fluid.relative(value.velocity.width, from: dragOffset, to: 0))) {
                        dragOffset = 0
                    }
                    if sideways {
                        if across < -90 { player.next() } else if across > 90 { player.previous() }
                    } else if up < -60 {
                        showNowPlaying = true
                    }
                }
        )
        .onDragCancelled(touching, stillBusy: { dragOffset != 0 }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Now Playing") { showNowPlaying = true }
    }
}

/// Only this line redraws as the song plays, every frame on ProMotion.
private struct MiniProgressLine: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        TimelineView(.animation(paused: !clock.running)) { context in
            let progress = clock.duration > 0 ? min(1, clock.elapsed(at: context.date) / clock.duration) : 0
            // Stretched, not re-laid-out: the cheapest way to move a line every frame.
            Rectangle().fill(.white.opacity(0.9))
                .scaleEffect(x: progress, y: 1, anchor: .leading)
        }
        .frame(height: 2)
        .clipShape(Capsule())
    }
}

extension View {
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
}

private extension View {
    /// Room for the glass dock under a page, and hides the system tab bar.
    func dockClearance(_ height: CGFloat) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: height) }
            .toolbar(.hidden, for: .tabBar)
    }
}
