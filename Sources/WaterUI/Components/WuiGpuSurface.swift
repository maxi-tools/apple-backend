// WuiGpuSurface.swift
// High-performance GPU rendering surface using wgpu
//
// # Layout Behavior
// GpuSurface stretches to fill available space by default (like SwiftUI's Color).
// Users can control size using the `.frame()` modifier externally.
//
// # Rendering
// Uses CAMetalLayer for zero-copy GPU rendering at up to 120fps.
// The Rust side owns wgpu Device/Queue/Surface and calls user's GpuRenderer callbacks.
//
// # HDR Support
// Configures CAMetalLayer for HDR when available using extended sRGB color space.

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

private final class WuiGpuSurfaceRenderState: @unchecked Sendable {
    private var ffiSurface: CWaterUI.WuiGpuSurface
    private var gpuState: OpaquePointer?
    private var isInitializing = false
    private var isActive = true
    private var renderInFlight = false
    private var externalRendering = false
    private var width: UInt32 = 0
    private var height: UInt32 = 0

    // Pointer/cursor state for GPU renderers
    private var pointerState = WuiPointerState(
        has_position: false,
        x: 0,
        y: 0,
        has_hit: false,
        hit_x: 0,
        hit_y: 0
    )

    // Gesture state for zoom/pan interactions
    private var gestureState = WuiGestureState(
        active: false,
        pinch_scale: 1.0,
        has_pinch_center: false,
        pinch_center_x: 0,
        pinch_center_y: 0,
        pan_offset_x: 0,
        pan_offset_y: 0,
        double_tap: false
    )

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(
        label: "waterui.gpu-surface.render",
        qos: .userInteractive
    )
    private let queueKey = DispatchSpecificKey<Void>()

    init(ffiSurface: CWaterUI.WuiGpuSurface) {
        self.ffiSurface = ffiSurface
        renderQueue.setSpecific(key: queueKey, value: ())
    }

    /// Update pointer position (in surface-local pixel coordinates).
    func updatePointerPosition(_ position: CGPoint?, scaleFactor: CGFloat) {
        lock.lock()
        if let pos = position {
            pointerState.has_position = true
            pointerState.x = Float(pos.x * scaleFactor)
            pointerState.y = Float(pos.y * scaleFactor)
        } else {
            pointerState.has_position = false
        }
        lock.unlock()
    }

    /// Update pointer hit state.
    func updatePointerHit(_ hit: Bool, origin: CGPoint?, scaleFactor: CGFloat) {
        lock.lock()
        if hit, let origin = origin {
            pointerState.has_hit = true
            pointerState.hit_x = Float(origin.x * scaleFactor)
            pointerState.hit_y = Float(origin.y * scaleFactor)
        } else if !hit {
            pointerState.has_hit = false
        }
        lock.unlock()
    }

    /// Update gesture state for pinch zoom.
    func updatePinchGesture(active: Bool, scale: CGFloat, center: CGPoint?, scaleFactor: CGFloat) {
        lock.lock()
        gestureState.active = active
        gestureState.pinch_scale = Float(scale)
        if let center = center {
            gestureState.has_pinch_center = true
            gestureState.pinch_center_x = Float(center.x * scaleFactor)
            gestureState.pinch_center_y = Float(center.y * scaleFactor)
        } else {
            gestureState.has_pinch_center = false
        }
        lock.unlock()
    }

    /// Update gesture state for pan.
    func updatePanGesture(active: Bool, offsetX: CGFloat, offsetY: CGFloat, scaleFactor: CGFloat) {
        lock.lock()
        gestureState.active = active
        gestureState.pan_offset_x = Float(offsetX * scaleFactor)
        gestureState.pan_offset_y = Float(offsetY * scaleFactor)
        lock.unlock()
    }

    /// Signal a double-tap gesture.
    func triggerDoubleTap() {
        lock.lock()
        gestureState.double_tap = true
        lock.unlock()
    }

    /// Clear double-tap flag (called after rendering).
    private func clearDoubleTap() {
        gestureState.double_tap = false
    }

