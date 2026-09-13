import AppKit
import CoreGraphics
import XCTest

@testable import NautilusKit

/// Draw a shape so signatures have something with real edges to describe.
private func shapeImage(_ w: Int, _ h: Int, draw: (CGContext, CGRect) -> Void) -> CGImage {
    let bpr = w * 4
    var px = [UInt8](repeating: 0, count: bpr * h)
    return px.withUnsafeMutableBytes { raw -> CGImage in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(ctx, CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}

private func barsImage(_ w: Int, _ h: Int, count: Int) -> CGImage {
    shapeImage(w, h) { ctx, rect in
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let step = rect.width / CGFloat(count * 2)
        for i in 0..<count {
            ctx.fill(CGRect(x: CGFloat(i * 2) * step, y: 0, width: step, height: rect.height))
        }
    }
}

private func circleImage(_ w: Int, _ h: Int) -> CGImage {
    shapeImage(w, h) { ctx, rect in
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
    }
}

final class ShapeSignatureTests: XCTestCase {
    func testIdenticalShapesCorrelatePerfectly() throws {
        let image = barsImage(120, 40, count: 4)
        let a = try XCTUnwrap(ShapeBuilder.signature(of: image))
        let b = try XCTUnwrap(ShapeBuilder.signature(of: image))
        XCTAssertEqual(a.score(against: b), 1.0, accuracy: 1e-4)
    }

    /// The whole point of resampling to a fixed 64x64: the same element drawn
    /// larger must still match, because a button rescales with resolution.
    func testTheSameShapeAtADifferentSizeStillMatches() throws {
        let small = try XCTUnwrap(ShapeBuilder.signature(of: barsImage(120, 40, count: 4)))
        let large = try XCTUnwrap(ShapeBuilder.signature(of: barsImage(240, 80, count: 4)))
        XCTAssertGreaterThan(small.score(against: large), 0.7)
    }

    func testDifferentShapesDoNotCorrelate() throws {
        let bars = try XCTUnwrap(ShapeBuilder.signature(of: barsImage(120, 40, count: 4)))
        let circle = try XCTUnwrap(ShapeBuilder.signature(of: circleImage(120, 40)))
        XCTAssertLessThan(bars.score(against: circle), 0.5)
    }

    /// A flat patch has no shape. It must correlate with nothing, rather than
    /// with everything — otherwise blank sky becomes a match for any button.
    func testAFlatPatchIsBlankAndMatchesNothing() throws {
        let flat = shapeImage(80, 80) { _, _ in }
        let signature = try XCTUnwrap(ShapeBuilder.signature(of: flat))
        XCTAssertTrue(signature.isBlank)
        let bars = try XCTUnwrap(ShapeBuilder.signature(of: barsImage(120, 40, count: 4)))
        XCTAssertEqual(signature.score(against: bars), 0, accuracy: 1e-9)
    }

    func testContrastDoesNotChangeTheScore() throws {
        let strong = shapeImage(100, 50) { ctx, rect in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(rect.insetBy(dx: 20, dy: 10))
        }
        let faint = shapeImage(100, 50) { ctx, rect in
            ctx.setFillColor(CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1))
            ctx.fill(rect.insetBy(dx: 20, dy: 10))
        }
        let a = try XCTUnwrap(ShapeBuilder.signature(of: strong))
        let b = try XCTUnwrap(ShapeBuilder.signature(of: faint))
        XCTAssertGreaterThan(a.score(against: b), 0.9, "normalization should erase contrast")
    }

    func testWindowSamplingMatchesAFullCropOfTheSameArea() throws {
        // A window pulled out of a shared edge map must describe the same thing
        // as cropping that area and building a signature directly — that
        // equivalence is what lets the cheap stage stand in for the expensive one.
        let image = barsImage(160, 80, count: 4)
        let luma = try XCTUnwrap(ShapeBuilder.luminance(of: image, width: 160, height: 80))
        let windowed = try XCTUnwrap(
            ShapeBuilder.signature(
                fromLuma: luma, width: 160, height: 80, x: 0, y: 0, w: 160, h: 80))
        let direct = try XCTUnwrap(ShapeBuilder.signature(of: image))
        XCTAssertGreaterThan(windowed.score(against: direct), 0.85)
    }

    func testOutOfBoundsWindowsAreRefused() {
        let luma = [Float](repeating: 0, count: 100)
        XCTAssertNil(
            ShapeBuilder.signature(fromLuma: luma, width: 10, height: 10, x: 5, y: 5, w: 10, h: 10))
        XCTAssertNil(
            ShapeBuilder.signature(fromLuma: luma, width: 10, height: 10, x: 0, y: 0, w: 0, h: 4))
    }
}

@MainActor
final class PrototypeStoreTests: XCTestCase {
    private func makeStore() throws -> (PrototypeStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nautilus-proto-\(UUID().uuidString)")
        return (PrototypeStore(root: root), root)
    }

    func testSaveAndLoadRoundTrip() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let signature = try XCTUnwrap(ShapeBuilder.signature(of: barsImage(120, 40, count: 4)))
        let sample = PrototypeSample(
            shape: Data(signature.raw).base64EncodedString(), featurePrint: nil,
            aspect: 3.0, learnedAt: "now", note: "進軍")
        try store.save(
            Prototype(name: "farlight_cod/march", semantic: "進軍", kind: "button",
                      positives: [sample]))

        let loaded = try PrototypeStore(root: root).load("farlight_cod/march")
        XCTAssertEqual(loaded.semantic, "進軍")
        XCTAssertEqual(loaded.positives.count, 1)
        XCTAssertEqual(loaded.aspect, 3.0, accuracy: 1e-9)
        // The stored sketch must survive the round trip, or matching silently degrades.
        let restored = try XCTUnwrap(loaded.positives[0].signature)
        XCTAssertEqual(restored.score(against: signature), 1.0, accuracy: 1e-4)
    }

    func testListsWhatWasSaved() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try store.list(), [])
        try store.save(Prototype(name: "farlight_cod/march"))
        try store.save(Prototype(name: "farlight_cod/attack"))
        XCTAssertEqual(try store.list(), ["farlight_cod/attack", "farlight_cod/march"])
    }

    /// A prototype name reaches the filesystem, so it must not be able to
    /// escape the store.
    func testNamesCannotClimbOutOfTheStore() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["../escape", "a/../../b", "/etc/passwd", "", "a/b/c", "set/na me", "set/.."] {
            XCTAssertThrowsError(try store.directory(for: bad), "\(bad.debugDescription) allowed")
        }
        XCTAssertNoThrow(try store.directory(for: "farlight_cod/march_button"))
        XCTAssertNoThrow(try store.directory(for: "loose-name"))
    }

    func testMissingPrototypeSaysSoAndNamesWhatExists() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(Prototype(name: "farlight_cod/march"))
        XCTAssertThrowsError(try store.load("farlight_cod/nope")) { error in
            let message = (error as? ToolFailure)?.message ?? ""
            XCTAssertTrue(message.contains("farlight_cod/march"), message)
        }
    }
}

/// Vision's descriptor is the stage that decides *which* element a candidate is.
final class FeaturePrintTests: XCTestCase {
    func testTheSameImageIsNearerThanADifferentOne() throws {
        let bars = barsImage(120, 40, count: 4)
        let other = circleImage(120, 40)
        guard let a = FeaturePrint.compute(bars), let b = FeaturePrint.compute(bars),
            let c = FeaturePrint.compute(other)
        else { throw XCTSkip("Vision feature prints unavailable here") }
        let same = try XCTUnwrap(FeaturePrint.distance(a, b))
        let different = try XCTUnwrap(FeaturePrint.distance(a, c))
        XCTAssertLessThan(same, different, "same image must be nearer than a different one")
    }

    func testSurvivesArchivingSoItCanBeStored() throws {
        guard let print = FeaturePrint.compute(barsImage(120, 40, count: 4)) else {
            throw XCTSkip("Vision feature prints unavailable here")
        }
        let encoded = try XCTUnwrap(FeaturePrint.encode(print))
        let decoded = try XCTUnwrap(FeaturePrint.decode(encoded))
        XCTAssertEqual(try XCTUnwrap(FeaturePrint.distance(print, decoded)), 0, accuracy: 1e-5)
    }
}
