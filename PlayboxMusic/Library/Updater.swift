import Foundation
import SwiftUI

/// Checks this repo's GitHub releases for a newer build than the one
/// running, at most once a day on its own or whenever asked.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable, Identifiable {
        var id: String { version }
        var version: String
        var notes: String
        var ipaURL: URL
        var pageURL: URL
        var published: Date?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Set when an automatic check finds an update, to show the sheet once.
    @Published var prompt: Release?

    static let repo = "user445879785/playboxmusic"
    private let lastCheckKey = "update.lastCheck"
    private let skippedKey = "update.skipped"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func checkAutomatically() async {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        await check()
        if case .available(let release) = state,
           UserDefaults.standard.string(forKey: skippedKey) != release.version {
            prompt = release
        }
    }

    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=10")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                state = .failed("GitHub didn't answer. Try again later.")
                return
            }
            let releases = try JSONDecoder.github.decode([GitHubRelease].self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let newest = releases
                .compactMap { release -> Release? in
                    guard release.tag_name.hasPrefix("music-v"), !release.draft,
                          let asset = release.assets.first(where: { $0.name.hasSuffix(".ipa") }),
                          let page = URL(string: release.html_url) else { return nil }
                    return Release(version: String(release.tag_name.dropFirst("music-v".count)),
                                   notes: release.body ?? "", ipaURL: asset.browser_download_url,
                                   pageURL: page, published: release.published_at)
                }
                .max { Self.compare($0.version, $1.version) < 0 }
            if let newest, Self.compare(newest.version, currentVersion) > 0 {
                state = .available(newest)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: skippedKey)
        prompt = nil
    }

    /// Compares dotted versions numerically: 1.0.10 is newer than 1.0.9.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0
            let r = index < y.count ? y[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let published_at: Date?
    let assets: [Asset]
}

private extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Shows the new version and how to install it.
struct UpdateSheet: View {
    @EnvironmentObject private var updater: UpdateChecker
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let release: UpdateChecker.Release
    @State private var copied = false

    /// ipakill (LiveContainer) answers livecontainer:// links.
    private static let ipakillScheme = "livecontainer"

    private var hasIpakill: Bool {
        URL(string: "\(Self.ipakillScheme)://").map(UIApplication.shared.canOpenURL) ?? false
    }

    /// Hands the IPA's web address straight to ipakill, which downloads
    /// it and installs it. Going through Safari's Downloads first can give
    /// ipakill a file it doesn't recognise as an IPA ("Please provide an
    /// IPA file to install"). Falls back to Safari without ipakill.
    private func installWithIpakill() {
        var components = URLComponents()
        components.scheme = Self.ipakillScheme
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: release.ipaURL.absoluteString)]
        guard let link = components.url else {
            openURL(release.ipaURL)
            return
        }
        openURL(link) { accepted in
            if !accepted { openURL(release.ipaURL) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(release.version)")
                            .font(.title2.weight(.bold))
                            .tracking(-0.4)
                        Text("You have \(updater.currentVersion)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(hasIpakill
                     ? "ipakill downloads and installs the new version itself. Your music, stars and settings stay."
                     : "Download the new IPA, then install it the same way you installed this one. Your music, stars and settings stay.")
                    .font(.callout).foregroundStyle(.secondary)

                Button {
                    installWithIpakill()
                } label: {
                    Label(hasIpakill ? "Install with ipakill" : "Download IPA",
                          systemImage: hasIpakill ? "arrow.down.app.fill" : "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.black)
                }
                .buttonStyle(PressScaleStyle())

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.url = release.ipaURL
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { openURL(release.ipaURL) } label: {
                        Label("Safari", systemImage: "safari")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .buttonStyle(PressScaleStyle())
                .sensoryFeedback(.success, trigger: copied)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Update Available")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Skip This Version") {
                        updater.skip(release)
                        dismiss()
                    }
                    .font(.footnote)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.thinMaterial)
    }
}