    /// Reset gesture state when gesture ends.
    func resetGestureState() {
        lock.lock()
        gestureState.active = false
        gestureState.pinch_scale = 1.0
        gestureState.has_pinch_center = false
        gestureState.pan_offset_x = 0
        gestureState.pan_offset_y = 0
        lock.unlock()
    }

    /// Send current pointer state to the GPU surface before rendering.
    private func syncPointerState() {
        guard let state = gpuState else { return }
        waterui_gpu_surface_set_pointer(state, pointerState)
    }

    /// Send current gesture state to the GPU surface before rendering.
    private func syncGestureState() {
        guard let state = gpuState else { return }
        waterui_gpu_surface_set_gesture(state, gestureState)
        // Clear double_tap after sending (it's a one-frame signal)
        clearDoubleTap()
    }

    func updateSize(width: UInt32, height: UInt32) {
        lock.lock()
        self.width = width
        self.height = height
        lock.unlock()
    }

    func initializeIfNeeded(
        layerPtr: UnsafeMutableRawPointer,
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

        self.width = width
        self.height = height

        if gpuState != nil {
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

        renderQueue.async { [weak self] in
            guard let self else { return }

            let state: OpaquePointer? = withUnsafeMutablePointer(to: &self.ffiSurface) {
                surfacePtr in
                waterui_gpu_surface_init(surfacePtr, layerPtr, width, height)
            }

            self.lock.lock()
            self.isInitializing = false

            guard self.isActive else {
                self.lock.unlock()
                if let state { waterui_gpu_surface_drop(state) }
                return
            }

            self.gpuState = state
            let success = (state != nil)
            self.lock.unlock()

            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    func requestRender() {
        lock.lock()
        if !isActive || externalRendering {
            lock.unlock()
            return
        }

        guard let state = gpuState, width > 0, height > 0, !renderInFlight else {
            lock.unlock()
            return
        }

        renderInFlight = true
        let width = self.width
        let height = self.height
        lock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            // Sync pointer and gesture state before rendering
            self.syncPointerState()
            self.syncGestureState()
            _ = waterui_gpu_surface_render(state, width, height)
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
        }
    }

    func waitForIdle() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return
        }
        renderQueue.sync {}
    }

    func setExternalRendering(_ enabled: Bool) {
        lock.lock()
        externalRendering = enabled
        lock.unlock()
    }

    func clearExternalRendering() {
        setExternalRendering(false)
    }

    func renderToTexture(texturePtr: UnsafeMutableRawPointer, width: UInt32, height: UInt32) -> Bool {
        lock.lock()
        if !isActive {
            lock.unlock()
            return false
        }
        let inFlight = renderInFlight
        lock.unlock()

        if inFlight {
            waitForIdle()
        }

        lock.lock()
        guard isActive, let state = gpuState, width > 0, height > 0 else {
            lock.unlock()
            return false
        }
        if renderInFlight {
            lock.unlock()
            return false
        }
        renderInFlight = true
        lock.unlock()

        let renderBlock = { [weak self] () -> Bool in
            guard let self else { return false }
            self.syncPointerState()
            self.syncGestureState()
            let ok = waterui_gpu_surface_render_to_texture(state, texturePtr, width, height)
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
            return ok
        }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return renderBlock()
        }

