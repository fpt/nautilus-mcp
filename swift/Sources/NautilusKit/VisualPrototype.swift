import CoreGraphics
import NautilusBridge
import Foundation
import Vision

// ============================================================================
// ShapeSignature — the cheap stage
// ============================================================================

/// A 64x64 monochrome edge sketch of something on screen, normalized so it can
/// be correlated against a candidate window in a few thousand operations.
///
/// Why edges rather than the pixels themselves: a game button sits on a 3D
/// scene that is different every frame, its fill animates and catches light,
/// badges overlap it, and it rescales with resolution. Its *outline and rough
/// internal structure* survive all of that. Contrast-normalizing before taking
/// edges removes the lighting, and resampling to a fixed 64x64 removes the
/// scale.
public struct ShapeSignature: Sendable, Equatable {
    public static let size = 64

    /// Edge magnitude, 0-255, row-major. Kept so a prototype can be written out
    /// as a PNG and looked at — a matcher you cannot inspect is a matcher you
    /// cannot debug.
    public let raw: [UInt8]

    /// The same data mean-subtracted and L2-normalized, so `score` is a plain
    /// dot product and lands in -1...1 regardless of contrast.
    public let unit: [Float]

    init(raw: [UInt8]) {
        self.raw = raw
        var floats = raw.map { Float($0) }
        let mean = floats.reduce(0, +) / Float(floats.count)
        for index in floats.indices { floats[index] -= mean }
        let norm = sqrt(floats.reduce(0) { $0 + $1 * $1 })
        // A perfectly flat patch has no shape to speak of; leave it at zero so
        // it correlates with nothing rather than with everything.
        self.unit = norm > 1e-6 ? floats.map { $0 / norm } : [Float](repeating: 0, count: floats.count)
    }

    /// Normalized cross-correlation, -1...1. 1 is identical shape.
    public func score(against other: ShapeSignature) -> Double {
        var total: Float = 0
        for index in unit.indices { total += unit[index] * other.unit[index] }
        return Double(total)
    }

    public var isBlank: Bool { unit.allSatisfy { $0 == 0 } }
}

// MARK: - Building signatures

enum ShapeBuilder {
    /// Grayscale a CGImage into a `width x height` luminance buffer.
    ///
    /// One CoreGraphics draw. Everything downstream is array arithmetic, which
    /// is what keeps a sliding-window search affordable.
    static func luminance(of image: CGImage, width: Int, height: Int) -> [Float]? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        return (0..<(width * height)).map { index in
            let offset = index * 4
            // Rec. 601 luma; the exact weights matter far less than consistency.
            return 0.299 * Float(buffer[offset]) + 0.587 * Float(buffer[offset + 1])
                + 0.114 * Float(buffer[offset + 2])
        }
    }

    /// Sobel edge magnitude over a luminance buffer.
    static func edges(_ luma: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        guard width >= 3, height >= 3 else { return out }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let tl = luma[i - width - 1], t = luma[i - width], tr = luma[i - width + 1]
                let l = luma[i - 1], r = luma[i + 1]
                let bl = luma[i + width - 1], b = luma[i + width], br = luma[i + width + 1]
                let gx = (tr + 2 * r + br) - (tl + 2 * l + bl)
                let gy = (bl + 2 * b + br) - (tl + 2 * t + tr)
                out[i] = (gx * gx + gy * gy).squareRoot()
            }
        }
        return out
    }

    /// Stretch to 0-255 so contrast does not depend on how brightly the scene
    /// happened to be lit.
    static func normalize(_ values: [Float]) -> [UInt8] {
        guard let low = values.min(), let high = values.max(), high - low > 1e-6 else {
            return [UInt8](repeating: 0, count: values.count)
        }
        let span = high - low
        return values.map { UInt8(max(0, min(255, ((($0 - low) / span) * 255).rounded()))) }
    }

    /// The full pipeline for one crop: grayscale -> edges -> normalize -> 64x64.
    static func signature(of image: CGImage) -> ShapeSignature? {
        let n = ShapeSignature.size
        guard let luma = luminance(of: image, width: n, height: n) else { return nil }
        return ShapeSignature(raw: normalize(edges(luma, width: n, height: n)))
    }

    /// Resample a window of an already-computed **luminance** buffer into a
    /// 64x64 signature — no CoreGraphics, so a sliding search can do this
    /// thousands of times.
    ///
    /// It samples luminance and *then* takes edges, because that is the order
    /// `signature(of:)` uses. Taking edges first at full resolution and
    /// downsampling afterwards is not the same operation: on identical input
    /// the two agreed only to 0.66, which would have quietly weakened every
    /// match, since the template comes from one path and the candidates from
    /// the other.
    static func signature(
        fromLuma luma: [Float], width: Int, height: Int,
        x: Int, y: Int, w: Int, h: Int
    ) -> ShapeSignature? {
        let n = ShapeSignature.size
        guard w > 0, h > 0, x >= 0, y >= 0, x + w <= width, y + h <= height else { return nil }
        var window = [Float](repeating: 0, count: n * n)
        for ty in 0..<n {
            let sy = y + (ty * h) / n
            for tx in 0..<n {
                let sx = x + (tx * w) / n
                window[ty * n + tx] = luma[sy * width + sx]
            }
        }
        return ShapeSignature(raw: normalize(edges(window, width: n, height: n)))
    }
}

