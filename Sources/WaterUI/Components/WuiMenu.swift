import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Menu component that displays a dropdown menu when tapped.
/// - iOS: Uses UIButton with UIMenu
/// - macOS: Uses NSPopUpButton
@MainActor
final class WuiMenu: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_menu_id() }

    private let labelView: any WuiComponent
    private let env: WuiEnvironment
    private let items: WuiComputed<CWaterUI.WuiArray_WuiMenuItem>
    private let semanticAccessibilityLabel: WuiComputed<WuiStyledStr>?
    private var itemsWatcher: WatcherGuard?
    private var semanticAccessibilityLabelWatcher: WatcherGuard?

    #if canImport(UIKit)
    private let button = UIButton(type: .system)
    #elseif canImport(AppKit)
    private let button = NSPopUpButton(frame: .zero, pullsDown: true)
    #endif

    var stretchAxis: WuiStretchAxis { .none }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let menu = waterui_force_as_menu(anyview)

        self.env = env
        guard let itemsPtr = menu.items else {
            fatalError("WuiMenu.items is null")
        }
        self.items = WuiComputed<CWaterUI.WuiArray_WuiMenuItem>(
            OpaquePointer(UnsafeMutableRawPointer(itemsPtr))
        )

        self.labelView = WuiAnyView.resolve(anyview: menu.label, env: env)
        self.semanticAccessibilityLabel = menu.accessibility_label.map {
            WuiComputed<WuiStyledStr>(OpaquePointer(UnsafeMutableRawPointer($0)))
        }

        super.init(frame: .zero)

        setupButton()
        configureSemanticAccessibility()
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSemanticAccessibility() {
        guard let semanticAccessibilityLabel else { return }
        applySemanticAccessibilityLabel(semanticAccessibilityLabel.value)
        semanticAccessibilityLabelWatcher = semanticAccessibilityLabel.watch { [weak self] value, _ in
            self?.applySemanticAccessibilityLabel(value)
        }
    }

    private func applySemanticAccessibilityLabel(_ styled: WuiStyledStr) {
        let text = styled.toString()
        #if canImport(UIKit)
        button.accessibilityLabel = text
        button.isAccessibilityElement = true
        #elseif canImport(AppKit)
        button.setAccessibilityLabel(text)
        button.toolTip = text
        #endif
    }

    private func setupButton() {
        #if canImport(UIKit)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        labelView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(labelView)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),

            labelView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
            labelView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            labelView.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
            labelView.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4)
        ])

        rebuildUIMenu(items.value)
        button.showsMenuAsPrimaryAction = true

        #elseif canImport(AppKit)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.pullsDown = true
        button.bezelStyle = .regularSquare
        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        rebuildMenu(items.value)
        #endif
    }

    #if canImport(UIKit)
    private func rebuildUIMenu(_ array: CWaterUI.WuiArray_WuiMenuItem) {
        let nodes = parseMenuNodes(from: array)
        button.menu = buildUIKitMenu(title: "", from: nodes) { [weak self] actionPtr in
            guard let self else { return }
            waterui_call_shared_action(actionPtr, self.env.inner)
        }
    }
    #endif

    #if canImport(AppKit)
    private func rebuildMenu(_ array: CWaterUI.WuiArray_WuiMenuItem) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: extractLabelText(), action: nil, keyEquivalent: ""))
        appendAppKitMenuItems(parseMenuNodes(from: array), to: menu, target: self, action: #selector(menuItemClicked(_:)))
        button.menu = menu
    }

    private func extractLabelText() -> String {
        if let textBase = labelView as? WuiTextBase {
            return textBase.textField.stringValue
        }
        return "Menu"
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuActionRef else {
            return
        }
        waterui_call_shared_action(action.actionPtr, env.inner)
    }
    #endif

    private func startWatching() {
        itemsWatcher = items.watch { [weak self] value, metadata in
            guard let self else { return }
            withPlatformAnimation(metadata) {
                #if canImport(UIKit)
                self.rebuildUIMenu(value)
                #elseif canImport(AppKit)
                self.rebuildMenu(value)
                #endif
            }
        }
    }

    func layoutPriority() -> Int32 { 0 }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 8

        var labelProposal = WuiProposalSize()
        if let proposedWidth = proposal.width {
            labelProposal.width = max(proposedWidth - Float(horizontalPadding), 0)
        }
        if let proposedHeight = proposal.height {
            labelProposal.height = max(proposedHeight - Float(verticalPadding), 0)
        }

        let labelSize = labelView.sizeThatFits(labelProposal)
        return CGSize(
            width: labelSize.width + horizontalPadding,
            height: labelSize.height + verticalPadding
        )
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
    }
    #endif
}