        var ok = false
        renderQueue.sync {
            ok = renderBlock()
        }
        return ok
    }

    func renderToMetalTexture(texturePtr: UnsafeMutableRawPointer, width: UInt32, height: UInt32) -> Bool {
        lock.lock()
        if !isActive {
            lock.unlock()
            return false
        }
        let inFlight = renderInFlight
        lock.unlock()

        if inFlight {
            waitForIdle()
        }

        lock.lock()
        guard isActive, let state = gpuState, width > 0, height > 0 else {
            lock.unlock()
            return false
        }
        if renderInFlight {
            lock.unlock()
            return false
        }
        renderInFlight = true
        lock.unlock()

        let renderBlock = { [weak self] () -> Bool in
            guard let self else { return false }
            self.syncPointerState()
            self.syncGestureState()
            let ok = waterui_gpu_surface_render_to_metal_texture(state, texturePtr, width, height)
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
            return ok
        }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return renderBlock()
        }

        var ok = false
        renderQueue.sync {
            ok = renderBlock()
        }
        return ok
    }

    /// Get current state and initialization status (thread-safe).
    private func getStateInfo() -> (state: OpaquePointer?, isInitializing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (gpuState, isInitializing)
    }

    /// Await GPU setup completion and first frame render.
    /// This is used to ensure all GpuSurfaces are ready before showing the window.
    func awaitReady() async {
        // Wait for state to be available
        var state: OpaquePointer?
        while true {
            let info = getStateInfo()
            state = info.state

            if state != nil {
                break
            }
            if !info.isInitializing {
                // Not initialized and not initializing - nothing to wait for
                return
            }
            // Poll every 10ms while initializing
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard let state else { return }

        // Call await_ready on render queue with callback
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            renderQueue.async {
                // Create a context to pass through the callback
                let context = Unmanaged.passRetained(continuation as AnyObject).toOpaque()

                waterui_gpu_surface_await_ready(
                    state,
                    { userData in
                        guard let userData else { return }
                        let cont = Unmanaged<AnyObject>.fromOpaque(userData).takeRetainedValue()
                        if let continuation = cont as? CheckedContinuation<Void, Never> {
                            continuation.resume()
                        }
                    },
                    context
                )
            }
        }
    }

    func shutdown() {
        lock.lock()
        isActive = false
        let state = gpuState
        gpuState = nil
        lock.unlock()

        renderQueue.sync {
            if let state { waterui_gpu_surface_drop(state) }
        }
    }
}

