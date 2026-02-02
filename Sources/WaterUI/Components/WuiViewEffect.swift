// WuiViewEffect.swift
// GPU effect rendering view that captures child content and applies custom effects
//
// # Architecture
// ViewEffect captures its child view's rendered output and applies a GPU effect to it.
// The effect renderer receives the captured texture and can output to a different-sized texture.
//
// # Layout Behavior
// Layout is based on the child view's intrinsic size, not the effect's output size.
// This allows effects like blur (which may need padding) to work without affecting layout.
//
// # Rendering Pipeline
// 1. Child view renders to capture layer (CAMetalLayer)
// 2. Rust effect receives capture texture as input via Metal HAL
// 3. Effect renders to output layer (CAMetalLayer)
// 4. Output is displayed on screen
//
// # Zero-Copy Texture Sharing
// Uses IOSurface to share textures between the capture layer and wgpu:
// 1. Create IOSurface with shared memory
// 2. Create Metal texture backed by IOSurface
// 3. Pass MTLTexture pointer to Rust via waterui_view_effect_set_input()
// 4. Rust wraps MTLTexture in wgpu via Metal HAL

import CWaterUI
import IOSurface
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - Render State

/// Thread-safe render state for ViewEffect
private final class WuiViewEffectRenderState: @unchecked Sendable {
    private final class BoolCompletionBox: @unchecked Sendable {
        let completion: (Bool) -> Void

        init(_ completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }
    }

    private var ffiEffect: CWaterUI.WuiViewEffect
    private var effectState: OpaquePointer?
    private var isInitializing = false
    private var isActive = true
    private var renderInFlight = false
    private var inputWidth: UInt32 = 0
    private var inputHeight: UInt32 = 0

    /// Metal texture for zero-copy sharing (created from IOSurface)
    private var captureTexture: MTLTexture?
    /// IOSurface backing the capture texture
    private var captureSurface: IOSurfaceRef?

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(
        label: "waterui.view-effect.render",
        qos: .userInteractive
    )

    init(ffiEffect: CWaterUI.WuiViewEffect) {
        self.ffiEffect = ffiEffect
    }

