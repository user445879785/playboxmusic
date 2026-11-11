import SwiftUI
import UIKit

// ==========================================================================
// The tab dock from SOMA (kite-bay-otter-topaz, ios/App/App/NativeChrome.swift),
// ported unchanged in look and motion: every tab in one capsule of Apple's
// own glass material (UIGlassEffect, real Liquid Glass, when built with the
// iOS 26 SDK and running on iOS 26+; the system chrome blur otherwise), with
// an interactive glass pill under the selected tab that springs between
// them. Transparency and size come from Settings › Appearance.
// Additions for Playbox: SF Symbol icons and a count badge (Downloads).
// ==========================================================================

/// The glass material: Liquid Glass on iOS 26+, the system chrome blur otherwise.
func makeGlass(interactive: Bool = false, tint: UIColor? = nil, clear: Bool = false) -> UIVisualEffectView {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
        let g = UIGlassEffect(style: clear ? .clear : .regular)
        g.isInteractive = interactive
        g.tintColor = tint
        return UIVisualEffectView(effect: g)
    }
    #endif
    let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    if let tint {
        v.contentView.backgroundColor = tint
    }
    return v
}

struct ChromeTab: Equatable {
    let id: String
    let title: String
    let symbol: String
    var badge: Int = 0
}

/// Every tab in one scrolling glass capsule, with a glass pill under the
/// selected one that springs between them.
final class ChromeDock: UIView {
    var onSelect: ((String) -> Void)?

    private var glass = makeGlass()
    /// A wash over the glass that makes it more solid as transparency drops.
    private let shade = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var pill = makeGlass(interactive: true)
    private var buttons: [String: DockButton] = [:]
    private(set) var selected = ""
    private var accent = UIColor(somaHex: "#1FD661")
    private(set) var tabs: [ChromeTab] = []
    private(set) var scale: CGFloat = 1
    private var transparency: CGFloat = 0.5
    private var clearStyle = false

    static let baseHeight: CGFloat = 64

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 8)

        installGlass()

        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.alwaysBounceVertical = false
        scroll.isDirectionalLockEnabled = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.clipsToBounds = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(scroll)

        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.isUserInteractionEnabled = false
        scroll.addSubview(pill)

        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 2
        scroll.addSubview(stack)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The glass layer, rebuilt when the style switches between regular and
    /// clear (the effect's style cannot change in place).
    private func installGlass() {
        let old = glass
        let fresh = makeGlass(clear: clearStyle)
        fresh.frame = bounds
        fresh.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fresh.layer.cornerCurve = .continuous
        fresh.clipsToBounds = true
        shade.frame = fresh.contentView.bounds
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shade.isUserInteractionEnabled = false
        fresh.contentView.addSubview(shade)
        if scroll.superview != nil {
            fresh.contentView.addSubview(scroll)
        }
        insertSubview(fresh, at: 0)
        if old !== fresh && old.superview != nil { old.removeFromSuperview() }
        glass = fresh
        applyShade()
        setNeedsLayout()
    }

    private func applyShade() {
        // Below the middle the glass fills in towards solid; above it, the
        // clear style takes over.
        let solid = max(0, 0.5 - transparency) / 0.5
        shade.backgroundColor = UIColor.systemBackground.withAlphaComponent(solid * 0.9)
    }

    /// Transparency 0…1 and size 0.8…1.25, from Settings.
    func setStyle(transparency t: CGFloat, scale sc: CGFloat) {
        transparency = min(1, max(0, t))
        let wantClear = transparency > 0.75
        if wantClear != clearStyle {
            clearStyle = wantClear
            installGlass()
        } else {
            applyShade()
        }
        let newScale = min(1.25, max(0.8, sc))
        if abs(newScale - scale) > 0.001 {
            scale = newScale
            setTabs(tabs)
        }
    }

    func setTabs(_ tabs: [ChromeTab]) {
        // Only the badges changed: update in place, so the pill doesn't jump.
        if tabs.map(\.id) == self.tabs.map(\.id), tabs.map(\.title) == self.tabs.map(\.title), !buttons.isEmpty,
           buttons.values.first?.scale == scale {
            self.tabs = tabs
            for t in tabs { buttons[t.id]?.badge = t.badge }
            return
        }
        self.tabs = tabs
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = [:]
        for t in tabs {
            let b = DockButton(tab: t, scale: scale)
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(b)
            buttons[t.id] = b
        }
        setNeedsLayout()
        layoutIfNeeded()
        select(selected, animated: false)
    }

    func setAccent(_ c: UIColor) {
        guard c.hexString != accent.hexString || buttons.isEmpty else { return }
        accent = c
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect()
            g.isInteractive = true
            g.tintColor = c.withAlphaComponent(0.22)
            pill.effect = g
        }
        #endif
        if pill.effect is UIBlurEffect {
            pill.contentView.backgroundColor = c.withAlphaComponent(0.18)
        }
        refreshColors()
    }

    @objc private func tapped(_ b: DockButton) {
        guard b.tabId != selected else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        select(b.tabId, animated: true)
        onSelect?(b.tabId)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 6 * scale
        let h = bounds.height
        glass.layer.cornerRadius = h / 2
        pill.layer.cornerRadius = (h - inset * 2) / 2
        stack.layoutIfNeeded()
        let w = stack.systemLayoutSizeFitting(CGSize(width: UIView.layoutFittingCompressedSize.width, height: h - inset * 2)).width
        // Few tabs centre in the capsule; many scroll.
        let contentW = max(w + inset * 2, bounds.width)
        stack.frame = CGRect(x: (contentW - w) / 2, y: inset, width: w, height: h - inset * 2)
        scroll.contentSize = CGSize(width: contentW, height: h)
        scroll.contentInset = .zero
        if abs(scroll.contentOffset.y) > 0.5 {
            scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: 0)
        }
        placePill(animated: false)
    }

    func select(_ id: String, animated: Bool) {
        selected = id
        refreshColors()
        placePill(animated: animated)
        if let b = buttons[id] {
            let f = b.convert(b.bounds, to: scroll).insetBy(dx: -60, dy: 0)
            scroll.scrollRectToVisible(f, animated: animated)
        }
    }

    private func refreshColors() {
        for (id, b) in buttons {
            b.tintColor = id == selected ? accent : .label
        }
    }

    private func placePill(animated: Bool) {
        guard let b = buttons[selected] else {
            pill.alpha = 0
            return
        }
        let target = b.convert(b.bounds, to: scroll)
        let apply = {
            self.pill.alpha = 1
            self.pill.frame = target
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }
}

