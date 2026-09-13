import CoreGraphics
import Foundation

/// A rectangle in **root-frame normalized coordinates**, top-left origin.
///
/// The single most important convention here: every box this server hands out
/// — an OCR hit, a detected region, a changed area — is expressed against the
/// *original captured frame*, never against whatever crop it was found in.
///
/// The alternative rots immediately. OCR a crop of the bottom-right corner and
/// return `[0.3, 0.2, 0.7, 0.8]`, and nobody downstream can say whether that is
/// crop space or screen space; feed it to a tap and the tap lands somewhere
/// else entirely. Because these are always root coordinates, and Android input
/// is already normalized against the same frame, `ocr → bbox → tap` composes
/// with no conversion step at all.
public struct NormRect: Sendable, Hashable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        // Tolerate either corner order; a caller that types the corners
        // backwards means the region, not an empty one.
        self.x1 = min(x1, x2)
        self.y1 = min(y1, y2)
        self.x2 = max(x1, x2)
        self.y2 = max(y1, y2)
    }

    public static let full = NormRect(x1: 0, y1: 0, x2: 1, y2: 1)

    public var width: Double { x2 - x1 }
    public var height: Double { y2 - y1 }
    public var centerX: Double { (x1 + x2) / 2 }
    public var centerY: Double { (y1 + y2) / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func clamped() -> NormRect {
        NormRect(
            x1: min(max(x1, 0), 1), y1: min(max(y1, 0), 1),
            x2: min(max(x2, 0), 1), y2: min(max(y2, 0), 1))
    }

    /// Map a rect expressed in *this* rect's local 0-1 space into the space
    /// this rect itself lives in. Composing these is what carries a hit found
    /// in a crop of a crop back to root coordinates.
    public func project(_ local: NormRect) -> NormRect {
        NormRect(
            x1: x1 + local.x1 * width,
            y1: y1 + local.y1 * height,
            x2: x1 + local.x2 * width,
            y2: y1 + local.y2 * height)
    }

    /// The inverse: express a rect from the outer space in this rect's local
    /// 0-1 space. `nil` when this rect has no area to divide by.
    public func localize(_ outer: NormRect) -> NormRect? {
        guard width > 0, height > 0 else { return nil }
        return NormRect(
            x1: (outer.x1 - x1) / width,
            y1: (outer.y1 - y1) / height,
            x2: (outer.x2 - x1) / width,
            y2: (outer.y2 - y1) / height)
    }

    /// `{"x1":…,"y1":…,"x2":…,"y2":…}`, rounded to a sane number of places —
    /// a screen is not addressable to fifteen decimals and the noise is pure
    /// token cost.
    public var json: JSONValue {
        func r(_ v: Double) -> JSONValue { .number((v * 10000).rounded() / 10000) }
        return .object(["x1": r(x1), "y1": r(y1), "x2": r(x2), "y2": r(y2)])
    }

    /// Parse `{x1,y1,x2,y2}`, or the `{x,y,w,h}` spelling.
    public static func from(_ value: JSONValue?) -> NormRect? {
        guard let o = value?.objectValue else { return nil }
        if let x1 = o["x1"]?.doubleValue, let y1 = o["y1"]?.doubleValue,
            let x2 = o["x2"]?.doubleValue, let y2 = o["y2"]?.doubleValue
        {
            return NormRect(x1: x1, y1: y1, x2: x2, y2: y2)
        }
        if let x = o["x"]?.doubleValue, let y = o["y"]?.doubleValue,
            let w = o["w"]?.doubleValue, let h = o["h"]?.doubleValue
        {
            return NormRect(x1: x, y1: y, x2: x + w, y2: y + h)
        }
        return nil
    }

    /// Schema for a region argument, shared by every tool that takes one.
    public static var schema: JSONValue {
        .object([
            "type": .string("object"),
            "description": .string(
                "A rectangle in frame-normalized 0.0-1.0 coordinates, top-left origin. Always "
                    + "relative to the whole original frame, never to a crop."),
            "properties": .object([
                "x1": .numberProperty("Left edge.", minimum: 0, maximum: 1),
                "y1": .numberProperty("Top edge.", minimum: 0, maximum: 1),
                "x2": .numberProperty("Right edge.", minimum: 0, maximum: 1),
                "y2": .numberProperty("Bottom edge.", minimum: 0, maximum: 1),
            ]),
            "required": .array([.string("x1"), .string("y1"), .string("x2"), .string("y2")]),
        ])
    }
}

/// A candidate area worth looking at, found by `image_regions`.
///
/// Deliberately **not** semantic. Vision says *where* something interesting is
/// and roughly what shape it takes; deciding that it is a Barracks or an
/// Upgrade button is the caller's job, via OCR or its own eyes. A server that
/// answered "barracks" would be guessing about a game it knows nothing about,
/// and would stop the caller looking for itself.
public struct Region: Sendable, Hashable {
    public enum Kind: String, Sendable {
        /// Vision found text here — worth an OCR.
        case textLike = "text_like"
        /// A rectangular shape: a button, a panel, a card.
        case rectangle
        /// Salient without being either — an icon, a unit, a highlight.
        case salient
    }

    public let id: String
    public let bbox: NormRect
    public let kind: Kind
    public let confidence: Double

