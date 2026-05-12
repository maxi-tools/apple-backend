import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
@MainActor
final class WuiTabButton: UIControl {
    private let labelView: WuiAnyView
    private let env: WuiEnvironment
    private var selectedColorWatcher: WatcherGuard?
    private var resolvedSelectedColor: UIColor = .secondarySystemBackground
    var onTap: (() -> Void)?

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    init(labelView: WuiAnyView, env: WuiEnvironment) {
        self.labelView = labelView
        self.env = env
        super.init(frame: .zero)

        isAccessibilityElement = true
        accessibilityTraits = .button

        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        labelView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(labelView)

        layer.cornerRadius = 10
        layer.masksToBounds = true

        installSelectedColorWatcher()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 8
        labelView.frame = bounds.insetBy(dx: inset, dy: 6)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize(width: Float(size.width), height: Float(size.height)))
        return CGSize(width: labelSize.width + 16, height: max(labelSize.height + 12, 36))
    }

    private func installSelectedColorWatcher() {
        // Theme-driven selected background: pick the `Surface` slot
        // (elevated card / sheet color) so it reads as a chip on top of
        // the page background regardless of the active color scheme.
        guard let computedPtr = waterui_theme_color(env.inner, WuiColorSlot_Surface) else {
            return
        }
        let signal = WuiComputed<WuiResolvedColor>(computedPtr)
        resolvedSelectedColor = signal.value.toUIColor()
        selectedColorWatcher = signal.watch { [weak self] color, _ in
            guard let self else { return }
            self.resolvedSelectedColor = color.toUIColor()
            self.updateAppearance()
        }
    }

    private func updateAppearance() {
        backgroundColor = isSelected ? resolvedSelectedColor : UIColor.clear
    }
}
#elseif canImport(AppKit)
@MainActor
final class WuiTabButton: NSView {
    private let labelView: WuiAnyView
    private let env: WuiEnvironment
    private let clickRecognizer: NSClickGestureRecognizer
    private var selectedColorWatcher: WatcherGuard?
    private var resolvedSelectedColor: NSColor = NSColor.selectedControlColor.withAlphaComponent(0.15)

    var onClick: (() -> Void)?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    init(labelView: WuiAnyView, env: WuiEnvironment) {
        self.labelView = labelView
        self.env = env
        self.clickRecognizer = NSClickGestureRecognizer()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        clickRecognizer.target = self
        clickRecognizer.action = #selector(clicked)
        addGestureRecognizer(clickRecognizer)

        labelView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(labelView)

        installSelectedColorWatcher()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func clicked() {
        onClick?()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        labelView.frame = bounds.insetBy(dx: inset, dy: 6)
    }

    func sizeThatFits(_ size: NSSize) -> NSSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize(width: Float(size.width), height: Float(size.height)))
        return NSSize(width: labelSize.width + 16, height: max(labelSize.height + 12, 28))
    }

    private func installSelectedColorWatcher() {
        guard let computedPtr = waterui_theme_color(env.inner, WuiColorSlot_Surface) else {
            return
        }
        let signal = WuiComputed<WuiResolvedColor>(computedPtr)
        resolvedSelectedColor = signal.value.toNSColor()
        selectedColorWatcher = signal.watch { [weak self] color, _ in
            guard let self else { return }
            self.resolvedSelectedColor = color.toNSColor()
            self.updateAppearance()
        }
    }

    private func updateAppearance() {
        let color = isSelected ? resolvedSelectedColor : NSColor.clear
        layer?.backgroundColor = color.cgColor
    }
}
#endif
