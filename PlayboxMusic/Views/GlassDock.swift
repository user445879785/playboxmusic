import SwiftUI

// ==========================================================================
// The tab dock, after SOMA's (kite-bay-otter-topaz NativeChrome.swift): one
// capsule of Liquid Glass holding every tab, and a glass bubble under the
// selected tab that springs between them (0.45 s, damping 0.72, like SOMA).
// Built in SwiftUI so taps drive the pages directly, every tab gets an equal
// share of the width, and the bubble fills its tab exactly.
// Real Liquid Glass (.glassEffect) on iOS 26+, a material blur before.
// Transparency and size come from Settings › Appearance.
// ==========================================================================

struct ChromeTab: Equatable {
    let id: String
    let title: String
    let symbol: String
    var badge: Int = 0
}

struct GlassDock: View {
    static let baseHeight: CGFloat = 64

    let tabs: [ChromeTab]
    @Binding var selection: String
    let accent: Color
    /// 0 = solid, 0.5 = standard glass, 1 = clearest glass.
    let transparency: Double
    /// 0.8 … 1.25.
    let scale: Double

    @Namespace private var bubble
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var inset: CGFloat { 6 * scale }

    var body: some View {
        HStack(spacing: 2 * scale) {
            ForEach(tabs, id: \.id) { tab in
                Button { select(tab.id) } label: { cell(tab) }
                    .buttonStyle(DockPressStyle())
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(tab.badge > 0 ? "\(tab.badge) active" : "")
                    .accessibilityAddTraits(selection == tab.id ? .isSelected : [])
            }
        }
        .padding(inset)
        .frame(height: Self.baseHeight * scale)
        .background { capsule }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func select(_ id: String) {
        guard id != selection else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.78)) {
            selection = id
        }
    }

    private func cell(_ tab: ChromeTab) -> some View {
        let selected = selection == tab.id
        return VStack(spacing: 3 * scale) {
            Image(systemName: tab.symbol)
                .font(.system(size: 19 * scale, weight: .semibold))
                .frame(height: 22 * scale)
                .overlay(alignment: .topTrailing) {
                    if tab.badge > 0 {
                        Text(tab.badge > 99 ? "99+" : "\(tab.badge)")
                            .font(.system(size: 10 * scale, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4 * scale)
                            .frame(minWidth: 16 * scale, minHeight: 16 * scale)
                            .background(.red, in: Capsule())
                            .offset(x: 10 * scale, y: -6 * scale)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(tab.title)
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(selected ? accent : .primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if selected {
                pill.matchedGeometryEffect(id: "bubble", in: bubble)
            }
        }
        .contentShape(Capsule())
        .animation(.snappy, value: tab.badge)
    }

    /// The bubble under the selected tab: interactive, accent-tinted glass.
    @ViewBuilder
    private var pill: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !reduceTransparency {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(accent.opacity(0.22)).interactive(), in: .capsule)
        } else {
            fallbackPill
        }
        #else
        fallbackPill
        #endif
    }

    private var fallbackPill: some View {
        Capsule()
            .fill(accent.opacity(0.18))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    /// The dock's glass. Below the middle it fills in towards solid; above
    /// 75 % the clear glass style takes over, as in SOMA.
    @ViewBuilder
    private var capsule: some View {
        // Every step of the slider changes the look: a dark wash from fully
        // solid (0) to none (75 %+), where the clearer glass takes over.
        let solid = reduceTransparency ? 1 : min(1, max(0, 0.75 - transparency) / 0.75)
        ZStack {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), !reduceTransparency {
                Capsule()
                    .fill(.clear)
                    .glassEffect(transparency > 0.75 ? .clear : .regular, in: .capsule)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
            #else
            Capsule().fill(.ultraThinMaterial)
            #endif
            Capsule().fill(Color.black.opacity(solid * 0.92))
        }
    }
}

/// Tabs shrink slightly while pressed, like SOMA's.
private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}
