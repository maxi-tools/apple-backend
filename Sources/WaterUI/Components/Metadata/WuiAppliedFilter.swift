// WuiAppliedFilter.swift
// GPU-based filter rendering using wgpu
//
// This component handles Metadata<AppliedFilter> views:
// 1. Captures child view content to a texture
// 2. Sends texture to Rust for GPU filtering
// 3. Displays filtered result
//
// Uses callback-based async setup - no blocking on main thread.

import CWaterUI
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
    import CoreVideo
#endif

/// Context for async callback - holds both state and completion handler.
private final class SetupCallbackContext: @unchecked Sendable {
    let state: WuiAppliedFilterRenderState
    let completion: @Sendable (Bool) -> Void

    init(state: WuiAppliedFilterRenderState, completion: @escaping @Sendable (Bool) -> Void) {
        self.state = state
        self.completion = completion
    }
}

/// Thread-safe render state for AppliedFilter.
private final class WuiAppliedFilterRenderState: @unchecked Sendable {
    private var filterState: OpaquePointer?
    private var isInitializing = false
    private var isSetup = false
    private var isActive = true
    private var renderInFlight = false
    private var width: UInt32 = 0
    private var height: UInt32 = 0

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(
        label: "waterui.applied-filter.render",
        qos: .userInteractive
    )

    func updateSize(width: UInt32, height: UInt32) {
        lock.lock()
        self.width = width
        self.height = height
        lock.unlock()
    }

    /// Initialize filter resources (sync init, then async setup).
    func initializeIfNeeded(
        filter: UnsafeMutablePointer<WuiAppliedFilter_Struct>,
        layerPtr: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        if !isActive {
            lock.unlock()
            completion(false)
            return
        }

        self.width = width
        self.height = height

        if filterState != nil && isSetup {
            lock.unlock()
            completion(true)
            return
        }

        if isInitializing {
            lock.unlock()
            return
        }

        isInitializing = true
        lock.unlock()

        // Capture completion for later use in callback
        let completionCopy = completion

        renderQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completionCopy(false) }
                return
            }

            // Step 1: Sync init
            let state = waterui_applied_filter_init(filter, layerPtr, width, height)

            self.lock.lock()
            guard self.isActive else {
                self.isInitializing = false
                self.lock.unlock()
                if let state { waterui_applied_filter_drop(state) }
                DispatchQueue.main.async { completionCopy(false) }
                return
            }

            if state == nil {
                self.isInitializing = false
                self.lock.unlock()
                Logger.waterui.error("[AppliedFilter] Init failed")
                DispatchQueue.main.async { completionCopy(false) }
                return
            }

            self.filterState = state
            self.lock.unlock()

            // Step 2: Async setup with callback
            // Create context object that holds both state and completion
            let callbackContext = SetupCallbackContext(state: self, completion: completionCopy)
            let contextPtr = Unmanaged.passRetained(callbackContext).toOpaque()

            waterui_applied_filter_setup(state, setupCallback, contextPtr)
        }
    }

    func requestRender() {
        lock.lock()
        if !isActive || !isSetup {
            lock.unlock()
            return
        }

        guard let state = filterState, width > 0, height > 0, !renderInFlight else {
            lock.unlock()
            return
        }

        renderInFlight = true
        let width = self.width
        let height = self.height
        lock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            _ = waterui_applied_filter_render(state, width, height)
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
        }
    }

    func shutdown() {
        lock.lock()
        isActive = false
        let state = filterState
        filterState = nil
        lock.unlock()

        renderQueue.sync {
            if let state { waterui_applied_filter_drop(state) }
        }
    }

    func markSetupComplete() {
        lock.lock()
        isInitializing = false
        isSetup = true
        lock.unlock()
    }
}

/// C-compatible callback for async setup completion.
/// Must be a static function - cannot capture any context.
private func setupCallback(userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }

    // Retrieve the context object
    let context = Unmanaged<SetupCallbackContext>.fromOpaque(userData).takeRetainedValue()

    // Mark setup complete
    context.state.markSetupComplete()

    Logger.waterui.debug("[AppliedFilter] Setup complete")

    // Call completion on main thread
    DispatchQueue.main.async {
        context.completion(true)
    }
}

