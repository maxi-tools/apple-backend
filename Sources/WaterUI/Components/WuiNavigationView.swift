// WuiNavigationView.swift
// Navigation view component with navigation bar
//
// # Layout Behavior
// NavigationView stretches to fill available space (greedy).
// Contains a navigation bar and content area.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiNavigationView: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_navigation_view_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private var titleView: WuiAnyView
    private var contentView: WuiAnyView
    private let env: WuiEnvironment

    // Reactive watchers
    private var colorWatcher: WatcherGuard?
    private var hiddenWatcher: WatcherGuard?

    // Bar configuration
    private var barColor: WuiComputed<WuiResolvedColor>?
    private var barHidden: WuiComputed<Bool>?

    // Navigation support
    private var hasNavigationController: Bool = false

    #if canImport(UIKit)
    private let navBarView: UIView = UIView()
    #elseif canImport(AppKit)
    private let navBarView: NSView = NSView()
    private var backButton: NSButton?
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiNav: CWaterUI.WuiNavigationView = waterui_force_as_navigation_view(anyview)
        self.init(ffiNav: ffiNav, env: env)
    }

    /// Initialize from FFI struct directly (used by NavigationStack when pushing)
    convenience init(ffiNav: CWaterUI.WuiNavigationView, env: WuiEnvironment) {
        let contentView = WuiAnyView(anyview: ffiNav.content, env: env)
        let barState = makeNavigationBarState(from: ffiNav.bar, env: env)

        // Check if we're inside a navigation stack
        let hasNavController = waterui_env_has_navigation_controller(env.inner)

        self.init(
            content: contentView,
            barState: barState,
            env: env,
            hasNavigationController: hasNavController
        )
    }

    // MARK: - Designated Init

    init(
        content: WuiAnyView,
        barState: WuiNavigationBarState,
        env: WuiEnvironment,
        hasNavigationController: Bool
    ) {
        self.contentView = content
        self.env = env
        self.hasNavigationController = hasNavigationController
        self.titleView = barState.title.view

        super.init(frame: .zero)

        configureNavBar()
        configureContent()
        setupColorWatcher(barState.color)
        setupHiddenWatcher(barState.hidden)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureNavBar() {
        // When inside a NavigationStack, native navigation chrome handles the bar.
        // - iOS: UINavigationController provides native nav bar with back button and swipe gesture
        // - macOS: Window toolbar provides back button
        // Hide the custom nav bar entirely in both cases.
        if hasNavigationController {
            navBarView.isHidden = true
            return
        }

        navBarView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(navBarView)

        #if canImport(UIKit)
        navBarView.backgroundColor = .systemBackground
        #elseif canImport(AppKit)
        navBarView.wantsLayer = true
        navBarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Add back button if NOT inside navigation stack (standalone NavigationView)
        // When inside NavigationStack, the toolbar provides back button
        let button = NSButton(title: "< Back", target: self, action: #selector(backButtonTapped))
        button.bezelStyle = .inline
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(button)
        self.backButton = button
        #endif

        titleView.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(titleView)

        // Add bottom border
        #if canImport(UIKit)
        let border = UIView()
        border.backgroundColor = .separator
        border.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(border)
        #elseif canImport(AppKit)
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.separatorColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(border)
        #endif
    }

    @objc private func backButtonTapped() {
        waterui_navigation_pop(env.inner)
    }

    private func configureContent() {
        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
    }

    private func setupColorWatcher(_ color: WuiComputed<WuiResolvedColor>?) {
        guard let color else { return }
        self.barColor = color
        applyBarColor(color.value)
        colorWatcher = color.watch { [weak self] value, metadata in
            guard let self else { return }
            withPlatformAnimation(metadata) {
                self.applyBarColor(value)
            }
        }
    }

    private func setupHiddenWatcher(_ hidden: WuiComputed<Bool>?) {
        guard let hidden else { return }
        self.barHidden = hidden
        applyBarHidden(hidden.value)
        hiddenWatcher = hidden.watch { [weak self] value, _ in
            self?.applyBarHidden(value)
        }
    }

    private func applyBarColor(_ color: WuiResolvedColor) {
        #if canImport(UIKit)
        navBarView.backgroundColor = color.toUIColor()
        #elseif canImport(AppKit)
        navBarView.layer?.backgroundColor = color.toNSColor().cgColor
        #endif
    }

    private func applyBarHidden(_ hidden: Bool) {
        navBarView.isHidden = hidden
        #if canImport(UIKit)
        setNeedsLayout()
        layoutIfNeeded()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // NavigationView takes all available space
        let width = proposal.width.map { CGFloat($0) } ?? 320
        let height = proposal.height.map { CGFloat($0) } ?? 480
        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        performLayout()
    }
    #endif

    private func performLayout() {
        let barHeight = navBarView.isHidden ? 0 : measuredNavBarHeight()

        // Position nav bar at top
        navBarView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        #if canImport(AppKit)
            // Position back button on the left (macOS standalone NavigationView)
            if let backButton = backButton {
                let buttonSize = backButton.sizeThatFits(CGSize(width: 100, height: barHeight))
                backButton.frame = CGRect(
                    x: 12,
                    y: (barHeight - buttonSize.height) / 2,
                    width: buttonSize.width,
                    height: buttonSize.height
                )
            }
        #endif

        // Center title in nav bar
        let titleSize = titleView.sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: Float(barHeight)))
        titleView.frame = CGRect(
            x: (bounds.width - titleSize.width) / 2,
            y: (barHeight - titleSize.height) / 2,
            width: titleSize.width,
            height: titleSize.height
        )

        // Position border at bottom of nav bar
        #if canImport(AppKit)
            if let border = navBarView.subviews.last, border !== titleView && border !== backButton {
                border.frame = CGRect(x: 0, y: barHeight - 1, width: bounds.width, height: 1)
            }
        #else
            if let border = navBarView.subviews.last, border !== titleView {
                border.frame = CGRect(x: 0, y: barHeight - 1, width: bounds.width, height: 1)
            }
        #endif

        // Position content below nav bar
        let contentY = barHeight
        let contentHeight = bounds.height - barHeight
        contentView.frame = CGRect(x: 0, y: contentY, width: bounds.width, height: contentHeight)
    }

    private func measuredNavBarHeight() -> CGFloat {
        #if canImport(UIKit)
        let bar = UINavigationBar()
        let size = bar.sizeThatFits(CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height))
        return size.height
        #elseif canImport(AppKit)
        let titleSize = titleView.sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: nil))
        let backSize = backButton?.sizeThatFits(CGSize(width: bounds.width, height: bounds.height)) ?? .zero
        return max(titleSize.height, backSize.height)
        #endif
    }
}
