import Foundation
import Metal

private typealias WaterKitVideoRenderFrameFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    UInt32,
    UInt32
) -> Bool

private typealias WaterKitVideoSetExternalRenderingFn = @convention(c) (
    UnsafeMutableRawPointer?,
    Bool
) -> Void

@_silgen_name("waterkit_video_apple_register_gpu_surface_host")
private func waterkitVideoAppleRegisterGpuSurfaceHost(
    _ hostId: UInt64,
    _ userData: UnsafeMutableRawPointer?,
    _ renderFrame: WaterKitVideoRenderFrameFn,
    _ setExternalRendering: WaterKitVideoSetExternalRenderingFn
)

@_silgen_name("waterkit_video_apple_unregister_gpu_surface_host")
private func waterkitVideoAppleUnregisterGpuSurfaceHost(_ hostId: UInt64)

private func wuiWaterKitVideoPictureInPictureRenderFrame(
    userData: UnsafeMutableRawPointer?,
    texturePtr: UnsafeMutableRawPointer?,
    width: UInt32,
    height: UInt32
) -> Bool {
    guard let userData, let texturePtr else {
        fatalError("waterkit-video Apple PiP callbacks require non-null user data and texture")
    }

    let bridge = Unmanaged<WuiWaterKitVideoPictureInPictureHostBridge>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let textureAddress = Int(bitPattern: texturePtr)
    return MainActor.assumeIsolated {
        bridge.renderFrame(
            texturePtr: UnsafeMutableRawPointer(bitPattern: textureAddress)!,
            width: width,
            height: height
        )
    }
}

private func wuiWaterKitVideoPictureInPictureSetExternalRendering(
    userData: UnsafeMutableRawPointer?,
    enabled: Bool
) {
    guard let userData else {
        fatalError("waterkit-video Apple PiP setExternalRendering callback requires user data")
    }

    let bridge = Unmanaged<WuiWaterKitVideoPictureInPictureHostBridge>
        .fromOpaque(userData)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        bridge.setExternalRendering(enabled)
    }
}

@MainActor
final class WuiWaterKitVideoPictureInPictureHostBridge {
    private let hostId: UInt64
    private weak var surface: WuiGpuSurface?

    init(hostId: UInt64, surface: WuiGpuSurface) {
        self.hostId = hostId
        self.surface = surface

        waterkitVideoAppleRegisterGpuSurfaceHost(
            hostId,
            Unmanaged.passUnretained(self).toOpaque(),
            wuiWaterKitVideoPictureInPictureRenderFrame,
            wuiWaterKitVideoPictureInPictureSetExternalRendering
        )
    }

    func renderFrame(
        texturePtr: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        guard let surface else { return false }
        let texture = Unmanaged<MTLTexture>.fromOpaque(texturePtr).takeUnretainedValue()
        return surface.renderToMetalTexture(texture: texture, width: width, height: height)
    }

    func setExternalRendering(_ enabled: Bool) {
        guard let surface else { return }
        if enabled {
            surface.beginExternalRendering()
        } else {
            surface.endExternalRendering()
        }
    }

    deinit {
        waterkitVideoAppleUnregisterGpuSurfaceHost(hostId)
        MainActor.assumeIsolated {
            surface?.endExternalRendering()
        }
    }
}
