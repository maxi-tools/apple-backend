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
/// Uses nonisolated(unsafe) locals for C FFI pointer safety.
private let renderViewImpl: ViewRenderFn = { viewPtr, size, callback in
    // Convert from CWaterUI.WuiSize to WaterUI.WuiSize
    let swiftSize = WuiSize(width: size.width, height: size.height)
    // Copy C pointers to nonisolated(unsafe) locals for safe transfer across isolation boundary
    nonisolated(unsafe) let unsafeViewPtr = viewPtr
    nonisolated(unsafe) let unsafeCallback = callback
    // Dispatch to main queue for view operations
    DispatchQueue.main.async {
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

/// Captures a view to RGBA pixel data.
/// Returns the data along with actual pixel dimensions (width, height).
@preconcurrency @MainActor
private func captureViewToRGBA(
    view: PlatformView,
    proposedSize: CGSize,
    scale: CGFloat
) -> (Data, Int, Int)? {
    // Get actual content size from intrinsicContentSize
    let actualSize = view.intrinsicContentSize

    // Layout the view at actual content size
    view.frame = CGRect(origin: .zero, size: actualSize)

    #if canImport(UIKit)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    #elseif canImport(AppKit)
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    #endif

    Logger.waterui.info("ViewRenderer: proposedSize=\(proposedSize.width)x\(proposedSize.height), actualSize=\(actualSize.width)x\(actualSize.height)")

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
    UIGraphicsPushContext(context)
    defer { UIGraphicsPopContext() }

    // Fill with white background first
    context.setFillColor(UIColor.white.cgColor)
    context.fill(CGRect(origin: .zero, size: actualSize))

    // Render the view hierarchy
    view.layer.render(in: context)

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
    tempWindow.backgroundColor = .white
    tempWindow.contentView = view
    tempWindow.isReleasedWhenClosed = false

    // Force layer-backing for proper rendering
    view.wantsLayer = true

    // Force layout
    view.layoutSubtreeIfNeeded()

    // Display window (offscreen) to trigger rendering pipeline
    tempWindow.orderFrontRegardless()
    tempWindow.displayIfNeeded()

    // Wait for GPU surfaces to render their first frame
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

    // Capture using cacheDisplay for text rendering
    if let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmapRep)
        if let textImage = bitmapRep.cgImage {
            context.draw(textImage, in: CGRect(origin: .zero, size: actualSize))
        }
    }

    // Find and capture GPU surfaces manually
    captureGpuSurfaces(in: view, to: context, rootBounds: view.bounds, scale: scale)

    // Clean up
    tempWindow.orderOut(nil)
    #endif

    return (pixelData, width, height)
}

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

        guard pixelWidth > 0 && pixelHeight > 0 else {
            Logger.waterui.info("ViewRenderer: GPU surface has zero size, skipping")
            for subview in view.subviews {
                captureGpuSurfaces(in: subview, to: context, rootBounds: rootBounds, scale: scale)
            }
            return
        }

        // Create an offscreen texture to render to
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.waterui.error("ViewRenderer: Failed to create Metal device for GPU capture")
            for subview in view.subviews {
                captureGpuSurfaces(in: subview, to: context, rootBounds: rootBounds, scale: scale)
            }
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
            for subview in view.subviews {
                captureGpuSurfaces(in: subview, to: context, rootBounds: rootBounds, scale: scale)
            }
            return
        }

        // Render the GPU surface to our capture texture
        let rendered = gpuSurface.renderToMetalTexture(
            texture: captureTexture,
            width: pixelWidth,
            height: pixelHeight
        )

        if rendered {
            // Read back the texture data (rgba16Float = 8 bytes per pixel)
            let bytesPerRowFloat = Int(pixelWidth) * 8
            var floatPixels = [UInt16](repeating: 0, count: Int(pixelWidth) * Int(pixelHeight) * 4)

            captureTexture.getBytes(
                &floatPixels,
                bytesPerRow: bytesPerRowFloat,
                from: MTLRegionMake2D(0, 0, Int(pixelWidth), Int(pixelHeight)),
                mipmapLevel: 0
            )

            // Convert float16 to uint8
            var pixelBytes = [UInt8](repeating: 0, count: Int(pixelWidth) * Int(pixelHeight) * 4)
            for i in 0..<(Int(pixelWidth) * Int(pixelHeight)) {
                let r = float16ToFloat32(floatPixels[i * 4])
                let g = float16ToFloat32(floatPixels[i * 4 + 1])
                let b = float16ToFloat32(floatPixels[i * 4 + 2])
                let a = float16ToFloat32(floatPixels[i * 4 + 3])

                pixelBytes[i * 4] = UInt8(clamping: Int(r * 255))
                pixelBytes[i * 4 + 1] = UInt8(clamping: Int(g * 255))
                pixelBytes[i * 4 + 2] = UInt8(clamping: Int(b * 255))
                pixelBytes[i * 4 + 3] = UInt8(clamping: Int(a * 255))
            }

            // Create CGImage from pixel data
            let bytesPerRow = Int(pixelWidth) * 4
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let dataProvider = CGDataProvider(data: Data(pixelBytes) as CFData) {
                if let cgImage = CGImage(
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
                    // Draw the GPU surface content at its frame position
                    context.saveGState()
                    let drawRect = CGRect(
                        x: frameInRoot.origin.x,
                        y: rootBounds.height - frameInRoot.origin.y - frameInRoot.height,
                        width: frameInRoot.width,
                        height: frameInRoot.height
                    )
                    context.draw(cgImage, in: drawRect)
                    context.restoreGState()

                    Logger.waterui.info("ViewRenderer: captured GPU surface \(pixelWidth)x\(pixelHeight) at \(NSStringFromRect(frameInRoot))")
                }
            }
        } else {
            Logger.waterui.info("ViewRenderer: GPU surface render returned false")
        }
    }

    // Recursively process subviews
    for subview in view.subviews {
        captureGpuSurfaces(in: subview, to: context, rootBounds: rootBounds, scale: scale)
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
#endif
