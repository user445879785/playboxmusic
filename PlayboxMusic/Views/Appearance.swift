import SwiftUI
import UIKit

/// App-wide look: the accent colour and the glass dock's transparency and
/// size, saved between launches. Same controls as SOMA's Setup › Dock.
final class Appearance {
    static let shared = Appearance()

    static let swatches: [(name: String, hex: String)] = [
        ("Playbox", "#1FD661"), ("SOMA Lime", "#D3FD50"), ("Sky", "#4FB3FF"), ("Violet", "#A78BFA"),
        ("Pink", "#FF5FA2"), ("Apple Music", "#FA2D48"), ("Amber", "#FFB020"), ("Mint", "#4BE3C1"),
        ("Coral", "#FF6B5A"), ("White", "#F2F2F7")
    ]

    static let accentKey = "appearance.accent"
    static let transparencyKey = "appearance.dockTransparency"
    static let scaleKey = "appearance.dockScale"
    static let defaultAccent = "#1FD661"

    /// Read live from settings every time, so nothing can hold a stale colour.
    var accentHex: String { UserDefaults.standard.string(forKey: Self.accentKey) ?? Self.defaultAccent }
    var accentUIColor: UIColor { UIColor(somaHex: accentHex) }
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
/// dock's transparency and size. Stored with @AppStorage, which the dock
/// and every screen read directly, so changes apply immediately.
struct AppearanceSection: View {
    @AppStorage(Appearance.accentKey) private var accentHex = Appearance.defaultAccent
    @AppStorage(Appearance.transparencyKey) private var dockTransparency = 0.5
    @AppStorage(Appearance.scaleKey) private var dockScale = 1.0

    private var accent: Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(somaHex: accentHex)) },
                set: { accentHex = UIColor($0).hexString })
    }

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Appearance.swatches, id: \.hex) { swatch in
                        let selected = accentHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                        let colour = Color(uiColor: UIColor(somaHex: swatch.hex))
                        Button {
                            accentHex = swatch.hex
                        } label: {
                            Circle()
                                .fill(colour)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(.white, lineWidth: selected ? 3 : 0).padding(-4))
                                .shadow(color: colour.opacity(0.45), radius: 8, y: 3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(swatch.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .sensoryFeedback(.selection, trigger: accentHex)
            ColorPicker("Custom colour", selection: accent, supportsOpacity: false)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Dock transparency")
                    Spacer()
                    Text(abs(dockTransparency - 0.5) < 0.01 ? "Standard" : "\(Int((dockTransparency * 100).rounded()))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text("Solid").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $dockTransparency, in: 0...1, step: 0.05)
                    Text("Clear").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Dock size")
                    Spacer()
                    Text("\(Int((dockScale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text("S").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $dockScale, in: 0.8...1.25, step: 0.05)
                    Text("L").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Reset Appearance") {
                accentHex = Appearance.defaultAccent
                dockTransparency = 0.5
                dockScale = 1
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("The dock is real Liquid Glass on iOS 26 and later.")
        }
    }
}