    /// Create or recreate the capture texture with IOSurface backing
    func createCaptureTexture(device: MTLDevice, width: UInt32, height: UInt32) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }

        // Check if we already have a texture of the right size
        if let existing = captureTexture,
           existing.width == Int(width),
           existing.height == Int(height) {
            return existing
        }

        // Create IOSurface properties
        let bytesPerElement = 8 // RGBA16Float = 4 * 2 bytes
        let bytesPerRow = Int(width) * bytesPerElement
        let totalBytes = bytesPerRow * Int(height)

        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: totalBytes,
            kIOSurfacePixelFormat: 0x52477846, // 'RGhF' = RGBA16Float
        ]

        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            Logger.waterui.error("[WuiViewEffect] Failed to create IOSurface")
            return nil
        }

        // Create Metal texture descriptor
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared

        // Create Metal texture from IOSurface
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            Logger.waterui.error("[WuiViewEffect] Failed to create Metal texture from IOSurface")
            return nil
        }

        self.captureSurface = surface
        self.captureTexture = texture
        self.inputWidth = width
        self.inputHeight = height

        Logger.waterui.debug("[WuiViewEffect] Created capture texture: \(width)x\(height)")
        return texture
    }

    /// Get the current capture texture
    func getCaptureTexture() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return captureTexture
    }

    func updateSize(width: UInt32, height: UInt32) {
        lock.lock()
        self.inputWidth = width
        self.inputHeight = height
        lock.unlock()
    }

    func initializeIfNeeded(
        outputLayerPtr: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32,
        completion: @escaping (Bool) -> Void
    ) {
        lock.lock()
        if !isActive {
            lock.unlock()
            completion(false)
            return
        }

        self.inputWidth = width
        self.inputHeight = height

        if effectState != nil {
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

        let completionBox = BoolCompletionBox(completion)
        let outputLayerAddr = Int(bitPattern: outputLayerPtr)

        renderQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completionBox.completion(false) }
                return
            }

            guard let outputLayerPtr = UnsafeMutableRawPointer(bitPattern: outputLayerAddr) else {
                self.lock.lock()
                self.isInitializing = false
                self.lock.unlock()
                DispatchQueue.main.async { completionBox.completion(false) }
                return
            }

            let state: OpaquePointer? = withUnsafeMutablePointer(to: &self.ffiEffect) {
                effectPtr in
                waterui_view_effect_init(effectPtr, outputLayerPtr, width, height)
            }

            self.lock.lock()
            self.isInitializing = false

            guard self.isActive else {
                self.lock.unlock()
                if let state { waterui_view_effect_drop(state) }
                return
            }

            self.effectState = state
            let success = (state != nil)
            self.lock.unlock()

            DispatchQueue.main.async {
                completionBox.completion(success)
            }
        }
    }

    func requestRender() {
        lock.lock()
        if !isActive {
            lock.unlock()
            return
        }

        guard let state = effectState, inputWidth > 0, inputHeight > 0, !renderInFlight else {
            lock.unlock()
            return
        }

        renderInFlight = true
        let stateAddr = Int(bitPattern: state)
        lock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let state = OpaquePointer(bitPattern: stateAddr) else {
                self.lock.lock()
                self.renderInFlight = false
                self.lock.unlock()
                return
            }
            _ = waterui_view_effect_render(state)
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
        }
    }

    /// Provide input texture data to the effect
    func setInput(type: WuiInputType, handle: UnsafeMutableRawPointer, width: UInt32, height: UInt32) -> Bool {
        lock.lock()
        guard let state = effectState, isActive else {
            lock.unlock()
            return false
        }
        lock.unlock()

        return waterui_view_effect_set_input(state, type, handle, width, height)
    }

    func shutdown() {
        lock.lock()
        isActive = false
        let state = effectState
        effectState = nil
        lock.unlock()

        renderQueue.sync {
            if let state { waterui_view_effect_drop(state) }
        }
    }
}

// MARK: - ViewEffect Component

