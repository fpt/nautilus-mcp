import CoreGraphics
import Foundation
import Vision

// ============================================================================
// Matcher
// ============================================================================

public struct VisualMatch: Sendable {
    public var bbox: NormRect
    public var score: Double
    public var shapeScore: Double
    public var featureScore: Double
    public var rejectedBy: String?
}

/// Finds a learned element on screen, in two stages.
///
/// Scanning a whole screen with an image comparison is both slow and prone to
/// finding something that merely looks similar. So:
///
/// 1. **Propose, cheaply.** Slide a window of the prototype's aspect across the
///    search region's edge map at several scales, scoring by normalized
///    cross-correlation. This is array arithmetic over a buffer built with one
///    CoreGraphics draw, so thousands of positions cost little.
/// 2. **Confirm, expensively.** Take only the best few and compare them with
///    Vision's feature print, which is what actually distinguishes this button
///    from the one next to it.
///
/// Hard negatives are subtracted at the end: a game's icons resemble each other,
/// and "similar enough" is not "the right one".
@MainActor
enum VisualMatcher {
    /// Multipliers applied to the size the prototype was learned at. A UI
    /// element does not change size much between sightings, so a tight sweep
    /// around the known size beats guessing from the search region's shape.
    static let sizeMultipliers: [Double] = [0.65, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
    /// Used only when a prototype predates size recording: fractions of the
    /// search region's width.
    static let blindScales: [Double] = [0.08, 0.12, 0.18, 0.25, 0.35, 0.5, 0.7, 0.9]
    /// How many proposals survive the coarse sweep. Generous on purpose: the
    /// sweep lands on a grid, so the true position often scores a little below
    /// a neighbouring offset and needs to still be in the running when
    /// refinement happens. At six, a real match sitting seventh never reached
    /// the classifier at all.
    static let coarseShortlist = 24
    /// How many survive refinement and reach the expensive classifier.
    static let refinedShortlist = 6
    /// Local alignment search, in working-buffer pixels and scale multipliers.
    /// A candidate is usually found but misaligned by a pixel or three, which
    /// lets background into the window and collapses the score — that is a more
    /// common failure than missing the element outright.
    static let alignmentOffsets = [-4, -2, 0, 2, 4]
    static let alignmentScales = [0.92, 1.0, 1.08]

    static func find(
        prototype: Prototype, frame: Frame, searchArea: NormRect, limit: Int,
        scaleRange: (low: Double, high: Double)? = nil
    ) throws -> [VisualMatch] {
        guard let template = prototype.positives.compactMap(\.signature).first else {
            throw ToolFailure("prototype \(prototype.name) has no usable samples")
        }
        let templates = prototype.positives.compactMap(\.signature)
        guard let regionPixels = frame.pixels(in: searchArea) else {
            throw ToolFailure("the search region does not overlap frame \(frame.id)")
        }

        // --- Stage 1: cheap proposals over one luminance buffer ---------------
        // Size the working buffer so the expected window lands around 44px —
        // big enough to resample to 64x64 without losing the shape, small
        // enough that the sweep stays cheap.
        let relative = prototype.frameWidth.map { $0 / max(searchArea.width, 1e-6) }
        let target = 44.0
        let desired = relative.map { Int((target / max($0, 1e-6)).rounded()) } ?? 320
        let width = max(120, min(min(720, regionPixels.width), desired))
        let height = max(
            8, Int((Double(width) * Double(regionPixels.height) / Double(regionPixels.width)).rounded()))
        guard let luma = ShapeBuilder.luminance(of: regionPixels, width: width, height: height)
        else { throw ToolFailure("could not rasterize the search region") }

        let aspect = max(0.05, prototype.aspect)
        var proposals: [(score: Double, x: Int, y: Int, w: Int, h: Int)] = []

        // Widths to try, in working-buffer pixels.
        //
        // Derived from the range of sizes the prototype was taught at, widened
        // at both ends — a map sprite scales with the camera, so the same node
        // is a different size at every zoom. Teaching it at two zooms widens
        // this automatically.
        let widths: [Double]
        if let span = prototype.frameWidthRange {
            let multipliers = scaleRange ?? (low: 0.6, high: 1.6)
            let lo = span.low / max(searchArea.width, 1e-6) * multipliers.low
            let hi = max(lo * 1.05, span.high / max(searchArea.width, 1e-6) * multipliers.high)
            // Log-spaced: scale error is proportional, so equal ratios beat
            // equal differences.
            let steps = 9
            widths = (0..<steps).map { index in
                let t = Double(index) / Double(steps - 1)
                return Double(width) * lo * pow(hi / lo, t)
            }
        } else {
            widths = blindScales.map { Double(width) * $0 }
        }

        for candidateWidth in widths {
            let w = Int(candidateWidth.rounded())
            let h = Int((Double(w) / aspect).rounded())
            guard w >= 8, h >= 8, w <= width, h <= height else { continue }
            let stride = max(2, min(w, h) / 6)
            var y = 0
            while y + h <= height {
                var x = 0
                while x + w <= width {
                    if let candidate = ShapeBuilder.signature(
                        fromLuma: luma, width: width, height: height, x: x, y: y, w: w, h: h),
                        !candidate.isBlank
                    {
                        let best = templates.map { candidate.score(against: $0) }.max() ?? -1
                        proposals.append((best, x, y, w, h))
                    }
                    x += stride
                }
                y += stride
            }
        }
        guard !proposals.isEmpty else { return [] }
        proposals.sort { $0.score > $1.score }

        // Keep the best few, but not several overlapping views of one spot.
        var kept: [(score: Double, x: Int, y: Int, w: Int, h: Int)] = []
        for candidate in proposals {
            let overlapping = kept.contains { other in
                let dx = abs((candidate.x + candidate.w / 2) - (other.x + other.w / 2))
                let dy = abs((candidate.y + candidate.h / 2) - (other.y + other.h / 2))
                return dx < max(candidate.w, other.w) / 2 && dy < max(candidate.h, other.h) / 2
            }
            if !overlapping { kept.append(candidate) }
            if kept.count >= coarseShortlist { break }
        }

        // --- Stage 1b: nudge each candidate into alignment ---------------------
        func shapeScore(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Double? {
            guard
                let signature = ShapeBuilder.signature(
                    fromLuma: luma, width: width, height: height, x: x, y: y, w: w, h: h),
                !signature.isBlank
            else { return nil }
            return templates.map { signature.score(against: $0) }.max()
        }

        // Refinement maximizes the SHAPE score, but the verdict is mostly the
        // feature print. Replacing a candidate with its shape-best neighbour
        // therefore sometimes moves it somewhere the classifier likes less —
        // measured, it cost menu_items 0.470 -> 0.388. So keep BOTH the coarse
        // box and its refined neighbour and let the classifier choose, rather
        // than deciding on a proxy for the thing we actually care about.
        var finalists: [(score: Double, x: Int, y: Int, w: Int, h: Int)] = []
        for candidate in kept.prefix(refinedShortlist) {
            finalists.append(candidate)
            var refined = candidate
            for scale in alignmentScales {
                let w = Int((Double(candidate.w) * scale).rounded())
                let h = Int((Double(candidate.h) * scale).rounded())
                guard w >= 8, h >= 8, w <= width, h <= height else { continue }
                for dx in alignmentOffsets {
                    for dy in alignmentOffsets {
                        let x = candidate.x + dx
                        let y = candidate.y + dy
                        guard x >= 0, y >= 0, x + w <= width, y + h <= height else { continue }
                        if let score = shapeScore(x, y, w, h), score > refined.score {
                            refined = (score, x, y, w, h)
                        }
                    }
                }
            }
            // Only worth a second classifier call if it actually moved.
            if refined.x != candidate.x || refined.y != candidate.y || refined.w != candidate.w {
                finalists.append(refined)
            }
        }
        kept = finalists

        // --- Stage 2: confirm with feature prints -----------------------------
        let positivePrints = prototype.positives.compactMap { $0.featurePrint.flatMap(FeaturePrint.decode) }
        let negativePrints = prototype.negatives.compactMap { $0.featurePrint.flatMap(FeaturePrint.decode) }
        let negativeShapes = prototype.negatives.compactMap(\.signature)

        var matches: [VisualMatch] = []
        for candidate in kept {
            // Map the window back into root coordinates through the searched area.
            let local = NormRect(
                x1: Double(candidate.x) / Double(width),
                y1: Double(candidate.y) / Double(height),
                x2: Double(candidate.x + candidate.w) / Double(width),
                y2: Double(candidate.y + candidate.h) / Double(height))
            let root = frame.toRoot(searchArea.project(local))

            var featureScore = 0.0
            var rejectedBy: String?
            if !positivePrints.isEmpty, let pixels = frame.pixels(in: root),
                let print = FeaturePrint.compute(pixels)
            {
                let best = positivePrints.compactMap { FeaturePrint.distance(print, $0) }.min()
                // Distances run ~0.2 for the same element and ~1.0 for a
                // different one, so 1 - d is a usable similarity.
                featureScore = best.map { max(0, 1 - $0) } ?? 0
                let worstNegative =
                    negativePrints.compactMap { FeaturePrint.distance(print, $0) }.min()
                    .map { max(0, 1 - $0) } ?? 0
                if worstNegative > featureScore {
                    rejectedBy = "resembles a known negative more than the prototype"
                    featureScore = max(0, featureScore - worstNegative)
                }
            }

            var shapeScore = max(0, candidate.score)
            if let signature = ShapeBuilder.signature(
                fromLuma: luma, width: width, height: height,
                x: candidate.x, y: candidate.y, w: candidate.w, h: candidate.h)
            {
                let negative = negativeShapes.map { signature.score(against: $0) }.max() ?? 0
                if negative > shapeScore { shapeScore = max(0, shapeScore - negative) }
            }

            // Feature print carries more weight: shape finds the place, the
            // feature print says which element it is.
            let combined =
                positivePrints.isEmpty ? shapeScore : 0.4 * shapeScore + 0.6 * featureScore
            matches.append(
                VisualMatch(
                    bbox: root, score: combined, shapeScore: shapeScore,
                    featureScore: featureScore, rejectedBy: rejectedBy))
        }
        matches.sort { $0.score > $1.score }
        return Array(matches.prefix(max(1, limit)))
    }
}

// ============================================================================
// visual_learn
// ============================================================================

/// Remember what something looks like, so it can be found again without OCR.
@MainActor
public final class VisualLearnTool: MCPTool {
    private let frames: FrameStore
    private let store: PrototypeStore

    public init(frames: FrameStore, store: PrototypeStore) {
        self.frames = frames
        self.store = store
    }

    public var name: String { "visual_learn" }
    public var description: String {
        "Remember the appearance of a UI element so it can be found later without reading text. "
            + "Point it at a region you have just identified — typically one you found with "
            + "image_ocr — and give it a name. Learning the same element again from a different "
            + "screen makes it more robust, and learning a look-alike with as=\"negative\" stops "
            + "it being confused with that look-alike. Store the icon rather than the whole "
            + "button where you can: an icon survives a language change, a label does not."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "name": .property(
                    "string", "Prototype id as `set/name`, e.g. farlight_cod/march_button."),
                "frame_id": FrameArgs.frameIdProperty,
                "region": NormRect.schema,
                "region_id": .property("string", "A region id from image_regions, instead of `region`."),
                "semantic": .property(
                    "string", "What it means or reads, e.g. 進軍. Recorded for humans; never matched on."),
                "kind": .property("string", "button, icon, panel, badge…"),
                "as": .property(
                    "string", "\"positive\" (default) or \"negative\" for a look-alike to reject."),
                "search_prior": NormRect.schema,
            ],
            required: ["name"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let name = try arguments.string("name")
        let (frame, area) = try FrameArgs.resolve(arguments, in: frames)
        guard let target = area else {
            throw ToolFailure("visual_learn needs a `region` or `region_id` to learn from")
        }
        guard let pixels = frame.pixels(in: target) else {
            throw ToolFailure("that region does not overlap frame \(frame.id)")
        }
        guard let signature = ShapeBuilder.signature(of: pixels) else {
            throw ToolFailure("could not build a shape from that region")
        }
        if signature.isBlank {
            throw ToolFailure(
                "that region has no discernible edges — it looks like flat colour, which cannot "
                    + "be matched. Point at the element itself, not the space beside it.")
        }

        let asNegative = (arguments.optionalString("as") ?? "positive").lowercased() == "negative"
        var prototype =
            (try? store.load(name))
            ?? Prototype(
                name: name, semantic: arguments.optionalString("semantic"),
                kind: arguments.optionalString("kind"))
        if prototype.semantic == nil { prototype.semantic = arguments.optionalString("semantic") }
        if prototype.kind == nil { prototype.kind = arguments.optionalString("kind") }
        if let prior = NormRect.from(arguments["search_prior"]) {
            prototype.searchPrior = NormRectCodable(prior)
        } else if prototype.searchPrior == nil {
            // Default to a generous box around where it was seen, so the first
            // search does not have to scan the whole screen.
            let pad = 0.12
            prototype.searchPrior = NormRectCodable(
                NormRect(
                    x1: target.x1 - pad, y1: target.y1 - pad,
                    x2: target.x2 + pad, y2: target.y2 + pad
                ).clamped())
        }

        // Keep a patch of the surrounding scene, three times the element on each
        // axis, so this sample doubles as a localization test: the matcher can
        // be asked to find the element in it and scored against where we know it
        // to be. Three times is enough to pose a real search without storing a
        // whole frame per sample.
        let context = NormRect(
            x1: target.centerX - target.width * 1.5,
            y1: target.centerY - target.height * 1.5,
            x2: target.centerX + target.width * 1.5,
            y2: target.centerY + target.height * 1.5
        ).clamped()
        let contextPixels = frame.pixels(in: context)
        let targetInContext = context.localize(frame.toRoot(target)).map(NormRectCodable.init)

        var sample = PrototypeSample(
            shape: Data(signature.raw).base64EncodedString(),
            featurePrint: FeaturePrint.compute(pixels).flatMap(FeaturePrint.encode),
            aspect: target.height > 0 ? target.width / target.height : 1,
            width: target.width, height: target.height,
            centerX: target.centerX, centerY: target.centerY,
            learnedAt: ISO8601DateFormatter().string(from: Date()),
            note: arguments.optionalString("semantic"),
            contextFile: nil,  // filled in below, once the index is known
            targetInContext: targetInContext)

        let index: Int
        if asNegative {
            index = prototype.negatives.count + 1
            if contextPixels != nil {
                sample.contextFile = String(format: "context-negative-%03d.png", index)
            }
            prototype.negatives.append(sample)
        } else {
            index = prototype.positives.count + 1
            if contextPixels != nil {
                sample.contextFile = String(format: "context-sample-%03d.png", index)
            }
            prototype.positives.append(sample)
        }
        try store.save(prototype)

        let tag = asNegative ? "negative" : "sample"
        store.writePNG(pixels, named: String(format: "%@-%03d.png", tag, index), for: name)
        if let contextPixels {
            store.writePNG(
                contextPixels, named: String(format: "context-%@-%03d.png", tag, index), for: name)
        }
        var shapeImage: CGImage?
        if let rendered = PrototypeStore.image(of: signature) {
            store.writePNG(rendered, named: String(format: "shape-%@-%03d.png", tag, index), for: name)
            shapeImage = rendered
        }

        var text =
            "Learned \(name) as \(asNegative ? "a negative" : "positive") #\(index) "
            + "(\(prototype.positives.count) positive, \(prototype.negatives.count) negative). "
            + "Aspect \(String(format: "%.2f", sample.aspect))."
        if sample.featurePrint == nil {
            text += " NOTE: Vision could not describe this crop, so matching will fall back to "
                + "shape alone and be less reliable."
        }
        text += " The image below is the stored edge sketch — if it does not look like the "
            + "element, relearn it with a tighter region."

        return MCPToolResult(
            text: text,
            images: shapeImage.flatMap(ImageCoding.encodeBase64).map { [MCPImage(base64: $0)] } ?? [])
    }
}

// ============================================================================
// visual_find
// ============================================================================

/// Locate a previously learned element on screen.
@MainActor
public final class VisualFindTool: MCPTool {
    private let frames: FrameStore
    private let store: PrototypeStore

    public init(frames: FrameStore, store: PrototypeStore) {
        self.frames = frames
        self.store = store
    }

    public var name: String { "visual_find" }
    public var description: String {
        "Find a previously learned UI element in a captured frame and return where it is. Use "
            + "this instead of OCR once an element has been learned: it does not depend on font "
            + "or language, and it still works when a button has moved. The box comes back in "
            + "whole-frame coordinates, ready for android_tap. Judge a result by `margin` (how "
            + "far ahead of the runner-up it is) more than by `score`: scores are relative, and "
            + "on real game art a solid match lands around 0.3-0.5 while everything else sits "
            + "near 0.1. A small margin means two things on screen look alike — confirm with "
            + "image_ocr before tapping."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "prototype": .property("string", "Prototype id, e.g. farlight_cod/march_button."),
                "frame_id": FrameArgs.frameIdProperty,
                "region": NormRect.schema,
                "min_score": .numberProperty(
                    "Report nothing below this (default 0.25). Scores are relative, not "
                        + "probabilities; see the description.", minimum: 0, maximum: 1),
                "max_results": .property("integer", "How many candidates to return (default 3)."),
                "scale_range": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Widen or narrow the size sweep, as [low, high] multipliers of the sizes "
                            + "the prototype was taught at (default [0.6, 1.6]). Raise the high "
                            + "end when the camera may be zoomed further in than when it was "
                            + "learned, e.g. [0.4, 3.0] for a map sprite at an unknown zoom."),
                    "items": .object(["type": .string("number")]),
                ]),
            ],
            required: ["prototype"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let name = try arguments.string("prototype")
        let prototype = try store.load(name)
        let frame = try frames.require(arguments.optionalString("frame_id"))
        // Explicit region, else where this element usually lives, else all of it.
        let area =
            NormRect.from(arguments["region"]) ?? prototype.searchPrior?.rect ?? .full
        // Calibrated against real game art: the element a prototype was taught
        // scores ~0.3-0.5 and every other icon in the same row ~0.08-0.16. A
        // higher floor rejects genuine matches — 0.35 threw away a hit that had
        // localised to within three thousandths of the right spot.
        let floor = arguments["min_score"]?.doubleValue ?? 0.25
        let limit = arguments.optionalInt("max_results") ?? 3

        var scaleRange: (low: Double, high: Double)?
        if case .array(let bounds)? = arguments["scale_range"], bounds.count == 2,
            let low = bounds[0].doubleValue, let high = bounds[1].doubleValue,
            low > 0, high >= low
        {
            scaleRange = (low, high)
        }

        let started = Date()
        let matches = try VisualMatcher.find(
            prototype: prototype, frame: frame, searchArea: area.clamped(), limit: limit,
            scaleRange: scaleRange)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        let accepted = matches.filter { $0.score >= floor }
        guard !accepted.isEmpty else {
            let best = matches.first.map { String(format: "%.2f", $0.score) } ?? "none"
            return MCPToolResult(
                text: try JSONValue.object([
                    "prototype": .string(name),
                    "frame_id": .string(frame.id),
                    "found": .bool(false),
                    "best_score": .string(best),
                    "searched": area.json,
                    "note": .string(
                        "Nothing scored above \(String(format: "%.2f", floor)). Either the element "
                            + "is not on screen, or it looks different now — some controls change "
                            + "appearance with state (a menu button while its menu is open, for "
                            + "instance). Confirm with image_ocr, and if it is there, visual_learn "
                            + "it again so the prototype covers that look too."),
                ]).serialized())
        }

        // The runner-up is the honest confidence signal: a high score means
        // little if something else on screen scores nearly as high.
        let margin = accepted.count > 1 ? accepted[0].score - accepted[1].score : accepted[0].score

        let items = accepted.map { match -> JSONValue in
            var object: [String: JSONValue] = [
                "bbox": match.bbox.json,
                "score": .number((match.score * 1000).rounded() / 1000),
                "shape_score": .number((match.shapeScore * 1000).rounded() / 1000),
                "feature_score": .number((match.featureScore * 1000).rounded() / 1000),
                "center": .object([
                    "x": .number((match.bbox.centerX * 10000).rounded() / 10000),
                    "y": .number((match.bbox.centerY * 10000).rounded() / 10000),
                ]),
            ]
            if let rejected = match.rejectedBy { object["warning"] = .string(rejected) }
            return .object(object)
        }
        return MCPToolResult(
            text: try JSONValue.object([
                "prototype": .string(name),
                "frame_id": .string(frame.id),
                "found": .bool(true),
                "took_ms": .number(Double(elapsed)),
                "margin": .number((margin * 1000).rounded() / 1000),
                "matches": .array(items),
            ]).serialized())
    }
}

