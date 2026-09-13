import CoreGraphics
import Foundation
import ScreenCapture
import Vision

/// Shared argument handling for the tools that address a cached frame.
///
/// Every one of them takes an optional `frame_id` (defaulting to the most
/// recent capture) and an optional `region` in root coordinates.
enum FrameArgs {
    static var frameIdProperty: JSONValue {
        .property(
            "string",
            "Frame to work on, from android_observe or macos_capture_window. Omit for the most "
                + "recent frame.")
    }

    /// Resolve `frame_id`, then `region` or `region_id` into a root-coordinate
    /// rect. `nil` rect means the whole frame.
    @MainActor
    static func resolve(
        _ args: [String: JSONValue], in store: FrameStore
    ) throws -> (frame: Frame, area: NormRect?) {
        let frame = try store.require(args.optionalString("frame_id"))
        if let regionId = args.optionalString("region_id") {
            guard let region = frame.region(regionId) else {
                let known = frame.regions.map(\.id).joined(separator: ", ")
                throw ToolFailure(
                    known.isEmpty
                        ? "frame \(frame.id) has no regions yet — call image_regions on it first"
                        : "no region \(regionId) on frame \(frame.id); it has \(known)")
            }
            return (frame, region.bbox)
        }
        return (frame, NormRect.from(args["region"]))
    }
}

// MARK: - image_ocr

/// Read text, with every box in root coordinates.
@MainActor
public final class ImageOCRTool: MCPTool {
    private let store: FrameStore
    public init(store: FrameStore) { self.store = store }

    public var name: String { "image_ocr" }
    public var description: String {
        "Read the text in a captured frame and return each string with its bounding box. Boxes "
            + "come back in whole-frame 0.0-1.0 coordinates even when you OCR a sub-region, so a "
            + "box can be handed straight to android_tap without converting anything. Narrowing "
            + "to a region is both faster and far more accurate on a busy screen."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "frame_id": FrameArgs.frameIdProperty,
            "region": NormRect.schema,
            "region_id": .property("string", "A region id from image_regions, instead of `region`."),
            "languages": .object([
                "type": .string("array"),
                "description": .string("Language hints, e.g. [\"en-US\",\"ja\"]. Default both."),
                "items": .object(["type": .string("string")]),
            ]),
            "min_confidence": .numberProperty(
                "Drop results below this confidence (default 0).", minimum: 0, maximum: 1),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let (frame, area) = try FrameArgs.resolve(arguments, in: store)
        let target = area ?? .full

        guard let pixels = frame.pixels(in: target) else {
            throw ToolFailure("that region does not overlap frame \(frame.id)")
        }
        var languages = ["en-US", "ja"]
        if case .array(let list)? = arguments["languages"] {
            let parsed = list.compactMap(\.stringValue)
            if !parsed.isEmpty { languages = parsed }
        }
        let floor = arguments["min_confidence"]?.doubleValue ?? 0

        let entries = try performOCR(on: pixels, languages: languages)
        // OCR ran on the cut-out pixels, so its boxes are local to that cut.
        // Project through the searched area, then through the frame's own
        // placement, so the caller only ever sees root coordinates.
        let items =
            entries
            .filter { Double($0.confidence) >= floor }
            .map { entry -> JSONValue in
                let local = NormRect(
                    x1: entry.x, y1: entry.y,
                    x2: entry.x + entry.width, y2: entry.y + entry.height)
                let root = frame.toRoot(target.project(local))
                return .object([
                    "text": .string(entry.text),
                    "confidence": .number((Double(entry.confidence) * 100).rounded() / 100),
                    "bbox": root.json,
                ])
            }

        guard !items.isEmpty else {
            return MCPToolResult(
                text: "No text found in \(frame.summary)"
                    + (area == nil ? "." : " within that region."))
        }
        let payload = try JSONValue.object([
            "frame_id": .string(frame.id),
            "items": .array(items),
        ]).serialized()
        return MCPToolResult(text: payload)
    }
}

// MARK: - image_crop

/// Cut a region out as a new frame, and show it.
@MainActor
public final class ImageCropTool: MCPTool {
    private let store: FrameStore
    public init(store: FrameStore) { self.store = store }

    public var name: String { "image_crop" }
    public var description: String {
        "Cut a region out of a captured frame and return it as an image, plus a new frame_id for "
            + "the crop. Use it to look closely at something too small to read in the full frame. "
            + "The crop remembers where it came from, so anything you find in it still reports "
            + "whole-frame coordinates."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "frame_id": FrameArgs.frameIdProperty,
            "region": NormRect.schema,
            "region_id": .property("string", "A region id from image_regions, instead of `region`."),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let (frame, area) = try FrameArgs.resolve(arguments, in: store)
        guard let target = area else {
            throw ToolFailure("image_crop needs a `region` or `region_id`")
        }
        guard let pixels = frame.pixels(in: target) else {
            throw ToolFailure("that region does not overlap frame \(frame.id)")
        }
        let cropped = store.registerCrop(of: frame, root: frame.toRoot(target), image: pixels)
        guard let base64 = WindowManager.cgImageToBase64(pixels) else {
            throw ToolFailure("could not encode the crop as PNG")
        }
        return MCPToolResult(
            text: "frame_id=\(cropped.id) — crop of \(frame.id) at "
                + "\((try? cropped.originRect.json.serialized()) ?? "") "
                + "(\(cropped.pixelWidth)x\(cropped.pixelHeight)).",
            images: [MCPImage(base64: base64)])
    }
}

