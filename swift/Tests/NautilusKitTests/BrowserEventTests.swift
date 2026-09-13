import BrowserAX
import XCTest

@testable import NautilusKit

/// The queue is the one part of the recorder that can be tested without a
/// browser, a person and an Accessibility grant. The rest — whether Safari
/// actually reports a click, whether a tap survives being slow — is only ever
/// established by running it, the same way the ImageIO fault was.
final class BrowserEventQueueTests: XCTestCase {
    func testSequenceNumbersAreIssuedInOrderAndNeverReused() {
        let queue = BrowserEventQueue(capacity: 10)
        let first = queue.append(BrowserEvent(kind: .click))
        let second = queue.append(BrowserEvent(kind: .scroll))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(queue.latestSeq, 2)
    }

    func testReadAfterReturnsOnlyWhatIsNew() {
        let queue = BrowserEventQueue(capacity: 10)
        for _ in 0..<5 { queue.append(BrowserEvent(kind: .click)) }
        let page = queue.read(after: 3)
        XCTAssertEqual(page.events.map(\.seq), [4, 5])
        XCTAssertFalse(page.more)
    }

    func testOldestAreDroppedAtCapacityAndTheLossIsReported() {
        let queue = BrowserEventQueue(capacity: 3)
        for _ in 0..<5 { queue.append(BrowserEvent(kind: .click)) }
        let page = queue.read()
        // A reader must not be handed a gap dressed up as continuity — the same
        // reason a stale frame is refused rather than quietly returned.
        XCTAssertEqual(page.events.map(\.seq), [3, 4, 5])
        XCTAssertEqual(page.dropped, 2)
        XCTAssertEqual(page.latest, 5)
    }

    func testLimitReportsThatMoreIsWaiting() {
        let queue = BrowserEventQueue(capacity: 10)
        for _ in 0..<5 { queue.append(BrowserEvent(kind: .click)) }
        let page = queue.read(after: 0, limit: 2)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertTrue(page.more)
    }

    func testClearingKeepsSequenceNumbersMovingForward() {
        let queue = BrowserEventQueue(capacity: 10)
        queue.append(BrowserEvent(kind: .click))
        queue.clear()
        // Restarting the numbering would make a reader's `after_seq` cursor
        // silently match events it has already seen.
        XCTAssertEqual(queue.append(BrowserEvent(kind: .click)), 2)
        XCTAssertEqual(queue.read().events.map(\.seq), [2])
    }

    func testObserversAreCalledOnceForEachEvent() {
        let queue = BrowserEventQueue(capacity: 10)
        let seen = Locked<[UInt64]>([])
        queue.observe { event in seen.withLock { $0.append(event.seq) } }
        queue.append(BrowserEvent(kind: .click))
        queue.append(BrowserEvent(kind: .navigate))
        XCTAssertEqual(seen.withLock { $0 }, [1, 2])
    }

    func testDescribeOmitsWhatIsEmptyAndTruncatesWhatIsLong() {
        let event = BrowserEvent(
            seq: 7, kind: .input, source: .agent, role: "textbox", name: "",
            value: String(repeating: "x", count: 300))
        guard case .object(let object) = BrowserEventsReadTool.describe(event) else {
            return XCTFail("expected an object")
        }
        XCTAssertNil(object["name"], "an empty name is noise in a listing")
        XCTAssertEqual(object["source"]?.stringValue, "agent")
        XCTAssertEqual(object["value"]?.stringValue?.count, 201)  // 200 + ellipsis
    }
}

/// Minimal box so the observer test can collect from whatever thread calls it.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
