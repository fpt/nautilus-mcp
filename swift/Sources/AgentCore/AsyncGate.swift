import Foundation

/// A mutual-exclusion gate for `async` work: at most one holder at a time,
/// **including across suspension points**.
///
/// An `actor` is not a substitute. Actors release their executor at every
/// `await`, so two calls into the same actor method interleave the moment one of
/// them suspends — which is exactly what happens around a multi-second model
/// response. Anything that must not overlap across a suspension needs this.
///
/// Ownership is handed directly from `release()` to the next waiter rather than
/// having waiters wake and re-contend: re-contention can starve a waiter, and an
/// early version that both set the flag *and* re-contended deadlocked against
/// itself. `release()` is synchronous so callers can `defer` it and free the
/// gate on every path, thrown errors included.
public final class AsyncGate: @unchecked Sendable {

    private let lock = NSLock()
    private var busy = false
    /// FIFO. Each parked continuation is resumed already owning the gate.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspend until the gate is free, then take it. On return the caller owns
    /// it and must `release()` exactly once.
    public init() {}

    public func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    /// Hand the gate to the next waiter, or free it when nobody is waiting.
    public func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
            return
        }
        // `busy` stays true: ownership moves to this waiter, it is never free.
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }
}