// ============================================================================
// Prototype — what a learned element looks like
// ============================================================================

/// One appearance of a learned element.
public struct PrototypeSample: Codable, Sendable {
    /// 64x64 edge sketch, base64 of the raw bytes.
    public var shape: String
    /// An archived `VNFeaturePrintObservation`, base64. Absent if Vision
    /// refused the crop.
    public var featurePrint: String?
    /// Aspect ratio (w/h) of the crop this came from.
    public var aspect: Double
    /// Size of the element **relative to the whole frame** when it was learned.
    /// A search sweeps around this rather than guessing, because an element's
    /// size relative to the screen is stable — guessing from the search
    /// region's own width fails as soon as that region is an odd shape.
    public var width: Double?
    public var height: Double?
    /// Where on the frame it was when taught. Lets a maintenance check ask
    /// "has this control moved?", which the search prior cannot answer — the
    /// prior is a padded box and gets clamped at the frame edge, so its centre
    /// drifts from the real one near a corner.
    public var centerX: Double?
    public var centerY: Double?
    public var learnedAt: String
    /// What the element was reading when it was learned — provenance, not a
    /// matching key.
    public var note: String?

    var signature: ShapeSignature? {
        guard let data = Data(base64Encoded: shape),
            data.count == ShapeSignature.size * ShapeSignature.size
        else { return nil }
        return ShapeSignature(raw: [UInt8](data))
    }
}

/// A learned UI element: what it means, what it looks like, and where to expect it.
///
/// Holds several positives, because the same button is drawn differently as the
/// scene behind it changes — and hard negatives, because a game's icons
/// resemble each other and "similar enough" is not the same as "the right one".
public struct Prototype: Codable, Sendable {
    public var name: String
    /// The text that identified it during exploration, e.g. `進軍`. Recorded so
    /// a human can tell what this is; matching never reads it.
    public var semantic: String?
    public var kind: String?
    public var positives: [PrototypeSample]
    public var negatives: [PrototypeSample]
    /// Where this element usually appears. Searching here instead of the whole
    /// screen is most of what makes matching both fast and accurate.
    public var searchPrior: NormRectCodable?

    public init(
        name: String, semantic: String? = nil, kind: String? = nil,
        positives: [PrototypeSample] = [], negatives: [PrototypeSample] = [],
        searchPrior: NormRectCodable? = nil
    ) {
        self.name = name
        self.semantic = semantic
        self.kind = kind
        self.positives = positives
        self.negatives = negatives
        self.searchPrior = searchPrior
    }

    /// Median aspect of the positives — the window shape a search should try.
    public var aspect: Double {
        let all = positives.map(\.aspect).sorted()
        guard !all.isEmpty else { return 1 }
        return all[all.count / 2]
    }

    /// Median on-screen width relative to the frame, if any sample recorded it.
    public var frameWidth: Double? {
        let all = positives.compactMap(\.width).filter { $0 > 0 }.sorted()
        guard !all.isEmpty else { return nil }
        return all[all.count / 2]
    }

    /// Smallest and largest on-screen width across the positives.
    ///
    /// A map sprite is drawn at whatever the current zoom dictates, so the same
    /// node can be taught at very different sizes. Sweeping between the extremes
    /// (widened at both ends) means learning one node at two zoom levels covers
    /// everything in between, instead of a median that suits neither.
    public var frameWidthRange: (low: Double, high: Double)? {
        let all = positives.compactMap(\.width).filter { $0 > 0 }.sorted()
        guard let low = all.first, let high = all.last else { return nil }
        return (low, high)
    }

    /// Median position it was taught at, if recorded.
    public var learnedCenter: (x: Double, y: Double)? {
        let xs = positives.compactMap(\.centerX).sorted()
        let ys = positives.compactMap(\.centerY).sorted()
        guard !xs.isEmpty, !ys.isEmpty else { return nil }
        return (xs[xs.count / 2], ys[ys.count / 2])
    }
}

/// `NormRect` is not `Codable` (it is the wire type); this is its stored twin.
public struct NormRectCodable: Codable, Sendable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double
    public init(_ rect: NormRect) {
        x1 = rect.x1
        y1 = rect.y1
        x2 = rect.x2
        y2 = rect.y2
    }
    public var rect: NormRect { NormRect(x1: x1, y1: y1, x2: x2, y2: y2) }
}

// ============================================================================
// Feature prints
// ============================================================================

