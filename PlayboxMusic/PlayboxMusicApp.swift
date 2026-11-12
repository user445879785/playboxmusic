import SwiftUI

@main
struct PlayboxMusicApp: App {
    @StateObject private var client = SoulseekClient()
    @StateObject private var library = MusicLibrary()
    @StateObject private var player = MusicPlayer()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CrashLog.install()
    }

    var body: some Scene {
        WindowGroup {
            MusicContentView()
                .environmentObject(client)
                .environmentObject(client.checks)
                .environment(\.soulseek, client)
                .environmentObject(library)
                .environmentObject(player)
        }
        .onChange(of: scenePhase) { _, phase in CrashLog.phase(phase) }
    }
}
