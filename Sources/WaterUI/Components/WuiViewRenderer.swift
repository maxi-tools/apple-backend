import CWaterUI
import CoreGraphics
import Dispatch
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - View Renderer Installation

/// Installs the native view renderer into the environment.
///
/// This allows the preview system to capture views as RGBA pixels.
@MainActor
public func installViewRenderer(env: OpaquePointer?) {
    waterui_env_install_view_renderer(env, renderViewImpl)
}

/// Native implementation of ViewRenderFn.
///
/// Called by Rust to render a view to RGBA pixels.
/// Called synchronously from the main thread (via spawn_local in Rust).
private let renderViewImpl: ViewRenderFn = { viewPtr, size, callback in
    // Convert from CWaterUI.WuiSize to WaterUI.WuiSize
    let swiftSize = WuiSize(width: size.width, height: size.height)
    // Mark pointers as unsafe for crossing actor boundary
    nonisolated(unsafe) let unsafeViewPtr = viewPtr
    nonisolated(unsafe) let unsafeCallback = callback
    // Call synchronously - we're already on the main thread from spawn_local
    // Use assumeIsolated since we know we're on main thread but compiler can't verify
    MainActor.assumeIsolated {
        renderViewToRGBA(viewPtr: unsafeViewPtr, size: swiftSize, callback: unsafeCallback)
    }
}

/// Renders a view to RGBA pixels and calls the callback.
/// Called from DispatchQueue.main.async, so we're on the main thread.
@preconcurrency @MainActor
private func renderViewToRGBA(
    viewPtr: UnsafeMutableRawPointer?,
    size: WuiSize,
    callback: ViewRenderCallback
) {
    Logger.waterui.info("ViewRenderer: starting render, size=\(size.width)x\(size.height)")

    guard let viewPtr = viewPtr else {
        Logger.waterui.error("ViewRenderer: nil view pointer")
        // Call with empty data to signal error
        callback.call?(callback.data, nil, 0, 0, 0)
        return
    }

    guard let env = globalEnvironment else {
        Logger.waterui.error("ViewRenderer: no global environment")
        callback.call?(callback.data, nil, 0, 0, 0)
        return
    }

    Logger.waterui.info("ViewRenderer: globalEnvironment found, creating view")

    // Cast the pointer to AnyView opaque pointer
    let anyviewPtr = OpaquePointer(viewPtr)

    // Create the native view from the AnyView
    let view = WuiAnyView(anyview: anyviewPtr, env: env)

    Logger.waterui.info("ViewRenderer: WuiAnyView created, subviews=\(view.subviews.count)")

    // Get screen scale
    #if canImport(UIKit)
    let scale = UIScreen.main.scale
    #elseif canImport(AppKit)
    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    #endif

    // Proposed size (max bounds for layout)
    let proposedSize = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))

    // Render the view to RGBA, getting actual content size
    if let (rgbaData, actualWidth, actualHeight) = captureViewToRGBA(view: view, proposedSize: proposedSize, scale: scale) {
        rgbaData.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                callback.call?(callback.data, nil, 0, 0, 0)
                return
            }
            callback.call?(
                callback.data,
                ptr,
                UInt(buffer.count),
                UInt32(actualWidth),
                UInt32(actualHeight)
            )
        }
    } else {
        Logger.waterui.error("ViewRenderer: failed to capture view")
        callback.call?(callback.data, nil, 0, 0, 0)
    }
}

#if canImport(AppKit)
/// Bridge the synchronous preview capture path onto the real first-paint readiness flow.
@preconcurrency @MainActor
private func waitForPreviewFirstPaintReady(_ view: WuiAnyView) {
    view.readySynchronously()
}

@preconcurrency @MainActor
private func withPreviewGpuSurfaceCaptureMode<T>(
    in view: NSView,
    _ body: () -> T
) -> T {
    let surfaces = collectPreviewGpuSurfaces(in: view)
    for surface in surfaces {
        surface.beginExternalRendering()
        surface.beginCaptureSuppression()
    }
    defer {
        for surface in surfaces.reversed() {
            surface.endCaptureSuppression()
            surface.endExternalRendering()
        }
    }
    return body()
}

