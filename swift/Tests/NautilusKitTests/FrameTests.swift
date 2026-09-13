import AppKit
import CoreGraphics
import XCTest

@testable import NautilusKit

/// A solid-colour image, so frames can be built without a screen or a device.
private func makeImage(_ w: Int, _ h: Int, gray: Double = 0.5) -> CGImage {
    let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage()!
}

final class NormRectTests: XCTestCase {
    func testCornersAreNormalizedWhicheverWayRound() {
        let backwards = NormRect(x1: 0.8, y1: 0.9, x2: 0.2, y2: 0.1)
        XCTAssertEqual(backwards.x1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(backwards.y2, 0.9, accuracy: 1e-9)
    }

    /// Projecting into a parent and localizing back must be the identity —
    /// this is the arithmetic every bbox in the server depends on.
    func testProjectAndLocalizeAreInverses() {
        let parent = NormRect(x1: 0.25, y1: 0.5, x2: 0.75, y2: 1.0)
        let local = NormRect(x1: 0.2, y1: 0.4, x2: 0.6, y2: 0.8)
        let projected = parent.project(local)
        let back = parent.localize(projected)
        XCTAssertEqual(back?.x1 ?? -1, local.x1, accuracy: 1e-9)
        XCTAssertEqual(back?.y2 ?? -1, local.y2, accuracy: 1e-9)
    }

    func testProjectionLandsWhereExpected() {
        // The bottom-right quadrant; its own centre is the frame's 0.75, 0.75.
        let quadrant = NormRect(x1: 0.5, y1: 0.5, x2: 1.0, y2: 1.0)
        let centre = quadrant.project(NormRect(x1: 0.5, y1: 0.5, x2: 0.5, y2: 0.5))
        XCTAssertEqual(centre.x1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(centre.y1, 0.75, accuracy: 1e-9)
    }

    func testZeroAreaRectCannotBeLocalizedInto() {
        let empty = NormRect(x1: 0.5, y1: 0.5, x2: 0.5, y2: 0.5)
        XCTAssertNil(empty.localize(.full))
    }

    func testParsesBothSpellings() {
        let corners = NormRect.from(
            .object(["x1": .number(0.1), "y1": .number(0.2), "x2": .number(0.3), "y2": .number(0.4)]))
        XCTAssertEqual(corners?.x2, 0.3)
        let sized = NormRect.from(
            .object(["x": .number(0.1), "y": .number(0.2), "w": .number(0.2), "h": .number(0.2)]))
        XCTAssertEqual(sized?.x2 ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertNil(NormRect.from(.object(["nonsense": .bool(true)])))
    }
}

@MainActor
final class FrameStoreTests: XCTestCase {
    func testAFreshFrameIsItsOwnRootAndCoversItself() {
        let store = FrameStore()
        let frame = store.register(image: makeImage(100, 50), source: "android")
        XCTAssertEqual(frame.rootId, frame.id)
        XCTAssertEqual(frame.originRect, .full)
        XCTAssertFalse(frame.isCrop)
        // On a whole frame, local and root coordinates coincide.
        let box = NormRect(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4)
        XCTAssertEqual(frame.toRoot(box), box)
    }

    /// The invariant the whole design rests on: something found inside a crop
    /// reports where it is on the *screen*, not where it is in the crop.
    func testACropReportsFindingsInRootCoordinates() {
        let store = FrameStore()
        let full = store.register(image: makeImage(1000, 1000), source: "android")
        let area = NormRect(x1: 0.5, y1: 0.5, x2: 1.0, y2: 1.0)
        let crop = store.registerCrop(
            of: full, root: area, image: full.pixels(in: area)!)

        XCTAssertTrue(crop.isCrop)
        XCTAssertEqual(crop.rootId, full.id)
        // Dead centre of the crop is three-quarters across the screen.
        let centre = crop.toRoot(NormRect(x1: 0.5, y1: 0.5, x2: 0.5, y2: 0.5))
        XCTAssertEqual(centre.x1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(centre.y1, 0.75, accuracy: 1e-9)
    }

    /// And it has to survive nesting, or `regions → crop → regions → crop`
    /// silently drifts.
    func testCropOfACropStillProjectsToTheRoot() {
        let store = FrameStore()
        let full = store.register(image: makeImage(1000, 1000), source: "android")
        let half = NormRect(x1: 0.5, y1: 0.5, x2: 1.0, y2: 1.0)
        let crop1 = store.registerCrop(of: full, root: half, image: full.pixels(in: half)!)

        // Take the bottom-right quarter *of the crop*, in root coordinates.
        let inner = crop1.toRoot(NormRect(x1: 0.5, y1: 0.5, x2: 1.0, y2: 1.0))
        XCTAssertEqual(inner.x1, 0.75, accuracy: 1e-9)
        let crop2 = store.registerCrop(of: crop1, root: inner, image: crop1.pixels(in: inner)!)

        XCTAssertEqual(crop2.rootId, full.id, "a nested crop still belongs to the original frame")
        let centre = crop2.toRoot(NormRect(x1: 0.5, y1: 0.5, x2: 0.5, y2: 0.5))
        XCTAssertEqual(centre.x1, 0.875, accuracy: 1e-9)
        XCTAssertEqual(centre.y1, 0.875, accuracy: 1e-9)
    }

    func testPixelsOutsideTheFrameAreRefused() {
        let store = FrameStore()
        let frame = store.register(image: makeImage(100, 100), source: "android")
        let crop = store.registerCrop(
            of: frame, root: NormRect(x1: 0, y1: 0, x2: 0.2, y2: 0.2),
            image: frame.pixels(in: NormRect(x1: 0, y1: 0, x2: 0.2, y2: 0.2))!)
        // A root area in the far corner has no overlap with a top-left crop.
        XCTAssertNil(crop.pixels(in: NormRect(x1: 0.9, y1: 0.9, x2: 1.0, y2: 1.0)))
    }

    func testTheOldestFrameIsEvictedAndSaysSo() throws {
        let store = FrameStore(capacity: 3)
        let first = store.register(image: makeImage(10, 10), source: "android")
        for _ in 0..<3 { store.register(image: makeImage(10, 10), source: "android") }
        XCTAssertEqual(store.count, 3)
        XCTAssertNil(store.frame(first.id))

        // An evicted id must not read as a typo, and must not silently fall
        // back to a different frame.
        XCTAssertThrowsError(try store.require(first.id)) { error in
            let message = (error as? ToolFailure)?.message ?? ""
            XCTAssertTrue(message.contains(first.id), message)
            XCTAssertTrue(message.contains("only the last 3"), message)
        }
    }

    func testAnOmittedFrameIdMeansTheMostRecent() throws {
        let store = FrameStore()
        store.register(image: makeImage(10, 10), source: "android")
        let newest = store.register(image: makeImage(20, 20), source: "android")
        XCTAssertEqual(try store.require(nil).id, newest.id)
        XCTAssertEqual(try store.require("").id, newest.id)
    }

    func testRequiringAFrameBeforeAnyCaptureExplainsHowToGetOne() {
        XCTAssertThrowsError(try FrameStore().require(nil)) { error in
            let message = (error as? ToolFailure)?.message ?? ""
            XCTAssertTrue(message.contains("android_observe"), message)
        }
    }

    /// Region ids restart per frame, so `(frame_id, region_id)` is the address.
    func testRegionIdsAreScopedToTheirFrame() {
        let store = FrameStore()
        let a = store.register(image: makeImage(10, 10), source: "android")
        let b = store.register(image: makeImage(10, 10), source: "android")
        _ = a.setRegions([(NormRect(x1: 0, y1: 0, x2: 0.1, y2: 0.1), .textLike, 0.9)])
        _ = b.setRegions([(NormRect(x1: 0.9, y1: 0.9, x2: 1, y2: 1), .salient, 0.5)])
        XCTAssertEqual(a.region("r1")?.kind, .textLike)
        XCTAssertEqual(b.region("r1")?.kind, .salient)
        XCTAssertNil(a.region("r2"))
    }
}

final class ImageDiffMathTests: XCTestCase {
    /// Adjacent changed cells should come back as one area, not as a cloud of
    /// coordinates — including diagonally adjacent ones.
    func testTouchingCellsMergeIntoOneArea() {
        let cells = [(1, 1), (2, 1), (1, 2), (2, 2), (3, 3)]
        let boxes = ImageDiffTool.merge(cells, cols: 10, rows: 10)
        XCTAssertEqual(boxes.count, 1, "diagonal contact should join the blocks")
        XCTAssertEqual(boxes[0].x1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(boxes[0].x2, 0.4, accuracy: 1e-9)
    }

    func testSeparateChangesStaySeparate() {
        let boxes = ImageDiffTool.merge([(0, 0), (9, 9)], cols: 10, rows: 10)
        XCTAssertEqual(boxes.count, 2)
    }

    func testLargestAreaComesFirst() {
        let boxes = ImageDiffTool.merge([(9, 9), (0, 0), (1, 0), (0, 1), (1, 1)], cols: 10, rows: 10)
        XCTAssertGreaterThan(boxes[0].width * boxes[0].height, boxes[1].width * boxes[1].height)
    }

    func testIdenticalImagesAreZeroDistance() throws {
        let image = makeImage(64, 64, gray: 0.4)
        let a = try ImageDiffTool.sample(image, cols: 8, rows: 8)
        let b = try ImageDiffTool.sample(image, cols: 8, rows: 8)
        for index in a.indices {
            XCTAssertEqual(ImageDiffTool.distance(a[index], b[index]), 0, accuracy: 1e-6)
        }
    }

    func testDifferentImagesAreNotZeroDistance() throws {
        let a = try ImageDiffTool.sample(makeImage(64, 64, gray: 0.1), cols: 8, rows: 8)
        let b = try ImageDiffTool.sample(makeImage(64, 64, gray: 0.9), cols: 8, rows: 8)
        XCTAssertGreaterThan(ImageDiffTool.distance(a[0], b[0]), 0.5)
    }
}

/// Decoding a screenshot the way the server actually receives it — base64 from
/// the Rust bridge, not a file. That distinction is not academic: bridging a
/// `Data(base64Encoded:)` straight to `CFData` killed the process inside
/// ImageIO's PNG reader with SIGBUS, while the identical PNG loaded from disk
/// decoded fine and a file-based test stayed green.
final class ImageDecodeTests: XCTestCase {
    /// A real PNG, encoded the way `android_observe` delivers one.
    private func pngBase64(_ w: Int, _ h: Int) throws -> String {
        let image = makeImage(w, h, gray: 0.3)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        return data.base64EncodedString()
    }

    func testDecodesAPNGArrivingAsBase64() throws {
        let decoded = ImageCoding.decode(base64: try pngBase64(1336, 752))
        XCTAssertEqual(decoded?.width, 1336)
        XCTAssertEqual(decoded?.height, 752)
    }

    func testRejectsRubbishInsteadOfFaulting() {
        XCTAssertNil(ImageCoding.decode(base64: ""))
        XCTAssertNil(ImageCoding.decode(base64: "not base64 at all !!!"))
        // Valid base64, but not an image.
        XCTAssertNil(ImageCoding.decode(base64: Data("hello".utf8).base64EncodedString()))
    }
}

/// Observations have a lifetime. A frame captured before an action describes a
/// world that no longer exists, and reading it returns numbers that look
/// plausible and are wrong — which is precisely how it misleads. The store
/// refuses it rather than relying on anyone to remember.
@MainActor
final class FrameStalenessTests: XCTestCase {
    private func makeStore() -> FrameStore { FrameStore() }

    func testAFrameIsReadableUntilTheWorldChanges() throws {
        let store = makeStore()
        let frame = store.register(image: makeImage(40, 40), source: "android")
        XCTAssertEqual(try store.require(frame.id).id, frame.id)

        store.worldChanged()
        XCTAssertThrowsError(try store.require(frame.id)) { error in
            let message = (error as? ToolFailure)?.message ?? ""
            XCTAssertTrue(message.contains("stale_frame"), message)
            XCTAssertTrue(message.contains("recovery"), message)
            XCTAssertTrue(message.contains(frame.id), message)
        }
    }

    /// The error has to say how far behind it is, not merely that it is behind.
    func testTheStaleErrorReportsBothEpochs() throws {
        let store = makeStore()
        let frame = store.register(image: makeImage(40, 40), source: "android")
        store.worldChanged()
        store.worldChanged()
        do {
            _ = try store.require(frame.id)
            XCTFail("a two-actions-old frame should be refused")
        } catch {
            let payload = try JSONValue.parse((error as? ToolFailure)?.message ?? "")
            XCTAssertEqual(payload["error"]?.stringValue, "stale_frame")
            XCTAssertEqual(payload["captured_epoch"]?.intValue, 0)
            XCTAssertEqual(payload["current_epoch"]?.intValue, 2)
            XCTAssertEqual(payload["actions_since"]?.intValue, 2)
        }
    }

    /// image_diff exists to compare before with after, so it must be allowed to
    /// read an old frame.
    func testStaleFramesAreStillReadableWhenExplicitlyAllowed() throws {
        let store = makeStore()
        let frame = store.register(image: makeImage(40, 40), source: "android")
        store.worldChanged()
        XCTAssertEqual(try store.require(frame.id, allowStale: true).id, frame.id)
    }

    func testACaptureAfterTheActionIsFreshAgain() throws {
        let store = makeStore()
        _ = store.register(image: makeImage(40, 40), source: "android")
        store.worldChanged()
        let newer = store.register(image: makeImage(40, 40), source: "android")
        XCTAssertEqual(try store.require(newer.id).id, newer.id)
        XCTAssertEqual(try store.require(nil).id, newer.id)
    }

    /// A crop is exactly as current as the frame it came from — no fresher, and
    /// no more stale.
    func testACropInheritsItsParentsFreshness() throws {
        let store = makeStore()
        let parent = store.register(image: makeImage(100, 100), source: "android")
        let area = NormRect(x1: 0, y1: 0, x2: 0.5, y2: 0.5)
        let crop = store.registerCrop(of: parent, root: area, image: parent.pixels(in: area)!)
        XCTAssertEqual(crop.observedEpoch, parent.observedEpoch)
        XCTAssertNoThrow(try store.require(crop.id))

        store.worldChanged()
        XCTAssertThrowsError(try store.require(crop.id), "a crop of a stale frame is stale")
    }

    /// An omitted frame_id must mean "the screen", not "the last thing I made".
    /// Resolving to the most recent frame would redirect observe -> crop -> ocr
    /// onto the crop, which reads as a tool failing to see something plainly
    /// on screen.
    func testAnOmittedIdMeansTheLastCaptureNotTheLastCrop() throws {
        let store = makeStore()
        let capture = store.register(image: makeImage(100, 100), source: "android")
        let area = NormRect(x1: 0, y1: 0, x2: 0.5, y2: 0.5)
        let crop = store.registerCrop(of: capture, root: area, image: capture.pixels(in: area)!)

        XCTAssertEqual(store.latest?.id, crop.id, "the crop really is the most recent frame")
        XCTAssertEqual(store.latestCapture?.id, capture.id)
        XCTAssertEqual(try store.require(nil).id, capture.id, "an omitted id must skip the crop")
    }
}
