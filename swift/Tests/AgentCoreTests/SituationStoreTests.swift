import XCTest

@testable import AgentCore

/// `SituationStore` is the Swift twin of Rust's `SituationMessages`, and the two
/// have to stay in step: the same observations must reach the model the same way
/// whichever backend is running.
final class SituationStoreTests: XCTestCase {

    func testReadsBackWhatWasPushed() {
        let store = SituationStore()
        store.push(text: "Windows: Safari", source: "screen")
        let entries = store.read()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].contains("Windows: Safari"))
        XCTAssertTrue(entries[0].contains("screen"), "the source should be visible: \(entries[0])")
    }

    func testEmptyStoreReadsEmpty() {
        XCTAssertTrue(SituationStore().read().isEmpty)
    }

    func testOldestAreDroppedAtTheCap() {
        let store = SituationStore(ttl: 600, maxMessages: 3)
        for i in 0..<10 { store.push(text: "entry \(i)", source: "screen") }

        let entries = store.read()
        XCTAssertEqual(entries.count, 3, "the cap must bound the store")
        XCTAssertTrue(entries[0].contains("entry 7"), "oldest dropped first: \(entries)")
        XCTAssertTrue(entries[2].contains("entry 9"))
    }

    /// The reason the cap exists: TTL alone doesn't bound anything. A producer
    /// polling every 30s against a 10-minute window keeps 20 entries alive, and
    /// the agent reads all of them.
    func testCapBoundsAChattyProducer() {
        let store = SituationStore()  // defaults
        for i in 0..<500 { store.push(text: "poll \(i)", source: "screen") }
        XCTAssertEqual(store.count(), SituationStore.defaultMaxMessages)
    }

    func testExpiredEntriesAreDropped() {
        let store = SituationStore(ttl: 0.05, maxMessages: 100)
        store.push(text: "stale", source: "screen")
        XCTAssertEqual(store.count(), 1)

        let expired = expectation(description: "ttl elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { expired.fulfill() }
        wait(for: [expired], timeout: 2)

        XCTAssertEqual(store.count(), 0, "entries past the TTL must not be read back")
    }

    func testResetClearsEverything() {
        let store = SituationStore()
        store.push(text: "a", source: "screen")
        store.clear()
        XCTAssertTrue(store.read().isEmpty)
    }

    /// The defaults are the contract shared with `situation.rs`; changing one
    /// side without the other is the divergence this consolidation removed.
    func testDefaultsMatchTheRustStore() {
        XCTAssertEqual(SituationStore.defaultTTL, 600, "situation.rs uses a 600s TTL")
        XCTAssertEqual(
            SituationStore.defaultMaxMessages, 20,
            "situation.rs uses DEFAULT_MAX_MESSAGES = 20"
        )
    }
}
