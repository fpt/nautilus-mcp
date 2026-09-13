import XCTest

@testable import AgentCore

/// `AsyncGate` is what keeps two turns from calling `respond` on one
/// `LanguageModelSession`, and keeps `reset` from swapping a session out from
/// under a running response.
///
/// The property under test is mutual exclusion **across suspension points** —
/// precisely what an `actor` does not give you, and what an `NSLock` snapshot of
/// the session reference did not give either.
final class AsyncGateTests: XCTestCase {

    func testUncontendedAcquireReturnsImmediately() async {
        let gate = AsyncGate()
        await gate.acquire()
        gate.release()
        await gate.acquire()  // would hang if release() failed to free it
        gate.release()
    }

    /// The regression that motivated the gate: holders must not overlap around
    /// an `await`. A counter incremented inside the critical section exceeds 1
    /// the moment two holders interleave.
    func testOneHolderAtATimeAcrossSuspension() async {
        let gate = AsyncGate()
        let tracker = Tracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    await gate.acquire()
                    await tracker.enter()
                    // Suspend *while holding* — an actor would let another in here.
                    try? await Task.sleep(for: .milliseconds(2))
                    await tracker.exit()
                    gate.release()
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "gate admitted \(peak) holders at once")
        let completed = await tracker.completed
        XCTAssertEqual(completed, 25, "every waiter must eventually run")
    }

    /// Ownership is handed straight to the next waiter, so nobody is starved and
    /// nobody deadlocks waiting on a gate that was already released.
    func testEveryWaiterEventuallyRuns() async {
        let gate = AsyncGate()
        let tracker = Tracker()

        await gate.acquire()
        let waiters = (0..<10).map { _ in
            Task {
                await gate.acquire()
                await tracker.exit()
                gate.release()
            }
        }
        // Let them all park before handing the gate over.
        try? await Task.sleep(for: .milliseconds(20))
        gate.release()

        for w in waiters { await w.value }
        let completed = await tracker.completed
        XCTAssertEqual(completed, 10)
    }

    /// `release()` in a `defer` must free the gate even when the body throws.
    func testGateIsFreedWhenTheHolderThrows() async {
        struct Boom: Error {}
        let gate = AsyncGate()

        func failing() async throws {
            await gate.acquire()
            defer { gate.release() }
            throw Boom()
        }

        do { try await failing() } catch { /* expected */ }

        // Would hang forever if the throw leaked the gate.
        let reacquired = Task { await gate.acquire(); gate.release(); return true }
        let ok = await reacquired.value
        XCTAssertTrue(ok)
    }
}

private actor Tracker {
    private(set) var peak = 0
    private(set) var completed = 0
    private var current = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current = max(0, current - 1)
        completed += 1
    }
}
