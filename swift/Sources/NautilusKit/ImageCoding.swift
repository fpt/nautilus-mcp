import CoreGraphics
import Foundation
import NautilusBridge

/// PNG bytes in and out, without ImageIO.
///
/// Swift has ImageIO and cannot use it here: its codecs fault (SIGBUS,
/// `EXC_ARM_DA_ALIGN`, a jump to a poisoned `0xbad4007`) in any ordinary
/// compiled binary — encode and decode, PNG and TIFF alike — while working
/// inside Apple-signed hosts such as `xctest` and the `swift` interpreter. That
/// asymmetry is why no unit test can catch it, and why the failure is a process
/// crash rather than a thrown error.
///
/// What still works is everything else: `CGImage` built from raw bytes is pure
/// CoreGraphics, and Vision reads such an image happily. So compression is
/// delegated to the Rust core's `png` crate and CoreGraphics does the rest.
enum ImageCoding {
    /// A base64 PNG — as `android_observe` delivers one — to pixels.
    static func decode(base64: String) -> CGImage? {
        guard !base64.isEmpty, let raw = try? decodePngBase64(base64Png: base64) else {
            return nil
        }
        return cgImage(from: raw)
    }

    /// Wrap RGBA8 bytes as a `CGImage`.
    static func cgImage(from raw: RawImage) -> CGImage? {
        let width = Int(raw.width)
        let height = Int(raw.height)
        guard width > 0, height > 0, raw.rgba.count == width * height * 4 else { return nil }

        // CFDataCreate copies into storage CoreFoundation owns, so the provider
        // — and the image built on it — keep it alive for as long as they live.
        let copied: CFData? = raw.rgba.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return CFDataCreate(kCFAllocatorDefault, base, buffer.count)
        }
        guard let copied, let provider = CGDataProvider(data: copied) else { return nil }

        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A `CGImage` — from ScreenCaptureKit, or a crop — to a base64 PNG.
    ///
    /// The image is first redrawn into a known RGBA8 buffer: whatever layout
    /// the source used, the encoder is then handed exactly what it expects.
    static func encodeBase64(_ image: CGImage) -> String? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4

        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            // The pointer must stay valid for the whole draw, so the context
            // lives and dies inside this closure.
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        return try? encodePngBase64(
            image: RawImage(width: UInt32(width), height: UInt32(height), rgba: buffer))
    }
}
