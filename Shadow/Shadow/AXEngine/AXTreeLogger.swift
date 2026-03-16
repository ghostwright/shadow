import Cocoa
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AXTreeLogger")

/// Integrates AX tree capture with Shadow's event pipeline.
///
/// Listens to WindowTracker events and captures AX snapshots on:
/// - App switches (lightweight focused element capture)
/// - Window title changes (lightweight focused element capture)
/// - Periodic timer (every 10 seconds during active use, Mimicry Phase A2)
/// - Explicit full snapshot requests (before/after agent actions, learning mode)
///
/// Uses FNV-1a tree hashing for deduplication — skips capture if the tree
/// hasn't changed since the last snapshot.
///
/// Snapshots are stored as compressed JSON in `~/.shadow/data/ax_snapshots/`
/// and indexed in the `ax_snapshots` SQLite table for behavioral search.
///
/// @MainActor because all AX API calls and EventWriter calls must be on main thread.
@MainActor
final class AXTreeLogger {
    /// Hash of the last captured tree, used for dedup.
    private var lastTreeHash: UInt64 = 0

    /// Timestamp of the last capture in microseconds.
    private var lastCaptureTime: UInt64 = 0

    /// Minimum interval between captures (1 second).
    private let minIntervalUs: UInt64 = 1_000_000

    /// When false, all captures are suppressed.
    var isEnabled = true

    /// Debounce timer for title changes and input events.
    private var debounceTask: Task<Void, Never>?

    /// Periodic snapshot timer (Mimicry Phase A2).
    private var periodicTimer: Timer?

    /// Interval between periodic snapshots (seconds).
    private static let periodicIntervalSeconds: TimeInterval = 10.0

    /// Timestamp of last user activity (mouse/key event), used to suppress
    /// periodic captures during idle periods.
    private var lastActivityTime: UInt64 = 0

    /// Maximum idle time before suppressing periodic captures (30 seconds).
    private static let maxIdleUs: UInt64 = 30_000_000

    /// Total snapshots captured this session (diagnostics).
    private(set) var snapshotsCapturedTotal: Int = 0

    /// Total snapshots stored to disk this session (diagnostics).
    private(set) var snapshotsStoredTotal: Int = 0

    /// Base directory for snapshot storage.
    private let snapshotDirectory: URL

    init() {
        self.snapshotDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/data/ax_snapshots")
    }

    // MARK: - Periodic Capture (Mimicry Phase A2)

