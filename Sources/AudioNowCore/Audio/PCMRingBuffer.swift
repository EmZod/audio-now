import Foundation
import Synchronization

/// Lock-free SPSC ring for float32 samples.
/// Producer: the worker pipe reader thread. Consumer: Core Audio's
/// real-time thread. Head/tail are monotonically increasing sample counts
/// (no empty/full ambiguity); power-of-two capacity for mask indexing.
///
/// The bounded capacity is the system's backpressure mechanism: when the
/// ring is full the producer stops reading the worker pipe, the kernel
/// pipe fills, the worker's stdout write blocks, and generation throttles
/// to realtime.
public final class PCMRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)   // producer-advanced
    private let tail = Atomic<Int>(0)   // consumer-advanced

    public init(seconds: Double, sampleRate: Int = 24_000) {
        var cap = 1
        while cap < Int(seconds * Double(sampleRate)) { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
    }

    deinit { storage.deallocate() }

    public var availableToRead: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    public var freeSpace: Int {
        capacity - (head.load(ordering: .relaxed) - tail.load(ordering: .acquiring))
    }

    /// Producer only. false = full (caller sleep-polls; that IS backpressure).
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {
        guard freeSpace >= count else { return false }
        let h = head.load(ordering: .relaxed)
        let first = min(count, capacity - (h & mask))
        memcpy(storage + (h & mask), src, first * 4)
        if count > first {
            memcpy(storage, src + first, (count - first) * 4)
        }
        head.store(h + count, ordering: .releasing)
        return true
    }

    /// Consumer (real-time thread) only. Returns samples actually copied.
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let n = min(count, head.load(ordering: .acquiring) - t)
        guard n > 0 else { return 0 }
        let first = min(n, capacity - (t & mask))
        memcpy(dst, storage + (t & mask), first * 4)
        if n > first {
            memcpy(dst + first, storage, (n - first) * 4)
        }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    /// Consumer-side flush (used by the fade-out completion and stop).
    public func discardAllFromConsumer() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
    }
}