/// GPU filter component for Metadata<AppliedFilter>.
///
/// Captures child view content and applies GPU filters via wgpu.
/// Uses CAMetalLayer for output display.
@MainActor
final class WuiAppliedFilter: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_applied_filter_id() }

    private let contentView: any WuiComponent
    private let renderState: WuiAppliedFilterRenderState
    private var ffiFilter: WuiAppliedFilter_Struct

    /// Output metal layer for filtered content
    private var outputLayer: CAMetalLayer!

    /// Whether GPU resources are initialized
    private var isGpuInitialized = false

    /// Content scale factor
    private var currentScaleFactor: CGFloat = 1.0

    /// Display link for render sync
    #if canImport(UIKit)
        private var displayLink: CADisplayLink?
    #elseif canImport(AppKit)
        private var displayLink: CVDisplayLink?
        private var displayLinkUserInfo: UnsafeMutableRawPointer?
    #endif

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_applied_filter(anyview)
        self.ffiFilter = metadata

        // Resolve child view
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
        self.renderState = WuiAppliedFilterRenderState()

        super.init(frame: .zero)

        #if canImport(AppKit)
            wantsLayer = true
        #endif

        setupOutputLayer()
        setupContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupOutputLayer() {
        outputLayer = CAMetalLayer()

        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.waterui.error("[AppliedFilter] Failed to create Metal device")
            return
        }

        outputLayer.device = device
        outputLayer.framebufferOnly = true
        outputLayer.maximumDrawableCount = 3
        outputLayer.isOpaque = false
        outputLayer.backgroundColor = CGColor.clear
        outputLayer.pixelFormat = .rgba16Float
        outputLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        outputLayer.wantsExtendedDynamicRangeContent = true

        #if canImport(UIKit)
            layer.addSublayer(outputLayer)
        #elseif canImport(AppKit)
            if self.layer == nil {
                self.layer = CALayer()
            }
            self.layer?.backgroundColor = CGColor.clear
            self.layer?.addSublayer(outputLayer)
        #endif
    }

    private func setupContentView() {
        contentView.translatesAutoresizingMaskIntoConstraints = true
        // Content view is rendered off-screen for capture
        // We don't add it as a subview - the filter handles display
        addSubview(contentView)
        contentView.isHidden = true
    }

    // MARK: - GPU Initialization

    private func initializeGpuIfNeeded() {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        #if canImport(UIKit)
            currentScaleFactor = contentScaleFactor
        #elseif canImport(AppKit)
            currentScaleFactor =
                window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        #endif

        let width = UInt32(bounds.width * currentScaleFactor)
        let height = UInt32(bounds.height * currentScaleFactor)

        renderState.updateSize(width: width, height: height)

        // Update output layer
        outputLayer.frame = bounds
        outputLayer.drawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        outputLayer.contentsScale = currentScaleFactor

        guard !isGpuInitialized else { return }

        let layerPtr = Unmanaged.passUnretained(outputLayer).toOpaque()

        withUnsafeMutablePointer(to: &ffiFilter) { filterPtr in
            renderState.initializeIfNeeded(
                filter: filterPtr,
                layerPtr: layerPtr,
                width: width,
                height: height
            ) { [weak self] success in
                guard let self, success else { return }
                // We're already on main thread (completion dispatches to main)
                // but we need to inform Swift we're on MainActor
                MainActor.assumeIsolated {
                    self.isGpuInitialized = true
                    self.startDisplayLink()
                    self.renderFrame()
                }
            }
        }
    }

    // MARK: - Display Link

    #if canImport(UIKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(render))

            if #available(iOS 15.0, tvOS 15.0, *) {
                displayLink?.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60,
                    maximum: 120,
                    preferred: 120
                )
            }

            displayLink?.add(to: .main, forMode: .common)
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func render() {
            renderFrame()
        }
    #elseif canImport(AppKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }

            var link: CVDisplayLink?
            let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard status == kCVReturnSuccess, let link else { return }

            displayLink = link

            let userInfo = Unmanaged.passRetained(renderState).toOpaque()
            displayLinkUserInfo = userInfo

            CVDisplayLinkSetOutputCallback(
                link,
                { _, _, _, _, _, userInfo -> CVReturn in
                    guard let userInfo else { return kCVReturnError }
                    let state = Unmanaged<WuiAppliedFilterRenderState>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    state.requestRender()
                    return kCVReturnSuccess
                },
                userInfo
            )

            CVDisplayLinkStart(link)
        }

        private func stopDisplayLink() {
            if let link = displayLink {
                CVDisplayLinkStop(link)
                displayLink = nil
            }

            if let userInfo = displayLinkUserInfo {
                Unmanaged<WuiAppliedFilterRenderState>.fromOpaque(userInfo).release()
                displayLinkUserInfo = nil
            }
        }
    #endif

    private func renderFrame() {
        renderState.requestRender()
    }

    // MARK: - WuiComponent

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    // MARK: - Layout

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            contentView.frame = bounds
            updateOutputLayerFrame()
            initializeGpuIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                currentScaleFactor = contentScaleFactor
                updateOutputLayerFrame()
                initializeGpuIfNeeded()
            }
        }
    #elseif canImport(AppKit)
        override var isFlipped: Bool { true }

        override var wantsLayer: Bool {
            get { true }
            set {}
        }

        override func layout() {
            super.layout()
            contentView.frame = bounds
            updateOutputLayerFrame()
            initializeGpuIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                currentScaleFactor = window?.backingScaleFactor ?? 1.0
                updateOutputLayerFrame()
                initializeGpuIfNeeded()
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            if let newScale = window?.backingScaleFactor, newScale != currentScaleFactor {
                currentScaleFactor = newScale
                updateOutputLayerFrame()
                initializeGpuIfNeeded()
            }
        }
    #endif

    private func updateOutputLayerFrame() {
        guard outputLayer != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        outputLayer.frame = bounds
        outputLayer.contentsScale = currentScaleFactor

        let width = bounds.width * currentScaleFactor
        let height = bounds.height * currentScaleFactor
        if width > 0 && height > 0 {
            outputLayer.drawableSize = CGSize(width: width, height: height)
        }

        CATransaction.commit()
    }

    // MARK: - Cleanup

    @MainActor deinit {
        stopDisplayLink()
        renderState.shutdown()
    }
}

// Type alias for the FFI struct
private typealias WuiAppliedFilter_Struct = CWaterUI.WuiAppliedFilter