@preconcurrency @MainActor
private func collectPreviewGpuSurfaces(in view: NSView) -> [WuiGpuSurface] {
    var surfaces: [WuiGpuSurface] = []
    collectPreviewGpuSurfaces(in: view, into: &surfaces)
    return surfaces
}

@preconcurrency @MainActor
private func collectPreviewGpuSurfaces(in view: NSView, into surfaces: inout [WuiGpuSurface]) {
    if let surface = view as? WuiGpuSurface {
        surfaces.append(surface)
    }
    for subview in view.subviews {
        collectPreviewGpuSurfaces(in: subview, into: &surfaces)
    }
}
#endif

/// Captures a view to RGBA pixel data.
/// Returns the data along with actual pixel dimensions (width, height).
@preconcurrency @MainActor
private func captureViewToRGBA(
    view: WuiAnyView,
    proposedSize: CGSize,
    scale: CGFloat
) -> (Data, Int, Int)? {
    // Measure with the proposed size so stretchable views render correctly.
    #if canImport(UIKit)
    let measuredSize = view.sizeThatFits(proposedSize)
    #elseif canImport(AppKit)
    view.frame = CGRect(origin: .zero, size: proposedSize)
    view.layoutSubtreeIfNeeded()
    let measuredSize = view.fittingSize
    #endif

    func resolveDimension(_ measured: CGFloat, fallback: CGFloat) -> CGFloat {
        if measured.isFinite, measured > 0, measured != PlatformView.noIntrinsicMetric {
            return measured
        }
        let safeFallback = (fallback.isFinite && fallback > 0) ? fallback : 1
        return safeFallback
    }

    let actualSize = CGSize(
        width: resolveDimension(measuredSize.width, fallback: proposedSize.width),
        height: resolveDimension(measuredSize.height, fallback: proposedSize.height)
    )

    // Layout the view at actual content size
    view.frame = CGRect(origin: .zero, size: actualSize)

    #if canImport(UIKit)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    #elseif canImport(AppKit)
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    #endif

    Logger.waterui.info("ViewRenderer: proposedSize=\(proposedSize.width)x\(proposedSize.height), measuredSize=\(measuredSize.width)x\(measuredSize.height), actualSize=\(actualSize.width)x\(actualSize.height)")

    // Calculate pixel dimensions
    let width = Int(actualSize.width * scale)
    let height = Int(actualSize.height * scale)

    // Create RGBA bitmap context at actual content size
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixelData = Data(count: width * height * bytesPerPixel)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let context = pixelData.withUnsafeMutableBytes({ buffer -> CGContext? in
        CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
    }) else {
        Logger.waterui.error("ViewRenderer: failed to create CGContext")
        return nil
    }

    // Scale context for retina
    context.scaleBy(x: scale, y: scale)

    #if canImport(UIKit)
    // UIKit rendering
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: 0, y: actualSize.height)
    context.scaleBy(x: 1, y: -1)

    UIGraphicsPushContext(context)
    defer { UIGraphicsPopContext() }

    // Fill with white background first
    context.setFillColor(UIColor.white.cgColor)
    context.fill(CGRect(origin: .zero, size: actualSize))

    // Render the view hierarchy
    view.layer.render(in: context)

    // Draw GPU surfaces behind UIKit-rendered content (Metal layers are not captured by render(in:))
    context.saveGState()
    context.setBlendMode(.destinationOver)
    captureGpuSurfaces(in: view, rootView: view, to: context, scale: scale)
    context.restoreGState()

    #elseif canImport(AppKit)
    // AppKit rendering - headless capture using cacheDisplay

    // Resize view to actual content size
    view.frame = CGRect(origin: .zero, size: actualSize)
    view.layoutSubtreeIfNeeded()

    // Create an offscreen window (positioned far offscreen for headless rendering)
    let tempWindow = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: actualSize),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    tempWindow.backgroundColor = NSColor.white
    tempWindow.contentView = view
    tempWindow.isReleasedWhenClosed = false

    // Force layer-backing for proper rendering
    view.wantsLayer = true

    // Force layout
    view.layoutSubtreeIfNeeded()

    withPreviewGpuSurfaceCaptureMode(in: view) {
        // Display window (offscreen) to trigger rendering pipeline
        tempWindow.orderFrontRegardless()
        tempWindow.display()  // Force full display, not just if needed

        // Force text fields to draw their content
        forceTextFieldsToDisplay(in: view)

        // Drive the real first-paint readiness flow instead of sleeping blindly.
        waitForPreviewFirstPaintReady(view)

        // Capture using cacheDisplay for text rendering
        if let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmapRep)
            if let textImage = bitmapRep.cgImage {
                context.draw(textImage, in: CGRect(origin: .zero, size: actualSize))
            }
        }

        // Draw GPU surfaces behind AppKit-rendered content
        context.saveGState()
        context.setBlendMode(.destinationOver)
        captureGpuSurfaces(in: view, to: context, rootBounds: view.bounds, scale: scale)
        context.restoreGState()

        tempWindow.orderOut(nil as Any?)
    }
    #endif

    return (pixelData, width, height)
}

