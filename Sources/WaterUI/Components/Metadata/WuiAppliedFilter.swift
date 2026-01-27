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
import Foundation
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
    private var preRender: ((OpaquePointer, UInt32, UInt32) -> Void)?
    private var captureRenderer: CARenderer?
    private var captureQueue: MTLCommandQueue?
    private var captureQueueDevice: MTLDevice?

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

    func requestRender(preRender: ((OpaquePointer, UInt32, UInt32) -> Void)? = nil) {
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
        let storedPreRender = self.preRender
        lock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            let renderHook = preRender ?? storedPreRender
            if let renderHook {
                renderHook(state, width, height)
            }
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

    func setPreRender(_ hook: ((OpaquePointer, UInt32, UInt32) -> Void)?) {
        lock.lock()
        preRender = hook
        lock.unlock()
    }

    func renderNativeLayer(
        _ layer: CALayer,
        targetTexture: MTLTexture,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        guard width > 0, height > 0 else { return false }

        let device = targetTexture.device
        let queue: MTLCommandQueue?
        lock.lock()
        if captureQueue == nil || captureQueueDevice !== device {
            captureQueueDevice = device
            captureQueue = device.makeCommandQueue()
            captureRenderer = nil
        }
        queue = captureQueue
        lock.unlock()

        let renderer: CARenderer
        let colorSpace: CGColorSpace? = {
            switch targetTexture.pixelFormat {
            case .rgba16Float:
                return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            default:
                return CGColorSpace(name: CGColorSpace.sRGB)
            }
        }()

        if let existing = captureRenderer {
            renderer = existing
            renderer.setDestination(targetTexture)
        } else {
            var options: [String: Any] = [
                kCARendererColorSpace as String: colorSpace as Any,
            ]
            if let queue {
                options[kCARendererMetalCommandQueue as String] = queue
            }
            renderer = CARenderer(mtlTexture: targetTexture, options: options)
            captureRenderer = renderer
        }

        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let now = CACurrentMediaTime()
        renderer.beginFrame(atTime: now, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        if let queue, let commandBuffer = queue.makeCommandBuffer() {
            // Block until the CARenderer work completes so wgpu samples updated pixels.
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        return true
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
    private var captureTexture: MTLTexture?
    private var captureSize: CGSize = .zero
    private var capturePixelFormat: MTLPixelFormat = .invalid
    private var captureCommandQueue: MTLCommandQueue?
    private var activeGpuSurfaces: [ObjectIdentifier: WuiGpuSurface] = [:]
    private var overlayTexture: MTLTexture?
    private var overlaySize: CGSize = .zero
    private var compositePipeline: MTLRenderPipelineState?
    private var compositePipelineFormat: MTLPixelFormat = .invalid
    private var compositeSampler: MTLSamplerState?
    private var gpuSurfaceTextures: [ObjectIdentifier: MTLTexture] = [:]
    private var gpuSurfaceTextureSizes: [ObjectIdentifier: CGSize] = [:]
    private var gpuSurfaceHasContent: Set<ObjectIdentifier> = []

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
        #if canImport(UIKit)
            outputLayer.backgroundColor = UIColor.clear.cgColor
        #elseif canImport(AppKit)
            outputLayer.backgroundColor = NSColor.clear.cgColor
        #endif
        outputLayer.zPosition = 1
        outputLayer.pixelFormat = .rgba16Float
        outputLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        outputLayer.wantsExtendedDynamicRangeContent = true

        #if canImport(UIKit)
            layer.addSublayer(outputLayer)
        #elseif canImport(AppKit)
            if self.layer == nil {
                self.layer = CALayer()
            }
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.addSublayer(outputLayer)
        #endif
    }

    private func setupContentView() {
        contentView.translatesAutoresizingMaskIntoConstraints = true
        // Keep content in the view tree for layout/capture; output layer overlays it.
        addSubview(contentView)
        contentView.isHidden = true
        outputLayer.removeFromSuperlayer()
        #if canImport(UIKit)
            layer.addSublayer(outputLayer)
        #elseif canImport(AppKit)
            if self.layer == nil {
                self.layer = CALayer()
            }
            self.layer?.addSublayer(outputLayer)
        #endif

        setupCapturePipeline()
    }

    private func setupCapturePipeline() {
        renderState.setPreRender { [weak self] state, width, height in
            guard let self else { return }
            var captureTexture: MTLTexture?
            var overlayTexture: MTLTexture?
            var snapshots: [GpuSurfaceSnapshot] = []
            var device: MTLDevice?

            let mainBlock = {
                self.withVisibleContentForCapture {
                    self.prepareCaptureView(self.contentView)
                    guard let outputDevice = self.outputLayer.device else { return }
                    device = outputDevice
                    guard let texture = self.ensureCaptureTexture(
                        device: outputDevice,
                        width: width,
                        height: height
                    ) else {
                        return
                    }
                    captureTexture = texture

                    snapshots = self.collectGpuSurfaceSnapshots()
                    self.updateExternalGpuSurfaces(snapshots)
                    if snapshots.isEmpty {
                        self.clearTexture(texture, device: outputDevice)
                        guard let layer = self.resolveCaptureLayer(from: self.contentView) else { return }
                        _ = self.renderState.renderNativeLayer(
                            layer,
                            targetTexture: texture,
                            width: width,
                            height: height
                        )
                    } else {
                        guard let overlay = self.ensureOverlayTexture(
                            device: outputDevice,
                            width: width,
                            height: height
                        ) else {
                            return
                        }
                        overlayTexture = overlay
                        self.clearTexture(overlay, device: outputDevice)
                        self.withHiddenGpuSurfaces {
                            guard let layer = self.resolveCaptureLayer(from: self.contentView) else { return }
                            _ = self.renderState.renderNativeLayer(
                                layer,
                                targetTexture: overlay,
                                width: width,
                                height: height
                            )
                        }
                    }
                }
            }

            if Thread.isMainThread {
                mainBlock()
            } else {
                DispatchQueue.main.sync(execute: mainBlock)
            }

            guard let device, let captureTexture else { return }

            if !snapshots.isEmpty {
                self.renderGpuSurfaces(
                    snapshots,
                    into: captureTexture,
                    overlayTexture: overlayTexture,
                    device: device
                )
            }

            let texturePtr = Unmanaged.passUnretained(captureTexture).toOpaque()
            let ok = waterui_applied_filter_set_input(
                state,
                WuiInputType_MetalTexture,
                texturePtr,
                width,
                height
            )
            if !ok {
                Logger.waterui.error("[AppliedFilter] Failed to set input texture")
            }
        }
    }

    private func withVisibleContentForCapture(_ work: () -> Void) {
        #if canImport(UIKit)
            let wasHidden = contentView.isHidden
            let oldAlpha = contentView.alpha
            contentView.isHidden = false
            contentView.alpha = 1.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            work()
            CATransaction.commit()
            contentView.alpha = oldAlpha
            contentView.isHidden = wasHidden
        #elseif canImport(AppKit)
            let wasHidden = contentView.isHidden
            let oldAlpha = contentView.alphaValue
            contentView.isHidden = false
            contentView.alphaValue = 1.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            work()
            CATransaction.commit()
            contentView.alphaValue = oldAlpha
            contentView.isHidden = wasHidden
        #endif
    }

    private func prepareCaptureView(_ view: PlatformView) {
        #if canImport(AppKit)
            ensureLayerBacked(view)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
            updateLayerTree(view, scale: currentScaleFactor)
        #elseif canImport(UIKit)
            view.setNeedsLayout()
            view.layoutIfNeeded()
        #endif
    }

    #if canImport(AppKit)
    private func updateLayerTree(_ view: PlatformView, scale: CGFloat) {
        if let layer = view.layer {
            layer.contentsScale = scale
            layer.setNeedsLayout()
            layer.layoutIfNeeded()
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
        }

        for subview in view.subviews {
            if let platformView = subview as? PlatformView {
                updateLayerTree(platformView, scale: scale)
            }
        }
    }

    private func ensureLayerBacked(_ view: PlatformView) {
        if view.layer == nil {
            view.wantsLayer = true
        }
        for subview in view.subviews {
            if let platformView = subview as? PlatformView {
                ensureLayerBacked(platformView)
            }
        }
    }
    #endif

    private func resolveCaptureLayer(from view: PlatformView) -> CALayer? {
        guard let component = view as? WuiComponent else {
            return view.layer
        }

        if isMetadataComponent(component) {
            if let contentSubview = view.subviews.first(where: { $0 is WuiComponent }) as? PlatformView {
                return resolveCaptureLayer(from: contentSubview)
            }
        }

        #if canImport(AppKit)
            if view.layer == nil {
                view.wantsLayer = true
            }
        #endif

        #if canImport(UIKit)
            return view.layer
        #elseif canImport(AppKit)
            return view.layer
        #endif
    }

    private struct GpuSurfaceSnapshot {
        let surface: WuiGpuSurface
        let origin: MTLOrigin
        let size: MTLSize
    }

    private func collectGpuSurfaceSnapshots() -> [GpuSurfaceSnapshot] {
        var snapshots: [GpuSurfaceSnapshot] = []
        collectGpuSurfaceSnapshots(from: contentView, into: &snapshots)
        return snapshots
    }

    private func updateExternalGpuSurfaces(_ snapshots: [GpuSurfaceSnapshot]) {
        var next: [ObjectIdentifier: WuiGpuSurface] = [:]
        next.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let id = ObjectIdentifier(snapshot.surface)
            next[id] = snapshot.surface
        }

        for (id, surface) in activeGpuSurfaces where next[id] == nil {
            surface.endExternalRendering()
        }
        for (id, surface) in next where activeGpuSurfaces[id] == nil {
            surface.beginExternalRendering()
        }

        activeGpuSurfaces = next
    }

    private func collectGpuSurfaceSnapshots(from view: PlatformView, into snapshots: inout [GpuSurfaceSnapshot]) {
        if let surface = view as? WuiGpuSurface {
            let rect = surface.convert(surface.bounds, to: contentView)
            let scale = currentScaleFactor
            let originX = Int((rect.origin.x * scale).rounded(.down))
            let originY = Int((rect.origin.y * scale).rounded(.down))
            let width = Int((rect.size.width * scale).rounded(.up))
            let height = Int((rect.size.height * scale).rounded(.up))
            let captureWidth = Int(captureSize.width)
            let captureHeight = Int(captureSize.height)

            let clampedOriginX = max(0, originX)
            let clampedOriginY = max(0, originY)
            let maxWidth = min(width, captureWidth - clampedOriginX)
            let maxHeight = min(height, captureHeight - clampedOriginY)

            if maxWidth > 0, maxHeight > 0 {
                snapshots.append(GpuSurfaceSnapshot(
                    surface: surface,
                    origin: MTLOrigin(x: clampedOriginX, y: clampedOriginY, z: 0),
                    size: MTLSize(width: maxWidth, height: maxHeight, depth: 1)
                ))
            }
            return
        }

        for subview in view.subviews {
            if let platformView = subview as? PlatformView, platformView is WuiComponent {
                collectGpuSurfaceSnapshots(from: platformView, into: &snapshots)
            }
        }
    }

    private func withHiddenGpuSurfaces(_ work: () -> Void) {
        var surfaces: [WuiGpuSurface] = []
        collectGpuSurfaces(in: contentView, into: &surfaces)
        if surfaces.isEmpty {
            work()
            return
        }

        let hiddenStates = surfaces.map(\.isHidden)
        for surface in surfaces {
            surface.isHidden = true
        }
        work()
        for (surface, wasHidden) in zip(surfaces, hiddenStates) {
            surface.isHidden = wasHidden
        }
    }

    private func collectGpuSurfaces(in view: PlatformView, into surfaces: inout [WuiGpuSurface]) {
        if let surface = view as? WuiGpuSurface {
            surfaces.append(surface)
            return
        }

        for subview in view.subviews {
            if let platformView = subview as? PlatformView, platformView is WuiComponent {
                collectGpuSurfaces(in: platformView, into: &surfaces)
            }
        }
    }

    private func ensureCaptureTexture(
        device: MTLDevice,
        width: UInt32,
        height: UInt32
    ) -> MTLTexture? {
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        if let texture = captureTexture,
           captureSize.width == CGFloat(width),
           captureSize.height == CGFloat(height),
           capturePixelFormat == pixelFormat
        {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            Logger.waterui.error("[AppliedFilter] Failed to create capture texture")
            return nil
        }

        captureTexture = texture
        captureSize = CGSize(width: Int(width), height: Int(height))
        capturePixelFormat = pixelFormat
        return texture
    }

    private func ensureOverlayTexture(
        device: MTLDevice,
        width: UInt32,
        height: UInt32
    ) -> MTLTexture? {
        let pixelFormat = capturePixelFormat == .invalid ? .bgra8Unorm : capturePixelFormat
        if let texture = overlayTexture,
           overlaySize.width == CGFloat(width),
           overlaySize.height == CGFloat(height),
           texture.pixelFormat == pixelFormat
        {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared

        let texture = device.makeTexture(descriptor: descriptor)
        overlayTexture = texture
        overlaySize = CGSize(width: Int(width), height: Int(height))
        return texture
    }

    private func ensureSurfaceTexture(
        for surface: WuiGpuSurface,
        device: MTLDevice,
        width: UInt32,
        height: UInt32
    ) -> MTLTexture? {
        let key = ObjectIdentifier(surface)
        let size = CGSize(width: Int(width), height: Int(height))
        if let texture = gpuSurfaceTextures[key],
           gpuSurfaceTextureSizes[key] == size
        {
            return texture
        }

        let pixelFormat = capturePixelFormat == .invalid ? .bgra8Unorm : capturePixelFormat
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        gpuSurfaceTextures[key] = texture
        gpuSurfaceTextureSizes[key] = size
        gpuSurfaceHasContent.remove(key)
        return texture
    }

    private func ensureCommandQueue(device: MTLDevice) -> MTLCommandQueue? {
        if let queue = captureCommandQueue, queue.device === device {
            return queue
        }
        let queue = device.makeCommandQueue()
        captureCommandQueue = queue
        return queue
    }

    private func clearTexture(_ texture: MTLTexture, device: MTLDevice) {
        guard let queue = ensureCommandQueue(device: device) else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func renderGpuSurfaces(
        _ snapshots: [GpuSurfaceSnapshot],
        into captureTexture: MTLTexture,
        overlayTexture: MTLTexture?,
        device: MTLDevice
    ) {
        var rendered: [(snapshot: GpuSurfaceSnapshot, texture: MTLTexture)] = []
        rendered.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            let width = UInt32(snapshot.size.width)
            let height = UInt32(snapshot.size.height)
            guard let surfaceTexture = ensureSurfaceTexture(
                for: snapshot.surface,
                device: device,
                width: width,
                height: height
            ) else { continue }

            let renderedOk = snapshot.surface.renderToMetalTexture(
                texture: surfaceTexture,
                width: width,
                height: height
            )
            if renderedOk {
                gpuSurfaceHasContent.insert(ObjectIdentifier(snapshot.surface))
                rendered.append((snapshot, surfaceTexture))
            } else if gpuSurfaceHasContent.contains(ObjectIdentifier(snapshot.surface)) {
                rendered.append((snapshot, surfaceTexture))
            }
        }

        guard let queue = ensureCommandQueue(device: device),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            return
        }

        encodeClear(captureTexture, commandBuffer: commandBuffer)

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            for entry in rendered {
                blit.copy(
                    from: entry.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: .init(x: 0, y: 0, z: 0),
                    sourceSize: entry.snapshot.size,
                    to: captureTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: entry.snapshot.origin
                )
            }
            blit.endEncoding()
        }

        if let overlayTexture {
            encodeCompositeOverlay(
                overlayTexture,
                onto: captureTexture,
                commandBuffer: commandBuffer,
                device: device
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func encodeClear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }
    }

    private func encodeCompositeOverlay(
        _ overlayTexture: MTLTexture,
        onto captureTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        device: MTLDevice
    ) {
        guard let pipeline = ensureCompositePipeline(device: device, format: captureTexture.pixelFormat),
              let sampler = ensureCompositeSampler(device: device)
        else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = captureTexture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(overlayTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func ensureCompositePipeline(
        device: MTLDevice,
        format: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        if let pipeline = compositePipeline, compositePipelineFormat == format {
            return pipeline
        }

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
            float2 pos[3] = { {-1.0, -1.0}, {3.0, -1.0}, {-1.0, 3.0} };
            float2 uv[3] = { {0.0, 0.0}, {2.0, 0.0}, {0.0, 2.0} };
            VertexOut out;
            out.position = float4(pos[vertexID], 0.0, 1.0);
            out.uv = uv[vertexID];
            return out;
        }

        fragment float4 fragment_main(
            VertexOut in [[stage_in]],
            texture2d<float> overlayTexture [[texture(0)]],
            sampler overlaySampler [[sampler(0)]]
        ) {
            return overlayTexture.sample(overlaySampler, in.uv);
        }
        """

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let vertex = library.makeFunction(name: "vertex_main"),
                  let fragment = library.makeFunction(name: "fragment_main")
            else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            compositePipeline = pipeline
            compositePipelineFormat = format
            return pipeline
        } catch {
            Logger.waterui.error("[AppliedFilter] Failed to create composite pipeline")
            return nil
        }
    }

    private func ensureCompositeSampler(device: MTLDevice) -> MTLSamplerState? {
        if let sampler = compositeSampler {
            return sampler
        }

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: descriptor)
        compositeSampler = sampler
        return sampler
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
            contentView.setNeedsLayout()
            contentView.layoutIfNeeded()
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
            contentView.needsLayout = true
            contentView.layoutSubtreeIfNeeded()
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
        for (_, surface) in activeGpuSurfaces {
            surface.endExternalRendering()
        }
        activeGpuSurfaces.removeAll()
        stopDisplayLink()
        renderState.shutdown()
    }
}

// Type alias for the FFI struct
private typealias WuiAppliedFilter_Struct = CWaterUI.WuiAppliedFilter
