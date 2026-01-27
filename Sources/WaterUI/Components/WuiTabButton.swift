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
    var onTap: (() -> Void)?

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    init(labelView: WuiAnyView) {
        self.labelView = labelView
        super.init(frame: .zero)

        isAccessibilityElement = true
        accessibilityTraits = .button

        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        labelView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(labelView)

        layer.cornerRadius = 10
        layer.masksToBounds = true

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

    private func updateAppearance() {
        backgroundColor = isSelected ? UIColor.secondarySystemBackground : UIColor.clear
    }
}
#elseif canImport(AppKit)
@MainActor
final class WuiTabButton: NSView {
    private let labelView: WuiAnyView
    private let clickRecognizer: NSClickGestureRecognizer

    var onClick: (() -> Void)?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    init(labelView: WuiAnyView) {
        self.labelView = labelView
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

    private func updateAppearance() {
        let color = isSelected ? NSColor.selectedControlColor.withAlphaComponent(0.15) : NSColor.clear
        layer?.backgroundColor = color.cgColor
    }
}
#endif