#if canImport(UIKit)
/// Recursively finds and captures all GPU surfaces in the view hierarchy.
@preconcurrency @MainActor
private func captureGpuSurfaces(
    in view: UIView,
    rootView: UIView,
    to context: CGContext,
    scale: CGFloat
) {
    if let gpuSurface = view as? WuiGpuSurface {
        let frameInRoot = view.convert(view.bounds, to: rootView)

        let pixelWidth = UInt32(frameInRoot.width * scale)
        let pixelHeight = UInt32(frameInRoot.height * scale)

        if pixelWidth > 0 && pixelHeight > 0 {
            let drawRect = CGRect(
                x: frameInRoot.origin.x,
                y: frameInRoot.origin.y,
                width: frameInRoot.width,
                height: frameInRoot.height
            )

            drawGpuSurface(
                gpuSurface: gpuSurface,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                drawRect: drawRect,
                context: context
            )
        } else {
            Logger.waterui.info("ViewRenderer: GPU surface has zero size, skipping")
        }
    }

    for subview in view.subviews {
        captureGpuSurfaces(in: subview, rootView: rootView, to: context, scale: scale)
    }
}
#endif

#if canImport(AppKit)
/// Recursively finds and captures all GPU surfaces in the view hierarchy.
@preconcurrency @MainActor
private func captureGpuSurfaces(
    in view: NSView,
    to context: CGContext,
    rootBounds: NSRect,
    scale: CGFloat
) {
    // Check if this view is a WuiGpuSurface
    if let gpuSurface = view as? WuiGpuSurface {
        // Get the frame in root view coordinates
        let frameInRoot = view.convert(view.bounds, to: view.window?.contentView)

        // Get pixel dimensions
        let pixelWidth = UInt32(frameInRoot.width * scale)
        let pixelHeight = UInt32(frameInRoot.height * scale)

        if pixelWidth > 0 && pixelHeight > 0 {
            let drawRect = CGRect(
                x: frameInRoot.origin.x,
                y: rootBounds.height - frameInRoot.origin.y - frameInRoot.height,
                width: frameInRoot.width,
                height: frameInRoot.height
            )

            drawGpuSurface(
                gpuSurface: gpuSurface,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                drawRect: drawRect,
                context: context
            )

            Logger.waterui.info("ViewRenderer: captured GPU surface \(pixelWidth)x\(pixelHeight) at \(NSStringFromRect(frameInRoot))")
        } else {
            Logger.waterui.info("ViewRenderer: GPU surface has zero size, skipping")
        }
    }

    // Recursively process subviews
    for subview in view.subviews {
        captureGpuSurfaces(in: subview, to: context, rootBounds: rootBounds, scale: scale)
    }
}

#endif

