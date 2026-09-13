import Foundation
import CoreGraphics
import Vision

/// A detected object from Vision framework analysis.
public struct DetectedObject: Sendable {
    /// Object type: "rectangle", "face", "barcode", or "text"
    public let type: String
    /// Confidence score (0.0–1.0).
    public let confidence: Float
    /// Bounding box in normalized coordinates (0.0–1.0).
    /// Origin is top-left (converted from Vision's bottom-left origin).
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// Barcode payload string (nil for non-barcode detections).
    public let payload: String?
}

/// Perform object detection on a CGImage using Apple Vision framework.
/// Detects rectangles, faces, barcodes, and text regions in a single pass.
/// Thread-safe — can be called from any thread/actor.
public func performObjectDetection(on image: CGImage) throws -> [DetectedObject] {
    // Rectangle detection
    let rectRequest = VNDetectRectanglesRequest()
    rectRequest.maximumObservations = 16
    rectRequest.minimumConfidence = 0.5
    rectRequest.minimumAspectRatio = 0.2

    // Face detection
    let faceRequest = VNDetectFaceRectanglesRequest()

    // Barcode detection
    let barcodeRequest = VNDetectBarcodesRequest()
    barcodeRequest.symbologies = [.qr, .aztec, .ean13, .ean8, .upce, .code128]

    // Text region detection (bounding boxes only, not OCR)
    let textRequest = VNDetectTextRectanglesRequest()
    textRequest.reportCharacterBoxes = false

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([rectRequest, faceRequest, barcodeRequest, textRequest])

    var results: [DetectedObject] = []

    // Collect rectangle observations
    if let rects = rectRequest.results {
        for obs in rects {
            let box = obs.boundingBox
            results.append(DetectedObject(
                type: "rectangle",
                confidence: obs.confidence,
                x: box.origin.x,
                y: 1.0 - box.origin.y - box.height,
                width: box.width,
                height: box.height,
                payload: nil
            ))
        }
    }

    // Collect face observations
    if let faces = faceRequest.results {
        for obs in faces {
            let box = obs.boundingBox
            results.append(DetectedObject(
                type: "face",
                confidence: obs.confidence,
                x: box.origin.x,
                y: 1.0 - box.origin.y - box.height,
                width: box.width,
                height: box.height,
                payload: nil
            ))
        }
    }

    // Collect barcode observations
    if let barcodes = barcodeRequest.results {
        for obs in barcodes {
            let box = obs.boundingBox
            results.append(DetectedObject(
                type: "barcode",
                confidence: obs.confidence,
                x: box.origin.x,
                y: 1.0 - box.origin.y - box.height,
                width: box.width,
                height: box.height,
                payload: obs.payloadStringValue
            ))
        }
    }

    // Collect text region observations (location only, use OCR to read)
    if let texts = textRequest.results {
        for obs in texts {
            let box = obs.boundingBox
            results.append(DetectedObject(
                type: "text",
                confidence: obs.confidence,
                x: box.origin.x,
                y: 1.0 - box.origin.y - box.height,
                width: box.width,
                height: box.height,
                payload: nil
            ))
        }
    }

    return results
}

/// Format detection results into a human-readable string with bounding boxes.
public func formatDetectionResults(_ objects: [DetectedObject]) -> String {
    if objects.isEmpty {
        return "No objects detected."
    }

    // Group by type
    let grouped = Dictionary(grouping: objects) { $0.type }
    var lines: [String] = ["Object Detection (\(objects.count) objects):"]

    for type in ["text", "rectangle", "face", "barcode"] {
        guard let items = grouped[type], !items.isEmpty else { continue }
        lines.append("  \(type)s (\(items.count)):")
        for item in items {
            let conf = String(format: "%.0f%%", item.confidence * 100)
            let pos = String(format: "[%.2f,%.2f %.0f%%x%.0f%%]",
                             item.x, item.y, item.width * 100, item.height * 100)
            if let payload = item.payload {
                lines.append("    \(pos) \(conf) payload=\"\(payload)\"")
            } else {
                lines.append("    \(pos) \(conf)")
            }
        }
    }

    return lines.joined(separator: "\n")
}