/// GPU effect view that captures child content and applies custom effects
@MainActor
final class WuiViewEffect: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_view_effect_id() }

    private(set) var stretchAxis: WuiStretchAxis = .none

    private let renderState: WuiViewEffectRenderState

    /// Metal device for texture creation
    private var metalDevice: MTLDevice?

    /// The output CAMetalLayer for effect result
    private var outputLayer: CAMetalLayer!

    /// The child view component
    private var childView: WuiAnyView?

    /// Whether GPU resources have been initialized
    private var isGpuInitialized = false

    /// Content scale factor
    private var currentScaleFactor: CGFloat = 1.0

    /// Current capture texture dimensions
    private var captureWidth: UInt32 = 0
    private var captureHeight: UInt32 = 0

    /// Display link for frame sync
    #if canImport(UIKit)
        private var displayLink: CADisplayLink?
    #elseif canImport(AppKit)
        private var displayLink: CADisplayLink?
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiEffect = waterui_force_as_view_effect(anyview)
        self.init(stretchAxis: stretchAxis, ffiEffect: ffiEffect, env: env)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, ffiEffect: CWaterUI.WuiViewEffect, env: WuiEnvironment) {
        self.stretchAxis = stretchAxis
        self.renderState = WuiViewEffectRenderState(ffiEffect: ffiEffect)

        super.init(frame: .zero)

        setupOutputLayer()
        if let contentPtr = ffiEffect.content {
            setupChildView(content: contentPtr, env: env)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupOutputLayer() {
        outputLayer = CAMetalLayer()

        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.waterui.error("[WuiViewEffect] Failed to create Metal device")
            return
        }

        // Save device for texture creation
        self.metalDevice = device

        outputLayer.device = device
        outputLayer.framebufferOnly = true
        outputLayer.maximumDrawableCount = 3
        outputLayer.isOpaque = false
        #if canImport(UIKit)
            outputLayer.backgroundColor = UIColor.clear.cgColor
        #elseif canImport(AppKit)
            outputLayer.backgroundColor = NSColor.clear.cgColor
        #endif

        // Configure HDR
        outputLayer.pixelFormat = .rgba16Float
        outputLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        outputLayer.wantsExtendedDynamicRangeContent = true

        #if canImport(UIKit)
            layer.addSublayer(outputLayer)
        #elseif canImport(AppKit)
            wantsLayer = true
            if self.layer == nil {
                self.layer = CALayer()
            }
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.addSublayer(outputLayer)
        #endif
    }

    private func setupChildView(content: OpaquePointer, env: WuiEnvironment) {
        // Create the child WuiAnyView
        childView = WuiAnyView(anyview: content, env: env)

        if let child = childView {
            // Child view is placed behind the output layer
            // In a full implementation, the child would render to a capture texture
            #if canImport(UIKit)
                insertSubview(child, at: 0)
            #elseif canImport(AppKit)
                addSubview(child, positioned: .below, relativeTo: nil)
            #endif
        }
    }

    // MARK: - GPU Initialization

    private func initializeGpuIfNeeded() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard let device = metalDevice else { return }

        #if canImport(UIKit)
            currentScaleFactor = contentScaleFactor
        #elseif canImport(AppKit)
            currentScaleFactor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        #endif

        let width = UInt32(bounds.width * currentScaleFactor)
        let height = UInt32(bounds.height * currentScaleFactor)

        // Create/update capture texture if size changed
        if width != captureWidth || height != captureHeight {
            _ = renderState.createCaptureTexture(device: device, width: width, height: height)
            captureWidth = width
            captureHeight = height
        }

        renderState.updateSize(width: width, height: height)

        // Update output layer
        outputLayer.frame = bounds
        outputLayer.drawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        outputLayer.contentsScale = currentScaleFactor

        let layerPtr = Unmanaged.passUnretained(outputLayer).toOpaque()

        guard !isGpuInitialized else { return }
        renderState.initializeIfNeeded(outputLayerPtr: layerPtr, width: width, height: height) {
            [weak self] success in
            guard let self else { return }
            guard success else {
                Logger.waterui.error("[WuiViewEffect] GPU initialization failed")
                return
            }
            self.isGpuInitialized = true
            self.startDisplayLink()
        }
    }

    // MARK: - Display Link

    #if canImport(UIKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(render))

            // Request up to 120fps on ProMotion displays
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
            onFrame()
        }
    #elseif canImport(AppKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link: CADisplayLink
            if let window {
                link = window.displayLink(target: self, selector: #selector(render))
            } else if let screen = NSScreen.main {
                link = screen.displayLink(target: self, selector: #selector(render))
            } else {
                return
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func render() {
            onFrame()
        }
    #endif

    private func onFrame() {
        // Get the capture texture
        guard let captureTexture = renderState.getCaptureTexture() else {
            return
        }

        // Pass the Metal texture pointer to Rust
        // The Rust side will wrap this in wgpu via the Metal HAL
        let texturePtr = Unmanaged.passUnretained(captureTexture).toOpaque()
        let success = renderState.setInput(
            type: WuiInputType_MetalTexture,
            handle: texturePtr,
            width: captureWidth,
            height: captureHeight
        )

        if success {
            // Trigger the effect render
            renderState.requestRender()
        }
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Delegate sizing to child view
        if let child = childView {
            return child.sizeThatFits(proposal)
        }
        return .zero
    }

    // MARK: - Layout

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            outputLayer.frame = bounds
            childView?.frame = bounds
            initializeGpuIfNeeded()
        }
    #elseif canImport(AppKit)
        override func layout() {
            super.layout()
            outputLayer.frame = bounds
            childView?.frame = bounds
            initializeGpuIfNeeded()
        }
    #endif

    // MARK: - Cleanup

    @MainActor deinit {
        stopDisplayLink()
        renderState.shutdown()
    }
}