enum FeaturePrint {
    /// Apple's image-similarity descriptor. Measured on synthetic buttons: the
    /// same button rescaled scores 0.19, two different buttons about 1.0 — a
    /// five-fold separation, and scale-invariant.
    ///
    /// (`VNClassifyImageRequest` is the wrong API for this: asked about a UI
    /// button it answers "blue_sky", because it classifies natural images into
    /// a fixed taxonomy and knows nothing of an application's widgets.)
    static func compute(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        return request.results?.first as? VNFeaturePrintObservation
    }

    static func encode(_ observation: VNFeaturePrintObservation) -> String? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
            .base64EncodedString()
    }

    static func decode(_ base64: String) -> VNFeaturePrintObservation? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Distance, lower is more alike. `nil` when the two cannot be compared.
    static func distance(
        _ lhs: VNFeaturePrintObservation, _ rhs: VNFeaturePrintObservation
    ) -> Double? {
        var value = Float(0)
        do {
            try lhs.computeDistance(&value, to: rhs)
        } catch {
            return nil
        }
        return Double(value)
    }
}

// ============================================================================
// Store
// ============================================================================

/// Prototypes on disk, grouped into sets — one set per application.
///
/// Layout, under the store root:
/// ```
/// farlight_cod/march_button/prototype.json
/// farlight_cod/march_button/shape-001.png     <- the 64x64 sketch, viewable
/// farlight_cod/march_button/sample-001.png    <- the crop it came from
/// ```
/// The PNGs are written for inspection; matching reads only the JSON.
@MainActor
public final class PrototypeStore {
    public let root: URL
    private var cache: [String: Prototype] = [:]

    public init(root: URL) {
        self.root = root
    }

    /// `farlight_cod/march_button` -> that directory. Rejects anything that
    /// would climb out of the store.
    func directory(for name: String) throws -> URL {
        guard !name.hasPrefix("/"), !name.hasSuffix("/"), !name.contains("//") else {
            throw ToolFailure(
                "bad prototype name \(name.debugDescription); it must be `set/name`, not a path")
        }
        let parts = name.split(separator: "/").map(String.init)
        guard (1...2).contains(parts.count),
            parts.allSatisfy({ part in
                !part.isEmpty && part != "." && part != ".."
                    && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            })
        else {
            throw ToolFailure(
                "bad prototype name \(name.debugDescription); use `set/name` with letters, "
                    + "digits, _ or -")
        }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    public func load(_ name: String) throws -> Prototype {
        if let cached = cache[name] { return cached }
        let file = try directory(for: name).appendingPathComponent("prototype.json")
        guard let data = try? Data(contentsOf: file) else {
            let known = (try? list().joined(separator: ", ")) ?? ""
            throw ToolFailure(
                known.isEmpty
                    ? "no prototype \(name); none have been learned yet — use visual_learn"
                    : "no prototype \(name); known: \(known)")
        }
        let prototype = try JSONDecoder().decode(Prototype.self, from: data)
        cache[name] = prototype
        return prototype
    }

    public func save(_ prototype: Prototype) throws {
        let directory = try directory(for: prototype.name)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prototype).write(
            to: directory.appendingPathComponent("prototype.json"))
        cache[prototype.name] = prototype
    }

    /// Every prototype in the store, as `set/name`.
    public func list() throws -> [String] {
        let manager = FileManager.default
        guard let sets = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }
        var names: [String] = []
        for set in sets.sorted() {
            let setURL = root.appendingPathComponent(set)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: setURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                let entries = try? manager.contentsOfDirectory(atPath: setURL.path)
            else { continue }
            for entry in entries.sorted()
            where manager.fileExists(
                atPath: setURL.appendingPathComponent(entry)
                    .appendingPathComponent("prototype.json").path)
            {
                names.append("\(set)/\(entry)")
            }
        }
        return names
    }

    /// Write a PNG beside the prototype so it can be looked at.
    ///
    /// Goes through the Rust encoder like everything else — ImageIO is not
    /// usable here (see `ImageCoding`).
    @discardableResult
    func writePNG(_ image: CGImage, named file: String, for name: String) -> URL? {
        guard let base64 = ImageCoding.encodeBase64(image),
            let data = Data(base64Encoded: base64),
            let directory = try? directory(for: name)
        else { return nil }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file)
        return (try? data.write(to: url)) == nil ? nil : url
    }

    /// Render a signature as a viewable grayscale image.
    static func image(of signature: ShapeSignature) -> CGImage? {
        let n = ShapeSignature.size
        var rgba = [UInt8](repeating: 255, count: n * n * 4)
        for index in 0..<(n * n) {
            let value = signature.raw[index]
            rgba[index * 4] = value
            rgba[index * 4 + 1] = value
            rgba[index * 4 + 2] = value
        }
        return ImageCoding.cgImage(
            from: RawImage(width: UInt32(n), height: UInt32(n), rgba: rgba))
    }
}
