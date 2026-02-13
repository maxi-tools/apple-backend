import CoreGraphics
import Foundation
import ImageIO

/// Decode encoded image bytes with Apple's platform codecs and return RGBA8 pixels.
///
/// Returns:
/// - `0` on success
/// - negative value on failure
@_cdecl("waterui_platform_decode_image_apple")
public func waterui_platform_decode_image_apple(
    _ dataPtr: UnsafePointer<UInt8>?,
    _ dataLen: Int,
    _ outPixels: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outWidth: UnsafeMutablePointer<UInt32>?,
    _ outHeight: UnsafeMutablePointer<UInt32>?,
    _ outLen: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard
        let dataPtr,
        dataLen > 0,
        let outPixels,
        let outWidth,
        let outHeight,
        let outLen
    else {
        return -1
    }

    let data = Data(bytes: dataPtr, count: dataLen) as CFData
    guard let source = CGImageSourceCreateWithData(data, nil) else {
        return -2
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return -3
    }

    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else {
        return -4
    }

    let bytesPerRow = width * 4
    let totalBytes = bytesPerRow * height
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        return -5
    }
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        return -6
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let rgbaData = context.data else {
        return -7
    }

    guard let raw = malloc(totalBytes) else {
        return -8
    }
    memcpy(raw, rgbaData, totalBytes)

    outPixels.pointee = raw.assumingMemoryBound(to: UInt8.self)
    outWidth.pointee = UInt32(width)
    outHeight.pointee = UInt32(height)
    outLen.pointee = totalBytes
    return 0
}
