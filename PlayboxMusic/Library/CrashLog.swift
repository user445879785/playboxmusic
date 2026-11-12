import Darwin
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
    // A crash handler may only do the simplest things: no memory, no locks.
    // So the file is opened and the first line prepared at launch, and the
    // handler only writes bytes to it. (It used to build strings and touch
    // settings, which could freeze the app instead of saving the report.)
    private static let liveFile = folder.appendingPathComponent("crash-live.txt")
    private static var liveFD: Int32 = -1
    private static var header: [UInt8] = []
    private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    private static var reported = false
    private static let backgroundKey = "diagnostics.inBackground"

    /// Call once at launch.
    static func install() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = file.path
        // A report the last run left behind becomes the one shown in Settings.
        if let size = try? FileManager.default.attributesOfItem(atPath: liveFile.path)[.size] as? UInt64, size > 0 {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: liveFile, to: file)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        header = Array("Playbox Music \(version), iOS \(UIDevice.current.systemVersion), started \(Date())\nSignal ".utf8)
        liveFD = open(liveFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
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
                let fd = CrashLog.liveFD
                if fd >= 0, !CrashLog.reported {
                    CrashLog.reported = true
                    CrashLog.header.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
                    var digits: (UInt8, UInt8, UInt8) = (48 + UInt8(number / 10 % 10), 48 + UInt8(number % 10), 10)
                    withUnsafeBytes(of: &digits) { _ = Darwin.write(fd, $0.baseAddress, 3) }
                    let count = backtrace(CrashLog.frames, 64)
                    backtrace_symbols_fd(CrashLog.frames, count, fd)
                }
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
        // The abort that follows an exception has nothing to add.
        reported = true
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
