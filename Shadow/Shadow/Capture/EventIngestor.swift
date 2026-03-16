import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "EventIngestor")

/// Event priority for backpressure policy.
/// Critical events are never dropped unless the system is in hard failure.
enum EventPriority: Sendable {
    /// Must not be dropped: key_down, mouse_down, app_switch, lifecycle events.
    case critical
    /// Can be evicted under pressure: mouse_move, scroll, title_changed.
    case normal
}

/// Non-blocking event ingest pipeline.
///
/// Decouples high-frequency callback paths (CGEventTap, notifications) from
/// the storage write path. Callbacks enqueue lightweight event data; a dedicated
/// writer task drains the queue in batches and writes to Rust storage.
///
/// Backpressure policy: when queue is full, evict oldest normal-priority events
/// to make room for critical events. Normal events are dropped when no capacity.
///
/// Thread-safe: enqueue() can be called from any thread (event tap callback,
/// main thread, etc.). The writer runs on a dedicated dispatch queue.
final class EventIngestor: @unchecked Sendable {

    /// Maximum number of events the queue can hold before applying backpressure.
    private let maxQueueSize: Int = 8192

    /// Maximum events per batch write.
    private let maxBatchSize: Int = 128

    /// Maximum wait time before flushing a partial batch (seconds).
    private let maxBatchWait: TimeInterval = 0.1

    // Queue storage — lock-protected for thread safety.
    // Using NSLock for minimal overhead on the hot path.
    private let lock = NSLock()
    private var queue: [(data: Data, priority: EventPriority)] = []
    private var running = false

    // Writer dispatch
    private let writerQueue = DispatchQueue(label: "com.shadow.ingestor.writer", qos: .utility)
    private var writerSource: DispatchSourceTimer?

    // MARK: - Lifecycle

    /// Start the background writer. Call once at capture startup.
    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        queue.reserveCapacity(1024)
        lock.unlock()

        // Timer-based drain: fires every maxBatchWait to flush partial batches
        let source = DispatchSource.makeTimerSource(queue: writerQueue)
        source.schedule(deadline: .now() + maxBatchWait, repeating: maxBatchWait)
        source.setEventHandler { [weak self] in
            self?.drainQueue()
        }
        source.resume()
        writerSource = source

        logger.info("Event ingestor started (queue capacity: \(self.maxQueueSize), batch: \(self.maxBatchSize))")
    }

    /// Stop the writer and drain all remaining events. Blocks until the queue
    /// is completely empty and all pending writes have completed.
    func stop() {
        lock.lock()
        running = false
        lock.unlock()

        writerSource?.cancel()
        writerSource = nil

        // Deterministic drain: loop on the writer queue until fully empty.
        // Each drainQueue() call processes up to maxBatchSize events.
        writerQueue.sync { [self] in
            while true {
                self.lock.lock()
                let isEmpty = self.queue.isEmpty
                self.lock.unlock()
                if isEmpty { break }
                self.drainQueue()
            }
        }

        logger.info("Event ingestor stopped")
    }

    // MARK: - Enqueue (Hot Path)

    /// Enqueue a serialized event for batch writing.
    /// This is the hot path — must be fast and never block on I/O.
    ///
    /// Backpressure policy:
    /// - Critical events evict the oldest normal-priority event when queue is full.
    /// - Normal events are dropped when queue is full.
    /// Returns true if enqueued, false if dropped.
    @discardableResult
    func enqueue(_ data: Data, priority: EventPriority = .normal) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard running else { return false }

        DiagnosticsStore.shared.increment("ingest_events_received_total")

        if queue.count >= maxQueueSize {
            switch priority {
            case .critical:
                // Evict the oldest normal-priority event to make room
                if let normalIndex = queue.firstIndex(where: { $0.priority == .normal }) {
                    queue.remove(at: normalIndex)
                    DiagnosticsStore.shared.increment("ingest_events_dropped_total")
                    DiagnosticsStore.shared.increment("ingest_events_dropped_evicted_total")
                } else {
                    // Queue is entirely critical events — drop the oldest to stay bounded.
                    // Strict bounded contract: queue must never exceed maxQueueSize.
                    queue.removeFirst()
                    DiagnosticsStore.shared.increment("ingest_events_dropped_total")
                    DiagnosticsStore.shared.increment("ingest_events_dropped_critical_overflow_total")
                }
            case .normal:
                DiagnosticsStore.shared.increment("ingest_events_dropped_total")
                DiagnosticsStore.shared.increment("ingest_events_dropped_backpressure_total")
                return false
            }
        }

        queue.append((data: data, priority: priority))

        // If we've hit the batch threshold, wake the writer immediately
        if queue.count >= maxBatchSize {
            writerQueue.async { [weak self] in
                self?.drainQueue()
            }
        }

        return true
    }

    // MARK: - Drain (Writer Path)

    /// Drain queued events and write them to Rust storage in a batch.
    /// Runs on writerQueue only.
    private func drainQueue() {
        // Dequeue up to maxBatchSize events under lock
        lock.lock()
        guard !queue.isEmpty else {
            lock.unlock()
            return
        }
        let count = min(queue.count, maxBatchSize)
        let batch = Array(queue.prefix(count).map(\.data))
        queue.removeFirst(count)
        let remainingDepth = Int64(queue.count)
        lock.unlock()

        // Track queue depth for diagnostics
        DiagnosticsStore.shared.setGauge("ingest_queue_depth_current", value: Double(remainingDepth))
        DiagnosticsStore.shared.updateHighWater("ingest_queue_depth_high_watermark", value: remainingDepth + Int64(batch.count))

        // Write batch to Rust storage
        let writeStart = CFAbsoluteTimeGetCurrent()
        do {
            let written = try writeEventsBatch(events: batch)
            let writeMs = (CFAbsoluteTimeGetCurrent() - writeStart) * 1000
            DiagnosticsStore.shared.recordLatency("ingest_batch_write_ms", ms: writeMs)
            DiagnosticsStore.shared.increment("ingest_events_written_total", by: Int64(written))
            if written != UInt32(batch.count) {
                logger.warning("Batch write: \(written)/\(batch.count) events written (parse failures)")
            }
        } catch let error as ShadowError {
            logger.error("Batch write failed: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("ingest_batch_write_fail_total")

            // Structured error classification — no stringly-typed matching
            switch error {
            case .IndexError:
                DiagnosticsStore.shared.increment("timeline_index_insert_fail_total")
            default:
                break
            }

            DiagnosticsStore.shared.postWarning(
                severity: .error,
                subsystem: "EventIngestor",
                code: "INGEST_BATCH_WRITE_FAIL",
                message: "Batch write failed: \(error.localizedDescription)"
            )
        } catch {
            logger.error("Batch write failed (unexpected): \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("ingest_batch_write_fail_total")
            DiagnosticsStore.shared.postWarning(
                severity: .error,
                subsystem: "EventIngestor",
                code: "INGEST_BATCH_WRITE_FAIL",
                message: "Batch write failed: \(error.localizedDescription)"
            )
        }
    }
}
