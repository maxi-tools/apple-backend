// WuiNavigationStack.swift
// Navigation stack container component with full push/pop support
//
// # Layout Behavior
// NavigationStack stretches to fill available space (greedy).
// Manages a stack of navigation views with native platform navigation.
//
// # Architecture
// Creates a NavigationController (via FFI) that receives push/pop calls from Rust.
// On iOS, uses UINavigationController for native gestures (swipe-back).
// On macOS, uses a custom view stack with animations.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Content View Controller

#if canImport(UIKit)
/// A UIViewController that hosts WaterUI content with native navigation behavior.
///
/// Layout strategy (matches SwiftUI):
/// - If content contains a scroll view: edge-to-edge layout with automatic inset adjustment
///   This enables proper large title collapse animation and nav bar blur effect
/// - If content has no scroll view: safe area layout to avoid nav bar overlap
@MainActor
final class WuiContentViewController: UIViewController {
    private let contentView: UIView
    private let navigationTitle: WuiNavigationTitle?
    private let barColor: WuiComputed<WuiResolvedColor>?
    private let barHidden: WuiComputed<Bool>?
    private var colorWatcher: WatcherGuard?
    private var hiddenWatcher: WatcherGuard?

    init(contentView: UIView, barState: WuiNavigationBarState?) {
        self.contentView = contentView
        self.navigationTitle = barState?.title
        self.barColor = barState?.color
        self.barHidden = barState?.hidden
        super.init(nibName: nil, bundle: nil)

        // Extend layout under navigation bar and home indicator
        // This is crucial for large title smooth transition
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        contentView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(contentView)
        applyNavigationTitle()
        startWatching()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Force navigation bar layout refresh for large title
        navigationController?.navigationBar.sizeToFit()
        applyBarState(animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Edge-to-edge layout - ScrollView handles insets via contentInsetAdjustmentBehavior
        contentView.frame = view.bounds
    }

    private func applyNavigationTitle() {
        guard let navigationTitle else { return }
        if navigationTitle.isPlainText {
            navigationItem.title = navigationTitle.text ?? ""
            navigationItem.titleView = nil
        } else {
            navigationItem.title = navigationTitle.text
            navigationItem.titleView = navigationTitle.view
        }
    }

    private func startWatching() {
        if let barColor {
            applyBarColor(barColor.value)
            colorWatcher = barColor.watch { [weak self] value, metadata in
                guard let self else { return }
                withPlatformAnimation(metadata) {
                    self.applyBarColor(value)
                }
            }
        }

        if let barHidden {
            applyBarHidden(barHidden.value, animated: false)
            hiddenWatcher = barHidden.watch { [weak self] value, metadata in
                guard let self else { return }
                let animated = shouldAnimate(metadata.animation ?? .none)
                self.applyBarHidden(value, animated: animated)
            }
        }
    }

    private func applyBarState(animated: Bool) {
        if let barColor {
            applyBarColor(barColor.value)
        }
        if let barHidden {
            applyBarHidden(barHidden.value, animated: animated)
        }
    }

    private func applyBarColor(_ color: WuiResolvedColor) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = color.toUIColor()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
    }

    private func applyBarHidden(_ hidden: Bool, animated: Bool) {
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
    }
}
#endif

// MARK: - Navigation Controller Wrapper

/// Wrapper class that receives push/pop callbacks from Rust via FFI.
/// This is retained by the navigation controller and bridged via C callbacks.
@MainActor
final class NavigationControllerWrapper {
    weak var delegate: WuiNavigationStack?

    func push(_ navView: CWaterUI.WuiNavigationView) {
        delegate?.handlePush(navView)
    }

    func pop() {
        delegate?.handlePop()
    }
}

// MARK: - WuiNavigationStack