    /// Start periodic AX tree captures. Call after permissions are confirmed.
    func startPeriodicCapture() {
        guard periodicTimer == nil else { return }
        periodicTimer = Timer.scheduledTimer(
            withTimeInterval: Self.periodicIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.capturePeriodicSnapshot()
            }
        }
        logger.info("Periodic AX snapshot capture started (every \(Self.periodicIntervalSeconds)s)")
    }

    /// Stop periodic captures.
    func stopPeriodicCapture() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    /// Record that the user is active (called by InputMonitor or WindowTracker).
    /// Prevents periodic captures from firing during idle periods.
    func recordUserActivity() {
        lastActivityTime = CaptureSessionClock.wallMicros()
    }

    /// Periodic snapshot capture — fires every 10 seconds when user is active.
    private func capturePeriodicSnapshot() {
        guard isEnabled else { return }
        let now = CaptureSessionClock.wallMicros()

        // Only capture if user has been active recently
        guard lastActivityTime > 0 && (now - lastActivityTime) < Self.maxIdleUs else { return }

        // Respect minimum interval
        guard now - lastCaptureTime >= minIntervalUs else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        let pid = frontApp.processIdentifier
        let snapshot = captureAndStore(pid: pid, trigger: "periodic")
        if snapshot != nil {
            DiagnosticsStore.shared.increment("ax_periodic_snapshot_total")
        }
    }

    // MARK: - App Switch Capture

    /// Called by WindowTracker on app switch. Captures focused element (lightweight).
    func onAppSwitch(app: NSRunningApplication) {
        guard isEnabled else { return }
        let now = CaptureSessionClock.wallMicros()
        guard now - lastCaptureTime >= minIntervalUs else { return }

        let pid = app.processIdentifier
        let appElement = ShadowElement.application(pid: pid)
        let appName = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier ?? ""

        let windowTitle: String?
        if let w = appElement.focusedWindow() {
            windowTitle = w.title()
        } else {
            windowTitle = nil
        }

        // Capture focused element data (lightweight, ~1ms)
        if let focused = appElement.focusedUIElement() {
            emitFocusedElement(
                appName: appName, bundleId: bundleId,
                windowTitle: windowTitle, element: focused, pid: pid)
        }

        lastCaptureTime = now

        // Also capture a full snapshot on app switch (Mimicry Phase A2)
        _ = captureAndStore(pid: pid, trigger: "app_switch")
    }

    // MARK: - Title Change Capture (Debounced)

    /// Called when window title changes. Debounced to 200ms to avoid noise.
    func onWindowTitleChanged(app: NSRunningApplication) {
        guard isEnabled else { return }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            guard !Task.isCancelled else { return }

            let now = CaptureSessionClock.wallMicros()
            guard now - self.lastCaptureTime >= self.minIntervalUs else { return }

            let pid = app.processIdentifier
            let appElement = ShadowElement.application(pid: pid)
            let appName = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier ?? ""

            let windowTitle: String?
            if let w = appElement.focusedWindow() {
                windowTitle = w.title()
            } else {
                windowTitle = nil
            }

            if let focused = appElement.focusedUIElement() {
                self.emitFocusedElement(
                    appName: appName, bundleId: bundleId,
                    windowTitle: windowTitle, element: focused, pid: pid)
            }

            self.lastCaptureTime = now
        }
    }

    // MARK: - Full Snapshot Capture

    /// Capture a full AX tree snapshot. Used before/after agent actions and during learning mode.
    /// Returns the snapshot data if the tree changed, nil if unchanged or if capture failed.
    func captureFullSnapshot(
        pid: pid_t, trigger: String
    ) -> AXTreeSnapshotData? {
        return captureAndStore(pid: pid, trigger: trigger)
    }

    // MARK: - Capture + Store Pipeline

    /// Capture an AX tree snapshot and store it to disk + index.
    /// Returns the snapshot data if the tree changed, nil if unchanged or if capture failed.
    private func captureAndStore(pid: pid_t, trigger: String) -> AXTreeSnapshotData? {
        let appElement = ShadowElement.application(pid: pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            logger.warning("Cannot capture snapshot: no running app for PID \(pid)")
            return nil
        }

        let snapshot = captureAXTree(
            app: appElement,
            appName: app.localizedName ?? "Unknown",
            bundleId: app.bundleIdentifier ?? "",
            windowTitle: appElement.focusedWindow()?.title(),
            displayId: nil,
            maxDepth: 15,
            maxNodes: 500,
            timeout: 0.2
        )

        guard let snapshot else {
            logger.debug("AX tree capture returned empty for PID \(pid)")
            return nil
        }

        // Dedup: skip if tree hash matches
        guard snapshot.treeHash != lastTreeHash else {
            logger.debug("AX tree unchanged (hash: \(snapshot.treeHash))")
            return nil
        }
        lastTreeHash = snapshot.treeHash
        snapshotsCapturedTotal += 1

        // Emit event to the event pipeline
        EventWriter.axTreeSnapshot(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            trigger: trigger,
            nodeCount: snapshot.nodeCount,
            treeHash: snapshot.treeHash
        )

        // Store snapshot to disk (async, non-blocking)
        storeSnapshotToDisk(snapshot, trigger: trigger)

        logger.info("AX snapshot captured: \(snapshot.nodeCount) nodes, trigger=\(trigger)")
        return snapshot
    }

    // MARK: - Snapshot Storage (Mimicry Phase A2)

    /// Store a snapshot as compressed JSON to disk and index it.
    private func storeSnapshotToDisk(_ snapshot: AXTreeSnapshotData, trigger: String) {
        let fm = FileManager.default
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = snapshotDirectory.appendingPathComponent(
            dateFormatter.string(from: Date()))

        // Ensure day directory exists
        if !fm.fileExists(atPath: dayDir.path) {
            do {
                try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create snapshot directory: \(error, privacy: .public)")
                return
            }
        }

        // Filename: timestamp in microseconds
        let filename = "\(snapshot.timestampUs).json"
        let filePath = dayDir.appendingPathComponent(filename)

        do {
            let encoder = JSONEncoder()
            // Use compact encoding to save space (no pretty-printing)
            let data = try encoder.encode(snapshot)
            try data.write(to: filePath, options: .atomic)
            snapshotsStoredTotal += 1

            // Index in the SQLite timeline
            do {
                try insertAxSnapshot(
                    timestampUs: snapshot.timestampUs,
                    appBundleId: snapshot.appBundleId,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    displayId: snapshot.displayId,
                    treeHash: snapshot.treeHash,
                    nodeCount: UInt32(snapshot.nodeCount),
                    trigger: trigger
                )
            } catch {
                logger.warning("Failed to index AX snapshot: \(error, privacy: .public)")
            }
        } catch {
            logger.error("Failed to store AX snapshot: \(error, privacy: .public)")
        }
    }

    // MARK: - Private Helpers

    private func emitFocusedElement(
        appName: String, bundleId: String,
        windowTitle: String?, element: ShadowElement, pid: pid_t
    ) {
        let role = element.role() ?? "AXUnknown"
        let title = element.title()
        let value = element.value().map { String($0.prefix(200)) }
        let identifier = element.identifier()

        let editableRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
        ]

        EventWriter.axFocusEvent(
            appName: appName, bundleId: bundleId,
            windowTitle: windowTitle,
            role: role, title: title, value: value,
            identifier: identifier,
            editable: editableRoles.contains(role),
            pid: pid
        )
    }
}