    public var json: JSONValue {
        .object([
            "id": .string(id),
            "bbox": bbox.json,
            "kind": .string(kind.rawValue),
            "confidence": .number((confidence * 100).rounded() / 100),
        ])
    }
}

/// One captured image, addressable by id.
///
/// A crop is also a Frame, which is what lets `crop → regions → crop → ocr`
/// nest without ever losing the root coordinate system: `originRect` records
/// where this image sits in the root frame, so anything found inside it
/// projects straight back.
public final class Frame {
    public let id: String
    public let image: CGImage
    /// Where the image came from, e.g. `android` or `macos:Safari`.
    public let source: String
    public let capturedAt: Date
    /// This image's placement within the root frame, in root coordinates.
    /// `.full` for a fresh capture.
    public let originRect: NormRect
    /// The originally captured frame this descends from — itself, if captured.
    public let rootId: String
    public private(set) var regions: [Region] = []

    init(
        id: String, image: CGImage, source: String, originRect: NormRect, rootId: String
    ) {
        self.id = id
        self.image = image
        self.source = source
        self.capturedAt = Date()
        self.originRect = originRect
        self.rootId = rootId
    }

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }
    public var isCrop: Bool { originRect != .full }

    /// Carry a rect found in this image (local 0-1) up into root coordinates.
    public func toRoot(_ local: NormRect) -> NormRect {
        originRect.project(local)
    }

    /// Bring a root-coordinate rect down into this image's local 0-1 space.
    public func toLocal(_ root: NormRect) -> NormRect? {
        originRect.localize(root)
    }

    /// Cut out a root-coordinate rect as pixels. `nil` when it does not overlap
    /// this image.
    public func pixels(in root: NormRect) -> CGImage? {
        guard let local = toLocal(root)?.clamped(), !local.isEmpty else { return nil }
        let rect = CGRect(
            x: (local.x1 * Double(image.width)).rounded(.down),
            y: (local.y1 * Double(image.height)).rounded(.down),
            width: max(1, (local.width * Double(image.width)).rounded()),
            height: max(1, (local.height * Double(image.height)).rounded()))
        return image.cropping(to: rect)
    }

    public func region(_ id: String) -> Region? {
        regions.first { $0.id == id }
    }

    /// Replace this frame's regions. Ids restart at r1 per frame, so
    /// `(frame_id, region_id)` is the address — `r3` alone means nothing.
    func setRegions(_ boxes: [(NormRect, Region.Kind, Double)]) -> [Region] {
        regions = boxes.enumerated().map { index, box in
            Region(id: "r\(index + 1)", bbox: box.0, kind: box.1, confidence: box.2)
        }
        return regions
    }

    public var summary: String {
        let size = "\(pixelWidth)x\(pixelHeight)"
        return isCrop
            ? "\(id) (crop of \(rootId), \(size))" : "\(id) (\(source), \(size))"
    }
}

/// The last few frames, so an agent can observe once and then crop, OCR and
/// diff without pushing the image back across the protocol each time.
///
/// A screenshot of a game is over a megabyte of base64. `observe → regions →
/// crop → ocr → tap` would otherwise carry that four times for one decision.
/// Bounded, because frames are large and only the recent past is useful: the
/// oldest is dropped once `capacity` is reached, and a caller that names an
/// evicted frame is told so rather than handed a wrong image.
@MainActor
public final class FrameStore {
    public static let defaultCapacity = 8

    private var frames: [Frame] = []
    private var nextFrameNumber = 1
    public let capacity: Int

    public init(capacity: Int = FrameStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var latest: Frame? { frames.last }
    public var count: Int { frames.count }
    public var ids: [String] { frames.map(\.id) }

    @discardableResult
    public func register(image: CGImage, source: String) -> Frame {
        // A freshly captured frame is its own root and covers itself entirely.
        let id = nextId()
        let frame = Frame(
            id: id, image: image, source: source, originRect: .full, rootId: id)
        append(frame)
        return frame
    }

    /// Record a crop as a frame in its own right, remembering where it sits.
    @discardableResult
    public func registerCrop(of parent: Frame, root: NormRect, image: CGImage) -> Frame {
        let frame = Frame(
            id: nextId(), image: image, source: parent.source, originRect: root,
            rootId: parent.rootId)
        append(frame)
        return frame
    }

    /// Look up a frame. A `nil` or empty id means the most recent one, so the
    /// common `observe` then `ocr` sequence needs no bookkeeping.
    public func frame(_ id: String?) -> Frame? {
        guard let id, !id.isEmpty else { return latest }
        return frames.first { $0.id == id }
    }

    /// Resolve a frame or explain what went wrong, naming what is available —
    /// an evicted id is otherwise indistinguishable from a typo.
    public func require(_ id: String?) throws -> Frame {
        if let frame = frame(id) { return frame }
        guard !frames.isEmpty else {
            throw ToolFailure(
                "no frames captured yet — call android_observe or macos_capture_window first")
        }
        throw ToolFailure(
            "no frame \(id ?? "?"); the store holds \(ids.joined(separator: ", ")) "
                + "(only the last \(capacity) are kept)")
    }

    private func append(_ frame: Frame) {
        frames.append(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
    }

    private func nextId() -> String {
        defer { nextFrameNumber += 1 }
        return "f\(nextFrameNumber)"
    }
}