/// Draw a GPU surface into the given context.
private func drawGpuSurface(
    gpuSurface: WuiGpuSurface,
    pixelWidth: UInt32,
    pixelHeight: UInt32,
    drawRect: CGRect,
    context: CGContext
) {
    guard let device = MTLCreateSystemDefaultDevice() else {
        Logger.waterui.error("ViewRenderer: Failed to create Metal device for GPU capture")
        return
    }

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,  // Match GPU surface HDR format
        width: Int(pixelWidth),
        height: Int(pixelHeight),
        mipmapped: false
    )
    textureDescriptor.usage = [.renderTarget, .shaderRead]
    textureDescriptor.storageMode = .shared

    guard let captureTexture = device.makeTexture(descriptor: textureDescriptor) else {
        Logger.waterui.error("ViewRenderer: Failed to create capture texture")
        return
    }

    let rendered = gpuSurface.renderToMetalTexture(
        texture: captureTexture,
        width: pixelWidth,
        height: pixelHeight
    )

    guard rendered else {
        Logger.waterui.info("ViewRenderer: GPU surface render returned false")
        return
    }

    let bytesPerRowFloat = Int(pixelWidth) * 8
    var floatPixels = [UInt16](repeating: 0, count: Int(pixelWidth) * Int(pixelHeight) * 4)

    captureTexture.getBytes(
        &floatPixels,
        bytesPerRow: bytesPerRowFloat,
        from: MTLRegionMake2D(0, 0, Int(pixelWidth), Int(pixelHeight)),
        mipmapLevel: 0
    )

    var pixelBytes = [UInt8](repeating: 0, count: Int(pixelWidth) * Int(pixelHeight) * 4)
    for i in 0 ..< (Int(pixelWidth) * Int(pixelHeight)) {
        let r = float16ToFloat32(floatPixels[i * 4])
        let g = float16ToFloat32(floatPixels[i * 4 + 1])
        let b = float16ToFloat32(floatPixels[i * 4 + 2])
        let a = float16ToFloat32(floatPixels[i * 4 + 3])

        pixelBytes[i * 4] = UInt8(clamping: Int(r * 255))
        pixelBytes[i * 4 + 1] = UInt8(clamping: Int(g * 255))
        pixelBytes[i * 4 + 2] = UInt8(clamping: Int(b * 255))
        pixelBytes[i * 4 + 3] = UInt8(clamping: Int(a * 255))
    }

    let bytesPerRow = Int(pixelWidth) * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let dataProvider = CGDataProvider(data: Data(pixelBytes) as CFData),
       let cgImage = CGImage(
           width: Int(pixelWidth),
           height: Int(pixelHeight),
           bitsPerComponent: 8,
           bitsPerPixel: 32,
           bytesPerRow: bytesPerRow,
           space: colorSpace,
           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
           provider: dataProvider,
           decode: nil,
           shouldInterpolate: true,
           intent: .defaultIntent
       ) {
        context.saveGState()
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    }
}

/// Convert a half-precision float (UInt16) to single-precision float.
private func float16ToFloat32(_ half: UInt16) -> Float {
    let sign = (half >> 15) & 0x1
    let exponent = (half >> 10) & 0x1F
    let mantissa = half & 0x3FF

    if exponent == 0 {
        if mantissa == 0 {
            // Zero
            return sign == 0 ? 0.0 : -0.0
        } else {
            // Denormalized number
            let f = Float(mantissa) / Float(1 << 10) * pow(2.0, -14.0)
            return sign == 0 ? f : -f
        }
    } else if exponent == 31 {
        if mantissa == 0 {
            // Infinity
            return sign == 0 ? Float.infinity : -Float.infinity
        } else {
            // NaN
            return Float.nan
        }
    } else {
        // Normalized number
        let f = (1.0 + Float(mantissa) / Float(1 << 10)) * pow(2.0, Float(Int(exponent) - 15))
        return sign == 0 ? f : -f
    }
}

#if canImport(AppKit)
/// Ensure text fields render their content before capturing.
@preconcurrency @MainActor
private func forceTextFieldsToDisplay(in view: NSView) {
    if let textField = view as? NSTextField {
        textField.needsDisplay = true
        textField.displayIfNeeded()
    }

    for subview in view.subviews {
        forceTextFieldsToDisplay(in: subview)
    }
}
#endif