// ============================================================================
// visual_list
// ============================================================================

@MainActor
public final class VisualListTool: MCPTool {
    private let store: PrototypeStore
    public init(store: PrototypeStore) { self.store = store }

    public var name: String { "visual_list" }
    public var description: String {
        "List the UI elements that have been learned with visual_learn, with what each one means "
            + "and how many examples it holds."
    }
    public var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let names = try store.list()
        guard !names.isEmpty else {
            return MCPToolResult(
                text: "No prototypes learned yet. Use visual_learn on a region you have "
                    + "identified to create one.")
        }
        // Built statement by statement: as one literal this defeated the
        // type checker ("unable to type-check this expression in reasonable time").
        let rows: [JSONValue] = names.compactMap { name in
            guard let prototype = try? store.load(name) else { return nil }
            var row: [String: JSONValue] = [:]
            row["name"] = .string(name)
            row["semantic"] = prototype.semantic.map { JSONValue.string($0) } ?? JSONValue.null
            row["kind"] = prototype.kind.map { JSONValue.string($0) } ?? JSONValue.null
            row["positives"] = .number(Double(prototype.positives.count))
            row["negatives"] = .number(Double(prototype.negatives.count))
            row["aspect"] = .number((prototype.aspect * 100).rounded() / 100)
            row["search_prior"] = prototype.searchPrior?.rect.json ?? JSONValue.null
            if let centre = prototype.learnedCenter {
                let x = (centre.x * 10000).rounded() / 10000
                let y = (centre.y * 10000).rounded() / 10000
                row["learned_center"] = .object(["x": .number(x), "y": .number(y)])
            } else {
                row["learned_center"] = .null
            }
            return .object(row)
        }
        return MCPToolResult(text: try JSONValue.array(rows).serialized())
    }
}
