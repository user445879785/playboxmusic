import Foundation
import SwiftUI
import UIKit

/// Records why the app last closed, so a crash can be copied from Settings:
/// - a crash (Swift error, Objective-C exception, bad memory access) saves
///   its call stack to crash.txt as it happens;
/// - a session that ends without either a crash or going to the background
///   first means iOS stopped the app while it was frozen (a "hang").
enum CrashLog {
    private static let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(".diagnostics", isDirectory: true)
    private static let file = folder.appendingPathComponent("crash.txt")
    private static var path = ""
    private static let liveKey = "diagnostics.sessionLive"
    private static let backgroundKey = "diagnostics.inBackground"

    /// Call once at launch.
    static func install() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = file.path
        let defaults = UserDefaults.standard
        // The last run was killed while active and left no crash report: a hang.
        if defaults.bool(forKey: liveKey), !defaults.bool(forKey: backgroundKey),
           !FileManager.default.fileExists(atPath: path) {
            let note = "\(Date()): the app was stopped by iOS while it was on screen (frozen or out of memory). No call stack is available.\n"
            try? note.write(to: file, atomically: true, encoding: .utf8)
        }
        defaults.set(true, forKey: liveKey)
        defaults.set(false, forKey: backgroundKey)

        NSSetUncaughtExceptionHandler { exception in
            CrashLog.write("Exception: \(exception.name.rawValue): \(exception.reason ?? "")",
                           stack: exception.callStackSymbols)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { number in
                CrashLog.write("Signal \(number)", stack: Thread.callStackSymbols)
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    /// Scene phase: going to the background is a normal place to be stopped.
    static func phase(_ phase: ScenePhase) {
        UserDefaults.standard.set(phase == .background, forKey: backgroundKey)
    }

    private static func write(_ reason: String, stack: [String]) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let text = "Playbox Music \(version), iOS \(UIDevice.current.systemVersion), \(Date())\n\(reason)\n"
            + stack.joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: text.data(using: .utf8))
        UserDefaults.standard.set(false, forKey: liveKey)
    }

    static var lastReport: String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// Settings › Diagnostics: the last crash report, ready to copy.
struct DiagnosticsSection: View {
    @State private var report = CrashLog.lastReport
    @State private var copied = false

    var body: some View {
        if let report {
            Section {
                Text(report.split(separator: "\n").prefix(12).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                Button(copied ? "Copied" : "Copy Crash Report") {
                    UIPasteboard.general.string = report
                    copied = true
                }
                Button("Clear", role: .destructive) {
                    CrashLog.clear()
                    self.report = nil
                }
            } header: {
                Text("Last Crash")
            } footer: {
                Text("Paste this to whoever is fixing the app.")
            }
        }
    }
}