/// High-performance GPU rendering surface using wgpu.
/// Uses CAMetalLayer with CADisplayLink for 120fps rendering.
@MainActor
final class WuiGpuSurface: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_gpu_surface_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private nonisolated(unsafe) let renderState: WuiGpuSurfaceRenderState

    /// The CAMetalLayer for GPU rendering
    private var metalLayer: CAMetalLayer!

    /// Display link for frame sync (120fps capable)
    #if canImport(UIKit)
        private var displayLink: CADisplayLink?
    #elseif canImport(AppKit)
        private var displayLink: CVDisplayLink?
        private var displayLinkUserInfo: UnsafeMutableRawPointer?
        private var trackingArea: NSTrackingArea?
    #endif

    /// Whether we've initialized the GPU resources
    private var isGpuInitialized = false
    private var externalRendering = false
    private var externalRenderingCount = 0
    private let externalLock = NSLock()

    /// Current pointer pressed state (for tracking press origin)
    private var pressOrigin: CGPoint?

    /// Content scale factor for high-DPI displays
    private var currentScaleFactor: CGFloat = 1.0

    /// Gesture tracking state
    private var gestureStartScale: CGFloat = 1.0
    private var cumulativeScale: CGFloat = 1.0
    private var gesturePanOffset: CGPoint = .zero

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiSurface = waterui_force_as_gpu_surface(anyview)
        self.init(stretchAxis: stretchAxis, ffiSurface: ffiSurface)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, ffiSurface: CWaterUI.WuiGpuSurface) {
        self.stretchAxis = stretchAxis
        self.renderState = WuiGpuSurfaceRenderState(ffiSurface: ffiSurface)

        super.init(frame: .zero)

        setupMetalLayer()
        setupPointerTracking()
    }

    // MARK: - Pointer Tracking Setup

    private func setupPointerTracking() {
        #if canImport(UIKit)
            // iOS/iPadOS: Add hover gesture for pointer tracking (iPadOS with trackpad/mouse)
            if #available(iOS 13.0, *) {
                let hoverGesture = UIHoverGestureRecognizer(
                    target: self, action: #selector(handleHover(_:)))
                addGestureRecognizer(hoverGesture)
            }

            // Add pinch gesture for zoom
            let pinchGesture = UIPinchGestureRecognizer(
                target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinchGesture)

            // Add pan gesture for chart panning
            let panGesture = UIPanGestureRecognizer(
                target: self, action: #selector(handlePan(_:)))
            panGesture.minimumNumberOfTouches = 2  // Require 2 fingers to avoid conflict with scroll
            addGestureRecognizer(panGesture)

            // Add double-tap gesture for reset
            let doubleTapGesture = UITapGestureRecognizer(
                target: self, action: #selector(handleDoubleTap(_:)))
            doubleTapGesture.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTapGesture)

            // Allow simultaneous gesture recognition
            pinchGesture.delegate = self
            panGesture.delegate = self
        #elseif canImport(AppKit)
            // macOS: Tracking area is updated in updateTrackingAreas()
            // Add magnification gesture for zoom
            let magnifyGesture = NSMagnificationGestureRecognizer(
                target: self, action: #selector(handleMagnification(_:)))
            addGestureRecognizer(magnifyGesture)

            // Add pan gesture for chart panning (scroll gesture)
            // Note: On macOS, we use scroll events instead of a separate pan gesture
        #endif
    }

    #if canImport(UIKit)
        @available(iOS 13.0, *)
        @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                let location = gesture.location(in: self)
                renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
            case .ended, .cancelled:
                renderState.updatePointerPosition(nil, scaleFactor: currentScaleFactor)
            default:
                break
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            if let touch = touches.first {
                let location = touch.location(in: self)
                pressOrigin = location
                renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
                renderState.updatePointerHit(true, origin: location, scaleFactor: currentScaleFactor)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            if let touch = touches.first {
                let location = touch.location(in: self)
                renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            renderState.updatePointerHit(false, origin: nil, scaleFactor: currentScaleFactor)
            pressOrigin = nil
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            renderState.updatePointerHit(false, origin: nil, scaleFactor: currentScaleFactor)
            pressOrigin = nil
        }

        // MARK: - Gesture Handlers (iOS)

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            let center = gesture.location(in: self)

            switch gesture.state {
            case .began:
                gestureStartScale = cumulativeScale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                let newScale = gestureStartScale * gesture.scale
                cumulativeScale = max(0.1, min(newScale, 10.0))  // Clamp scale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePinchGesture(
                    active: false,
                    scale: cumulativeScale,
                    center: nil,
                    scaleFactor: currentScaleFactor
                )
            default:
                break
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: self)

            switch gesture.state {
            case .began:
                gesturePanOffset = .zero
                renderState.updatePanGesture(
                    active: true,
                    offsetX: 0,
                    offsetY: 0,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                gesturePanOffset = CGPoint(x: translation.x, y: translation.y)
                renderState.updatePanGesture(
                    active: true,
                    offsetX: translation.x,
                    offsetY: translation.y,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePanGesture(
                    active: false,
                    offsetX: translation.x,
                    offsetY: translation.y,
                    scaleFactor: currentScaleFactor
                )
                gesturePanOffset = .zero
            default:
                break
            }
        }

        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .recognized {
                // Reset zoom/pan state
                cumulativeScale = 1.0
                gesturePanOffset = .zero
                renderState.triggerDoubleTap()
                renderState.resetGestureState()
            }
        }
    #elseif canImport(AppKit)
        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            // Remove old tracking area
            if let oldArea = trackingArea {
                removeTrackingArea(oldArea)
            }

            // Create new tracking area for mouse enter/exit and move
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect,
            ]
            trackingArea = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea!)
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            let location = convert(event.locationInWindow, from: nil)
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            let location = convert(event.locationInWindow, from: nil)
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            renderState.updatePointerPosition(nil, scaleFactor: currentScaleFactor)
        }

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            let location = convert(event.locationInWindow, from: nil)
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            renderState.updatePointerHit(false, origin: nil, scaleFactor: currentScaleFactor)
            pressOrigin = nil
        }

        override var acceptsFirstResponder: Bool { true }

        // MARK: - Gesture Handlers (macOS)

        @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
            let center = convert(gesture.location(in: self), from: nil)

            switch gesture.state {
            case .began:
                gestureStartScale = cumulativeScale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                let newScale = gestureStartScale * (1.0 + gesture.magnification)
                cumulativeScale = max(0.1, min(newScale, 10.0))  // Clamp scale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePinchGesture(
                    active: false,
                    scale: cumulativeScale,
                    center: nil,
                    scaleFactor: currentScaleFactor
                )
            default:
                break
            }
        }

        override func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)

            // Handle scroll wheel for panning (with Option key or trackpad)
            // Note: deltaX/deltaY are in points
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY

            // Check for scroll gesture phase
            switch event.phase {
            case .began:
                gesturePanOffset = .zero
                renderState.updatePanGesture(
                    active: true,
                    offsetX: deltaX,
                    offsetY: deltaY,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                gesturePanOffset = CGPoint(
                    x: gesturePanOffset.x + deltaX,
                    y: gesturePanOffset.y + deltaY
                )
                renderState.updatePanGesture(
                    active: true,
                    offsetX: gesturePanOffset.x,
                    offsetY: gesturePanOffset.y,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePanGesture(
                    active: false,
                    offsetX: gesturePanOffset.x,
                    offsetY: gesturePanOffset.y,
                    scaleFactor: currentScaleFactor
                )
                gesturePanOffset = .zero
            default:
                // Handle scroll events without phases (e.g., mouse wheel)
                if event.phase == [] && event.momentumPhase == [] {
                    // Immediate scroll event - treat as one-shot pan
                    renderState.updatePanGesture(
                        active: true,
                        offsetX: deltaX,
                        offsetY: deltaY,
                        scaleFactor: currentScaleFactor
                    )
                    renderState.updatePanGesture(
                        active: false,
                        offsetX: deltaX,
                        offsetY: deltaY,
                        scaleFactor: currentScaleFactor
                    )
                }
            }
        }

        // Double-click to reset zoom/pan
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            let location = convert(event.locationInWindow, from: nil)
            pressOrigin = location
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
            renderState.updatePointerHit(true, origin: location, scaleFactor: currentScaleFactor)

            // Check for double-click
            if event.clickCount == 2 {
                cumulativeScale = 1.0
                gesturePanOffset = .zero
                renderState.triggerDoubleTap()
                renderState.resetGestureState()
            }
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Metal Layer Setup

    private func setupMetalLayer() {
        metalLayer = CAMetalLayer()

        // Get the default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.waterui.error("[WuiGpuSurface] Failed to create Metal device")
            return
        }

        metalLayer.device = device
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3  // Triple buffering for smooth 120fps
        metalLayer.isOpaque = false  // Allow transparency for compositing with background
        metalLayer.backgroundColor = CGColor.clear  // Ensure no black background

        // Configure HDR support if available
        configureHDR()

        #if canImport(UIKit)
            // iOS/tvOS: Add metal layer as sublayer
            layer.addSublayer(metalLayer)
        #elseif canImport(AppKit)
            // macOS: Need to set wantsLayer and add sublayer
            wantsLayer = true
            if self.layer == nil {
                self.layer = CALayer()
            }
            self.layer?.backgroundColor = CGColor.clear
            self.layer?.addSublayer(metalLayer)
        #endif
    }

    /// Configure the metal layer for HDR rendering
    private func configureHDR() {
        // Use Rgba16Float for HDR support (must match Rust side)
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalLayer.wantsExtendedDynamicRangeContent = true
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

        // Update metal layer frame and drawable size
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        metalLayer.contentsScale = currentScaleFactor

        // Get pointer to metal layer for wgpu surface creation
        let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()

        guard !isGpuInitialized else { return }
        renderState.initializeIfNeeded(layerPtr: layerPtr, width: width, height: height) {
            [weak self] success in
            guard let self else { return }
            guard success else { return }
            self.isGpuInitialized = true
            if !self.externalRendering {
                self.startDisplayLink()
            }
            // Trigger immediate first render to avoid empty frame on window open
            self.renderFrame()
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
                    let state = Unmanaged<WuiGpuSurfaceRenderState>.fromOpaque(userInfo)
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
                Unmanaged<WuiGpuSurfaceRenderState>.fromOpaque(userInfo).release()
                displayLinkUserInfo = nil
            }
        }
    #endif

    private func renderFrame() {
        renderState.requestRender()
    }

    func setExternalRendering(_ enabled: Bool) {
        externalRendering = enabled
        renderState.setExternalRendering(enabled)
        if enabled {
            stopDisplayLink()
        } else if isGpuInitialized {
            startDisplayLink()
        }
    }

    func clearExternalRendering() {
        setExternalRendering(false)
    }

    func beginExternalRendering() {
        externalLock.lock()
        externalRenderingCount += 1
        let shouldEnable = externalRenderingCount == 1
        externalLock.unlock()
        if shouldEnable {
            setExternalRendering(true)
        }
    }

    func endExternalRendering() {
        externalLock.lock()
        if externalRenderingCount > 0 {
            externalRenderingCount -= 1
        }
        let shouldDisable = externalRenderingCount == 0
        externalLock.unlock()
        if shouldDisable {
            renderState.waitForIdle()
            setExternalRendering(false)
        }
    }

    nonisolated func renderToTexture(
        texturePtr: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        renderState.renderToTexture(texturePtr: texturePtr, width: width, height: height)
    }

    nonisolated func renderToMetalTexture(
        texture: MTLTexture,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        let texturePtr = Unmanaged.passUnretained(texture).toOpaque()
        return renderState.renderToMetalTexture(texturePtr: texturePtr, width: width, height: height)
    }

    // MARK: - Async Ready

    /// Wait for GPU setup and first frame to complete.
    /// Call this before showing the window to prevent flicker.
    nonisolated func waitForReady() async {
        await renderState.awaitReady()
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // GpuSurface stretches to fill available space
        let defaultSize: CGFloat = 100

        let width = proposal.width.map { CGFloat($0) } ?? defaultSize
        let height = proposal.height.map { CGFloat($0) } ?? defaultSize

        return CGSize(width: width, height: height)
    }

    // MARK: - Layout

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            updateMetalLayerFrame()
            initializeGpuIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                // Update scale factor when added to window
                currentScaleFactor = contentScaleFactor
                updateMetalLayerFrame()
                initializeGpuIfNeeded()
            }
        }
    #elseif canImport(AppKit)
        override func layout() {
            super.layout()
            updateMetalLayerFrame()
            initializeGpuIfNeeded()
        }

        override var isFlipped: Bool { true }

        override var wantsLayer: Bool {
            get { true }
            set {}
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                // Update scale factor when added to window
                currentScaleFactor = window?.backingScaleFactor ?? 1.0
                updateMetalLayerFrame()
                initializeGpuIfNeeded()
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            // Handle display change (e.g., moved to different monitor)
            if let newScale = window?.backingScaleFactor, newScale != currentScaleFactor {
                currentScaleFactor = newScale
                updateMetalLayerFrame()
                initializeGpuIfNeeded()
            }
        }
    #endif

    private func updateMetalLayerFrame() {
        guard metalLayer != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        metalLayer.frame = bounds
        metalLayer.contentsScale = currentScaleFactor

        let width = bounds.width * currentScaleFactor
        let height = bounds.height * currentScaleFactor
        if width > 0 && height > 0 {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }

        CATransaction.commit()
    }

    // MARK: - Cleanup

    @MainActor deinit {
        stopDisplayLink()
        renderState.shutdown()
    }
}

// MARK: - UIGestureRecognizerDelegate

#if canImport(UIKit)
extension WuiGpuSurface: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch and pan gestures to work together
        let isPinch = gestureRecognizer is UIPinchGestureRecognizer
            || otherGestureRecognizer is UIPinchGestureRecognizer
        let isPan = gestureRecognizer is UIPanGestureRecognizer
            || otherGestureRecognizer is UIPanGestureRecognizer

        return isPinch && isPan
    }
}
#endif