// MARK: - image_regions

/// Propose areas worth a closer look — without saying what they are.
@MainActor
public final class ImageRegionsTool: MCPTool {
    private let store: FrameStore
    public init(store: FrameStore) { self.store = store }

    public var name: String { "image_regions" }
    public var description: String {
        "Find areas of a frame that look worth inspecting — text, rectangular shapes like buttons "
            + "and panels, and otherwise salient spots such as icons. It reports WHERE something "
            + "interesting is, never what it is: decide that by cropping or OCRing the region. "
            + "Each result gets an id usable as region_id in image_crop, image_ocr and "
            + "android_tap_region."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "frame_id": FrameArgs.frameIdProperty,
            "region": NormRect.schema,
            "kinds": .object([
                "type": .string("array"),
                "description": .string(
                    "Which to look for: text_like, rectangle, salient. Default all three."),
                "items": .object(["type": .string("string")]),
            ]),
            "max_results": .property("integer", "Cap the number returned (default 40)."),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let (frame, area) = try FrameArgs.resolve(arguments, in: store)
        let target = area ?? .full
        guard let pixels = frame.pixels(in: target) else {
            throw ToolFailure("that region does not overlap frame \(frame.id)")
        }

        var wanted: Set<String> = ["text_like", "rectangle", "salient"]
        if case .array(let list)? = arguments["kinds"] {
            let parsed = Set(list.compactMap(\.stringValue))
            if !parsed.isEmpty { wanted = parsed }
        }
        let cap = max(1, arguments.optionalInt("max_results") ?? 40)

        var found: [(NormRect, Region.Kind, Double)] = []
        // Vision reports bottom-left origin; `flip` converts to the top-left
        // origin every other coordinate here uses.
        func flip(_ box: CGRect) -> NormRect {
            NormRect(
                x1: box.origin.x, y1: 1 - box.origin.y - box.height,
                x2: box.origin.x + box.width, y2: 1 - box.origin.y)
        }
        func record(_ box: CGRect, _ kind: Region.Kind, _ confidence: Double) {
            let root = frame.toRoot(target.project(flip(box)))
            found.append((root.clamped(), kind, confidence))
        }

        var requests: [VNRequest] = []
        let textRequest = VNDetectTextRectanglesRequest()
        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.maximumObservations = 32
        rectRequest.minimumConfidence = 0.3
        rectRequest.minimumAspectRatio = 0.1
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

        if wanted.contains("text_like") { requests.append(textRequest) }
        if wanted.contains("rectangle") { requests.append(rectRequest) }
        if wanted.contains("salient") { requests.append(saliencyRequest) }
        guard !requests.isEmpty else {
            throw ToolFailure("`kinds` must include at least one of text_like, rectangle, salient")
        }

        try VNImageRequestHandler(cgImage: pixels, options: [:]).perform(requests)

        for obs in textRequest.results ?? [] {
            record(obs.boundingBox, .textLike, Double(obs.confidence))
        }
        for obs in rectRequest.results ?? [] {
            record(obs.boundingBox, .rectangle, Double(obs.confidence))
        }
        for obs in saliencyRequest.results ?? [] {
            for salient in obs.salientObjects ?? [] {
                record(salient.boundingBox, .salient, Double(salient.confidence))
            }
        }

        // Strongest first, so a truncated list keeps the best candidates.
        found.sort { $0.2 > $1.2 }
        let regions = frame.setRegions(Array(found.prefix(cap)))

        guard !regions.isEmpty else {
            return MCPToolResult(text: "No candidate regions found in \(frame.summary).")
        }
        let payload = try JSONValue.object([
            "frame_id": .string(frame.id),
            "regions": .array(regions.map(\.json)),
            "truncated": .bool(found.count > regions.count),
        ]).serialized()
        return MCPToolResult(text: payload)
    }
}

// MARK: - image_diff

/// What changed between two frames — the verification primitive.
@MainActor
public final class ImageDiffTool: MCPTool {
    private let store: FrameStore

    /// The comparison grid. Coarse on purpose: the question is "did something
    /// change, and roughly where", not per-pixel truth. A fine grid would turn
    /// an animated water tile or a blinking cursor into hundreds of hits.
    private static let gridColumns = 48
    private static let gridRows = 27

    public init(store: FrameStore) { self.store = store }