final class DockButton: UIControl {
    let tabId: String
    let scale: CGFloat
    private let icon = UIImageView()
    private let label = UILabel()
    private let badgeLabel = UILabel()

    var badge: Int = 0 {
        didSet {
            badgeLabel.text = badge > 99 ? "99+" : "\(badge)"
            badgeLabel.isHidden = badge == 0
            accessibilityValue = badge > 0 ? "\(badge) active" : nil
        }
    }

    init(tab: ChromeTab, scale: CGFloat) {
        tabId = tab.id
        self.scale = scale
        super.init(frame: .zero)
        accessibilityLabel = tab.title
        accessibilityTraits = .button
        isAccessibilityElement = true
        icon.image = UIImage(systemName: tab.symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))?
            .withRenderingMode(.alwaysTemplate)
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        label.text = tab.title
        label.font = UIFont.systemFont(ofSize: 10.5 * scale, weight: .semibold)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        let v = UIStackView(arrangedSubviews: [icon, label])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 3
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)

        badgeLabel.font = UIFont.systemFont(ofSize: 10 * scale, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = .systemRed
        badgeLabel.textAlignment = .center
        badgeLabel.layer.cornerRadius = 8 * scale
        badgeLabel.layer.masksToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22 * scale),
            icon.heightAnchor.constraint(equalToConstant: 22 * scale),
            v.centerXAnchor.constraint(equalTo: centerXAnchor),
            v.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 64 * scale),
            widthAnchor.constraint(greaterThanOrEqualTo: v.widthAnchor, constant: 16),
            badgeLabel.heightAnchor.constraint(equalToConstant: 16 * scale),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16 * scale),
            badgeLabel.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            badgeLabel.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: 2),
        ])
        badge = tab.badge
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        icon.tintColor = tintColor
        label.textColor = tintColor
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.18) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
            }
        }
    }
}

/// The dock in SwiftUI.
struct GlassDock: UIViewRepresentable {
    let tabs: [ChromeTab]
    @Binding var selection: String
    let accent: UIColor
    let transparency: Double
    let scale: Double

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> ChromeDock {
        let dock = ChromeDock()
        dock.onSelect = { id in context.coordinator.selection.wrappedValue = id }
        dock.setStyle(transparency: transparency, scale: scale)
        dock.setTabs(tabs)
        dock.setAccent(accent)
        dock.select(selection, animated: false)
        return dock
    }

    func updateUIView(_ dock: ChromeDock, context: Context) {
        context.coordinator.selection = $selection
        dock.setStyle(transparency: transparency, scale: scale)
        if dock.tabs != tabs { dock.setTabs(tabs) }
        dock.setAccent(accent)
        if dock.selected != selection { dock.select(selection, animated: true) }
    }

    final class Coordinator {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
    }
}
