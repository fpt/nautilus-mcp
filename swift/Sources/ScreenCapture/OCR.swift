import Foundation
import CoreGraphics
import Vision

/// A single recognized text region from OCR.
public struct OCREntry: Sendable {
    /// The recognized text string.
    public let text: String
    /// Confidence score (0.0–1.0).
    public let confidence: Float
    /// Bounding box in normalized coordinates (0.0–1.0).
    /// Origin is top-left (converted from Vision's bottom-left origin).
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// Perform OCR on a CGImage using Apple Vision framework.
/// Returns recognized text entries with bounding boxes.
/// Thread-safe — can be called from any thread/actor.
public func performOCR(
    on image: CGImage,
    languages: [String] = ["en-US", "ja"]
) throws -> [OCREntry] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])

    guard let observations = request.results else { return [] }

    return observations.compactMap { obs in
        guard let candidate = obs.topCandidates(1).first else { return nil }
        let box = obs.boundingBox
        // Vision uses bottom-left origin; convert to top-left
        return OCREntry(
            text: candidate.string,
            confidence: candidate.confidence,
            x: box.origin.x,
            y: 1.0 - box.origin.y - box.height,
            width: box.width,
            height: box.height
        )
    }
}

/// Format OCR entries into a human-readable string with bounding boxes.
/// The coordinates can be used directly as crop_x/y/w/h parameters.
public func formatOCRResults(_ entries: [OCREntry]) -> String {
    if entries.isEmpty {
        return "No text detected."
    }
    var lines: [String] = ["OCR Results (\(entries.count) entries):"]
    for entry in entries {
        let conf = String(format: "%.0f%%", entry.confidence * 100)
        let pos = String(format: "[%.2f,%.2f %.0f%%x%.0f%%]",
                         entry.x, entry.y, entry.width * 100, entry.height * 100)
        lines.append("  \(pos) \"\(entry.text)\" (\(conf))")
    }
    return lines.joined(separator: "\n")
}

/// Format OCR entries into spatially-grouped text blocks, the way a person
/// reads a window: lines that are close together vertically are merged into a
/// block, and lines on the same row are ordered left-to-right. This is far more
/// legible to an LLM than the flat per-line list from `formatOCRResults` — use
/// this for "what does this window say"; use `formatOCRResults` when you need
/// per-line bounding boxes (e.g. to drive a follow-up crop).
///
/// Ported from m6o-deskcat's `groupIntoBlocks`, adapted for `OCREntry`'s
/// top-left origin (deskcat used Vision's bottom-left origin).
public func formatOCRResultsGrouped(_ entries: [OCREntry]) -> String {
    if entries.isEmpty {
        return "No text detected."
    }

    // Sort top-to-bottom. Top-left origin: a smaller y is higher on screen.
    let sorted = entries.sorted { $0.y < $1.y }

    var blocks: [[OCREntry]] = []
    var current: [OCREntry] = [sorted[0]]

    for i in 1..<sorted.count {
        let prev = current.last!
        let curr = sorted[i]
        // Vertical gap between the bottom of the previous line (y + height) and
        // the top of the current line (y).
        let gap = curr.y - (prev.y + prev.height)
        // Adaptive threshold: lines within ~1.5 line-heights belong together.
        let lineHeight = max(prev.height, curr.height)
        if gap < lineHeight * 1.5 {
            current.append(curr)
        } else {
            blocks.append(current)
            current = [curr]
        }
    }
    blocks.append(current)

    // Within each block, order lines on the same row left-to-right, otherwise
    // top-to-bottom; then join with spaces.
    let rendered = blocks.map { block -> String in
        let rowSorted = block.sorted { a, b in
            let aMidY = a.y + a.height / 2
            let bMidY = b.y + b.height / 2
            if abs(aMidY - bMidY) < a.height * 0.5 {
                return a.x < b.x            // same row → left-to-right
            }
            return aMidY < bMidY            // otherwise → top-to-bottom
        }
        return rowSorted.map(\.text).joined(separator: " ")
    }

    var out = ["OCR (\(blocks.count) block(s)):"]
    out.append(contentsOf: rendered.map { "  • \($0)" })
    return out.joined(separator: "\n")
}