    public var name: String { "image_diff" }
    public var description: String {
        "Compare two captured frames and report which areas changed. This is how you check that "
            + "an action did something: observe, act, observe again, then diff. An empty result "
            + "means the screen did not react — the tap probably missed. Changed areas come back "
            + "in whole-frame coordinates."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "frame_a": .property("string", "The earlier frame id."),
                "frame_b": .property("string", "The later frame id. Omit for the most recent."),
                "threshold": .numberProperty(
                    "How different a cell must be to count, 0-1 (default 0.06). Raise it to "
                        + "ignore animation.", minimum: 0, maximum: 1),
            ],
            required: ["frame_a"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let a = try store.require(try arguments.string("frame_a"))
        let b = try store.require(arguments.optionalString("frame_b"))
        guard a.id != b.id else {
            throw ToolFailure("frame_a and frame_b are the same frame (\(a.id))")
        }
        let threshold = arguments["threshold"]?.doubleValue ?? 0.06

        let cols = Self.gridColumns
        let rows = Self.gridRows
        let gridA = try Self.sample(a.image, cols: cols, rows: rows)
        let gridB = try Self.sample(b.image, cols: cols, rows: rows)

        var changed: [(Int, Int)] = []
        var total = 0.0
        for index in 0..<(cols * rows) {
            let delta = Self.distance(gridA[index], gridB[index])
            total += delta
            if delta > threshold { changed.append((index % cols, index / cols)) }
        }
        let meanDelta = total / Double(cols * rows)

        guard !changed.isEmpty else {
            return MCPToolResult(
                text: try JSONValue.object([
                    "frame_a": .string(a.id), "frame_b": .string(b.id),
                    "changed": .bool(false),
                    "changed_fraction": .number(0),
                    "mean_delta": .number((meanDelta * 1000).rounded() / 1000),
                    "note": .string(
                        "Nothing changed above the threshold. If an action should have had an "
                            + "effect, it probably did not land."),
                ]).serialized())
        }

        let boxes = Self.merge(changed, cols: cols, rows: rows)
        let payload = try JSONValue.object([
            "frame_a": .string(a.id), "frame_b": .string(b.id),
            "changed": .bool(true),
            "changed_fraction": .number(
                (Double(changed.count) / Double(cols * rows) * 1000).rounded() / 1000),
            "mean_delta": .number((meanDelta * 1000).rounded() / 1000),
            "areas": .array(boxes.map(\.json)),
        ]).serialized()
        return MCPToolResult(text: payload)
    }

    /// Average each grid cell to one RGB triple.
    nonisolated static func sample(_ image: CGImage, cols: Int, rows: Int) throws
        -> [(Double, Double, Double)]
    {
        let bytesPerRow = cols * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * rows)
        // The pointer must stay valid for the whole draw. Passing `&buffer`
        // straight to CGContext hands it a pointer good only for that call —
        // the same class of bug that made decodeImage fault in ImageIO.
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: cols, height: rows, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Let the resampler average each cell for us: two small draws
            // instead of reading megapixels by hand.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            return true
        }
        guard drew else { throw ToolFailure("could not build a comparison bitmap") }

        return (0..<(cols * rows)).map { index in
            let offset = index * 4
            return (
                Double(buffer[offset]) / 255, Double(buffer[offset + 1]) / 255,
                Double(buffer[offset + 2]) / 255
            )
        }
    }

    nonisolated static func distance(
        _ lhs: (Double, Double, Double), _ rhs: (Double, Double, Double)
    ) -> Double {
        (abs(lhs.0 - rhs.0) + abs(lhs.1 - rhs.1) + abs(lhs.2 - rhs.2)) / 3
    }

    /// Group changed cells into rectangles by flood fill, so a caller gets "the
    /// bottom panel changed" instead of two hundred coordinates.
    nonisolated static func merge(_ cells: [(Int, Int)], cols: Int, rows: Int) -> [NormRect] {
        var remaining = Set(cells.map { $0.1 * cols + $0.0 })
        var boxes: [NormRect] = []

        while let seed = remaining.first {
            var stack = [seed]
            remaining.remove(seed)
            var minX = seed % cols, maxX = minX
            var minY = seed / cols, maxY = minY

            while let current = stack.popLast() {
                let x = current % cols, y = current / cols
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                // 8-connected: diagonal neighbours belong to the same panel.
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < cols, ny >= 0, ny < rows else { continue }
                        let neighbour = ny * cols + nx
                        if remaining.remove(neighbour) != nil { stack.append(neighbour) }
                    }
                }
            }
            boxes.append(
                NormRect(
                    x1: Double(minX) / Double(cols), y1: Double(minY) / Double(rows),
                    x2: Double(maxX + 1) / Double(cols), y2: Double(maxY + 1) / Double(rows)))
        }
        // Largest first: the biggest change is usually the one that matters.
        boxes.sort { $0.width * $0.height > $1.width * $1.height }
        return boxes
    }
}
