import SwiftUI
import UIKit

/// App-wide look: the accent colour and the glass dock's transparency and
/// size, saved between launches. Same controls as SOMA's Setup › Dock.
final class Appearance: ObservableObject {
    static let shared = Appearance()

    static let swatches: [(name: String, hex: String)] = [
        ("Playbox", "#1FD661"), ("SOMA Lime", "#D3FD50"), ("Sky", "#4FB3FF"), ("Violet", "#A78BFA"),
        ("Pink", "#FF5FA2"), ("Coral", "#FF6B5A"), ("Amber", "#FFB020"), ("Mint", "#4BE3C1"),
        ("Red", "#FF453A"), ("White", "#F2F2F7")
    ]

    @Published var accentHex: String { didSet { UserDefaults.standard.set(accentHex, forKey: "appearance.accent") } }
    /// 0 = solid, 0.5 = standard glass, 1 = clearest glass.
    @Published var dockTransparency: Double { didSet { UserDefaults.standard.set(dockTransparency, forKey: "appearance.dockTransparency") } }
    /// 0.8 … 1.25.
    @Published var dockScale: Double { didSet { UserDefaults.standard.set(dockScale, forKey: "appearance.dockScale") } }

    private init() {
        let defaults = UserDefaults.standard
        accentHex = defaults.string(forKey: "appearance.accent") ?? "#1FD661"
        dockTransparency = defaults.object(forKey: "appearance.dockTransparency") as? Double ?? 0.5
        dockScale = defaults.object(forKey: "appearance.dockScale") as? Double ?? 1
    }

    var accentUIColor: UIColor { UIColor(somaHex: accentHex) }

    var accent: Color {
        get { Color(uiColor: accentUIColor) }
        set { accentHex = UIColor(newValue).hexString }
    }
}

extension UIColor {
    /// "#RRGGBB" to a colour; Playbox green if it can't be read.
    convenience init(somaHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&v) else {
            self.init(red: 0.12, green: 0.84, blue: 0.38, alpha: 1)
            return
        }
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = { (x: CGFloat) in Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// Settings › Appearance: accent swatches plus a custom picker, and the
/// dock's transparency and size with a live preview.
struct AppearanceSection: View {
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Appearance.swatches, id: \.hex) { swatch in
                        let selected = look.accentHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                        Button {
                            withAnimation(.snappy) { look.accentHex = swatch.hex }
                        } label: {
                            Circle()
                                .fill(Color(uiColor: UIColor(somaHex: swatch.hex)))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(.white, lineWidth: selected ? 3 : 0).padding(-4))
                                .shadow(color: Color(uiColor: UIColor(somaHex: swatch.hex)).opacity(0.45), radius: 8, y: 3)
                                .scaleEffect(selected ? 1.05 : 1)
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel(swatch.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .sensoryFeedback(.selection, trigger: look.accentHex)
            ColorPicker("Custom colour", selection: $look.accent, supportsOpacity: false)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Dock transparency")
                    Spacer()
                    Text(look.dockTransparency == 0.5 ? "Standard" : "\(Int((look.dockTransparency * 100).rounded()))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text("Solid").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $look.dockTransparency, in: 0...1, step: 0.05)
                    Text("Clear").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Dock size")
                    Spacer()
                    Text("\(Int((look.dockScale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text("S").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $look.dockScale, in: 0.8...1.25, step: 0.05)
                    Text("L").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Reset Appearance") {
                withAnimation(.snappy) {
                    look.accentHex = "#1FD661"
                    look.dockTransparency = 0.5
                    look.dockScale = 1
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("The dock is real Liquid Glass on iOS 26 and later; earlier versions use the system blur.")
        }
    }
}