@MainActor
final class WuiNavigationStack: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_navigation_stack_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let childEnv: WuiEnvironment
    private let transition: WuiNavigationTransition
    private var wrapper: NavigationControllerWrapper?

    #if canImport(UIKit)
    private var navController: UINavigationController!
    private var viewStack: [UIViewController] = []
    #elseif canImport(AppKit)
    private struct NavigationEntry {
        let view: NSView
        let title: WuiNavigationTitle?
    }

    private var viewStack: [NavigationEntry] = []
    private var currentIndex: Int = 0
    private var titleAccessory: NSTitlebarAccessoryViewController?
    private var titleContainer: NSView?
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiStack: CWaterUI.WuiNavigationStack = waterui_force_as_navigation_stack(anyview)

        // Clone the environment to create a child environment
        guard let childEnvPtr = waterui_clone_env(env.inner) else {
            fatalError("Failed to clone environment")
        }
        let childEnv = WuiEnvironment(childEnvPtr)

        // Create the wrapper that will receive push/pop callbacks
        let wrapper = NavigationControllerWrapper()

        // Create FFI callbacks that bridge to the wrapper
        let wrapperPtr = Unmanaged.passRetained(wrapper).toOpaque()

        // Create and install the navigation controller
        // Note: Callbacks are called synchronously from the main thread (via Rust's nami runtime).
        // We must NOT use async Task here because the FFI struct pointers become invalid
        // after the callback returns.
        let controllerPtr = waterui_navigation_controller_new(
            wrapperPtr,
            { data, navView in
                guard let data = data else { return }
                let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeUnretainedValue()
                // Process synchronously - navView's pointers are only valid during this callback
                wrapper.push(navView)
            },
            { data in
                guard let data = data else { return }
                let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeUnretainedValue()
                wrapper.pop()
            },
            { data in
                guard let data = data else { return }
                // Release the retained wrapper
                _ = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeRetainedValue()
            }
        )

        // Install the controller into the child environment
        waterui_env_install_navigation_controller(childEnv.inner, controllerPtr)

        // Render root view with the child environment (which has NavigationController).
        // If the root is a NavigationView, the stack owns the chrome and unwraps it.
        let rootViewId = WuiViewId(waterui_view_id(ffiStack.root))
        let navigationViewId = WuiViewId(waterui_navigation_view_id())

        let rootView: WuiAnyView
        let rootBarState: WuiNavigationBarState?
        let rootDisplayMode: WuiNavigationTitleDisplayMode

        if rootViewId == navigationViewId {
            let rootNav = waterui_force_as_navigation_view(ffiStack.root)
            rootView = WuiAnyView(anyview: rootNav.content, env: childEnv)
            rootBarState = makeNavigationBarState(from: rootNav.bar, env: childEnv)
            rootDisplayMode = rootNav.bar.display_mode
        } else {
            rootView = WuiAnyView(anyview: ffiStack.root, env: childEnv)
            rootBarState = nil
            rootDisplayMode = WuiNavigationTitleDisplayMode_Automatic
        }

        self.init(
            rootView: rootView,
            rootBarState: rootBarState,
            rootDisplayMode: rootDisplayMode,
            transition: ffiStack.transition,
            childEnv: childEnv,
            wrapper: wrapper
        )
    }

    // MARK: - Designated Init

    init(
        rootView: WuiAnyView,
        rootBarState: WuiNavigationBarState?,
        rootDisplayMode: WuiNavigationTitleDisplayMode,
        transition: WuiNavigationTransition,
        childEnv: WuiEnvironment,
        wrapper: NavigationControllerWrapper
    ) {
        self.transition = transition
        self.childEnv = childEnv
        self.wrapper = wrapper
        super.init(frame: .zero)

        wrapper.delegate = self
        configureNavigation(with: rootView, barState: rootBarState, displayMode: rootDisplayMode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureNavigation(
        with rootView: WuiAnyView,
        barState: WuiNavigationBarState?,
        displayMode: WuiNavigationTitleDisplayMode
    ) {
        #if canImport(UIKit)
        // iOS: Use UINavigationController for native swipe-back gesture
        let rootVC = makeViewController(
            for: rootView,
            barState: barState,
            displayMode: convertDisplayMode(displayMode)
        )
        navController = UINavigationController(rootViewController: rootVC)
        // Enable large titles support (individual VCs control their display mode)
        navController.navigationBar.prefersLargeTitles = true
        navController.delegate = self
        navController.view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(navController.view)
        viewStack.append(rootVC)
        #elseif canImport(AppKit)
        // macOS: Custom view stack
        rootView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rootView)
        viewStack.append(NavigationEntry(view: rootView, title: barState?.title))
#endif
}

    // MARK: - Push/Pop Handlers

    func handlePush(_ navView: CWaterUI.WuiNavigationView) {
        let barState = makeNavigationBarState(from: navView.bar, env: childEnv)

        // Render the content view
        let contentView = WuiAnyView(anyview: navView.content, env: childEnv)

        #if canImport(UIKit)
        // Extract and convert display mode
        let displayMode = convertDisplayMode(navView.bar.display_mode)
        let vc = makeViewController(for: contentView, barState: barState, displayMode: displayMode)
        pushViewController(vc)
        viewStack.append(vc)
        #elseif canImport(AppKit)
        // For macOS, push content directly - toolbar handles navigation chrome
        pushView(contentView, title: barState.title)
        #endif
    }

    #if canImport(AppKit)
    private var backButton: NSButton?
    private var titlebarAccessory: NSTitlebarAccessoryViewController?

    private func setupTitlebar() {
        guard let window = self.window else { return }

        // Check if already set up
        if titlebarAccessory != nil { return }

        // Create back button with native macOS styling
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        button.bezelStyle = .accessoryBarAction  // Native accessory bar style
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(backButtonTapped)
        button.isHidden = true  // Hidden initially on root view
        self.backButton = button

        // Create accessory view controller for the button
        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.view = button
        accessoryVC.layoutAttribute = .leading  // Position on the left!

        window.addTitlebarAccessoryViewController(accessoryVC)
        self.titlebarAccessory = accessoryVC

        window.titleVisibility = .visible
        updateTitlebarState()
    }

    private func updateTitlebarState() {
        guard let window = self.window else { return }

        applyTitle(viewStack.last?.title, in: window)

        // Update back button visibility
        backButton?.isHidden = viewStack.count <= 1
    }

    @objc private func backButtonTapped() {
        waterui_navigation_pop(childEnv.inner)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupTitlebar()
        }
    }

    private func pushView(_ view: NSView, title: WuiNavigationTitle?) {
        // Hide current view
        if let currentView = viewStack.last?.view {
            currentView.isHidden = true
        }

        // Add new view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds
        view.alphaValue = (transition == WuiNavigationTransition_None) ? 1 : 0
        addSubview(view)
        viewStack.append(NavigationEntry(view: view, title: title))

        // Update titlebar state (window title, back button)
        updateTitlebarState()

        if transition == WuiNavigationTransition_None {
            view.alphaValue = 1
        } else {
            // Animate in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                view.animator().alphaValue = 1
            }
        }
    }

    private func popView() {
        guard viewStack.count > 1 else { return }

        let currentEntry = viewStack.removeLast()
        let currentView = currentEntry.view

        // Update titlebar state before animation
        updateTitlebarState()

        if transition == WuiNavigationTransition_None {
            currentView.removeFromSuperview()
        } else {
            // Animate out
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                currentView.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    currentView.removeFromSuperview()
                }
            })
        }

        // Show previous view
        if let previousView = viewStack.last?.view {
            previousView.isHidden = false
        }
    }

    private func applyTitle(_ title: WuiNavigationTitle?, in window: NSWindow) {
        guard let title else {
            window.titleVisibility = .visible
            window.title = ""
            removeTitleAccessory()
            return
        }

        if title.isPlainText {
            window.titleVisibility = .visible
            window.title = title.text ?? ""
            removeTitleAccessory()
        } else {
            window.titleVisibility = .hidden
            window.title = ""
            installTitleAccessory(title.view, in: window)
        }
    }

    private func installTitleAccessory(_ titleView: NSView, in window: NSWindow) {
        let accessory = ensureTitleAccessory(in: window)

        titleView.removeFromSuperview()
        titleView.translatesAutoresizingMaskIntoConstraints = true
        let fittingSize = titleView.fittingSize
        titleView.frame = NSRect(origin: .zero, size: fittingSize)
        accessory.view = titleView
        titleContainer = titleView
    }

    private func ensureTitleAccessory(in window: NSWindow) -> NSTitlebarAccessoryViewController {
        if let existing = titleAccessory {
            return existing
        }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .centerX
        window.addTitlebarAccessoryViewController(accessory)
        titleAccessory = accessory
        return accessory
    }

    private func removeTitleAccessory() {
        titleContainer?.removeFromSuperview()
        titleContainer = nil
        titleAccessory?.view = NSView(frame: .zero)
    }
    #endif

    func handlePop() {
        #if canImport(UIKit)
        guard viewStack.count > 1 else { return }
        popViewController()
        viewStack.removeLast()
        #elseif canImport(AppKit)
        popView()
        #endif
    }

    #if canImport(UIKit)
    private func pushViewController(_ vc: UIViewController) {
        switch transition {
        case WuiNavigationTransition_PushPop:
            navController.pushViewController(vc, animated: true)
        case WuiNavigationTransition_Fade:
            addFadeTransition(to: navController.view.layer)
            navController.pushViewController(vc, animated: false)
        case WuiNavigationTransition_None:
            navController.pushViewController(vc, animated: false)
        default:
            navController.pushViewController(vc, animated: true)
        }
    }

    private func popViewController() {
        switch transition {
        case WuiNavigationTransition_PushPop:
            navController.popViewController(animated: true)
        case WuiNavigationTransition_Fade:
            addFadeTransition(to: navController.view.layer)
            navController.popViewController(animated: false)
        case WuiNavigationTransition_None:
            navController.popViewController(animated: false)
        default:
            navController.popViewController(animated: true)
        }
    }

    private func addFadeTransition(to layer: CALayer?) {
        guard let layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.25
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: "waterui.navigation.fade")
    }

    private func makeViewController(
        for view: UIView,
        barState: WuiNavigationBarState?,
        displayMode: UINavigationItem.LargeTitleDisplayMode = .automatic
    ) -> UIViewController {
        let vc = WuiContentViewController(contentView: view, barState: barState)
        vc.navigationItem.largeTitleDisplayMode = displayMode
        return vc
    }

    /// Converts FFI display mode enum to UIKit equivalent.
    private func convertDisplayMode(_ mode: WuiNavigationTitleDisplayMode) -> UINavigationItem.LargeTitleDisplayMode {
        switch mode {
        case WuiNavigationTitleDisplayMode_Automatic:
            return .automatic
        case WuiNavigationTitleDisplayMode_Inline:
            return .never  // .never gives inline (small) title
        case WuiNavigationTitleDisplayMode_Large:
            return .always
        default:
            return .automatic
        }
    }
    #endif

    #if canImport(UIKit)
    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        viewStack = navigationController.viewControllers
    }
    #endif

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let width = proposal.width.map { CGFloat($0) } ?? 320
        let height = proposal.height.map { CGFloat($0) } ?? 480
        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        navController?.view.frame = bounds
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Layout all views in stack to match bounds
        for entry in viewStack {
            entry.view.frame = bounds
        }
    }
    #endif
}

#if canImport(UIKit)
extension WuiNavigationStack: UINavigationControllerDelegate {}
#endif
