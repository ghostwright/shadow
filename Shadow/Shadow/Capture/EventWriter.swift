import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "EventWriter")

// MARK: - Minimal MessagePack Encoder

/// Encodes simple key-value maps to MessagePack format for the Rust storage engine.
/// Supports: strings, unsigned integers, signed integers, nil.
///
/// This avoids a third-party MessagePack dependency. Our events are simple maps
/// with string keys and string/integer/nil values — trivial to encode directly.
enum MsgPack {

    /// Encode a dictionary of event fields to MessagePack bytes.
    static func encode(_ fields: [(String, MsgPackValue)]) -> Data {
        var data = Data()
        // Map header (fixmap for <=15 entries, map16 for <=65535)
        let count = fields.count
        precondition(count <= 65535, "MsgPack encoder: event has \(count) fields, max is 65535")
        if count <= 15 {
            data.append(UInt8(0x80 | count))
        } else {
            data.append(0xDE)
            data.append(UInt8((count >> 8) & 0xFF))
            data.append(UInt8(count & 0xFF))
        }
        // Key-value pairs
        for (key, value) in fields {
            encodeString(key, into: &data)
            encodeValue(value, into: &data)
        }
        return data
    }

    private static func encodeString(_ s: String, into data: inout Data) {
        let bytes = Array(s.utf8)
        let len = bytes.count
        if len <= 31 {
            data.append(UInt8(0xA0 | len))
        } else if len <= 255 {
            data.append(0xD9)
            data.append(UInt8(len))
        } else {
            data.append(0xDA)
            data.append(UInt8((len >> 8) & 0xFF))
            data.append(UInt8(len & 0xFF))
        }
        data.append(contentsOf: bytes)
    }

    private static func encodeValue(_ value: MsgPackValue, into data: inout Data) {
        switch value {
        case .string(let s):
            encodeString(s, into: &data)
        case .uint64(let n):
            data.append(0xCF)
            var big = n.bigEndian
            data.append(Data(bytes: &big, count: 8))
        case .uint32(let n):
            if n <= 127 {
                data.append(UInt8(n))
            } else {
                data.append(0xCE)
                var big = n.bigEndian
                data.append(Data(bytes: &big, count: 4))
            }
        case .uint8(let n):
            if n <= 127 {
                data.append(n)
            } else {
                data.append(0xCC)
                data.append(n)
            }
        case .int32(let n):
            if n >= 0 && n <= 127 {
                data.append(UInt8(n))
            } else if n >= 0 {
                data.append(0xCE)
                var big = UInt32(n).bigEndian
                data.append(Data(bytes: &big, count: 4))
            } else {
                data.append(0xD2)
                var big = n.bigEndian
                data.append(Data(bytes: &big, count: 4))
            }
        case .nil:
            data.append(0xC0)
        }
    }
}

enum MsgPackValue {
    case string(String)
    case uint64(UInt64)
    case uint32(UInt32)
    case uint8(UInt8)
    case int32(Int32)
    case `nil`
}

// MARK: - Event Writer

/// Bridges Swift capture events to the Rust storage engine.
/// Constructs MessagePack v2 envelopes and sends them via UniFFI writeEvent.
///
/// When `clock` is set, events include full v2 envelope fields (session_id,
/// seq, ts_mono_ns, source). When nil (shouldn't happen in normal operation),
/// events fall back to v1 format for backward compatibility.
enum EventWriter {

    /// Session clock — set once during capture startup, before first event.
    /// CaptureSessionClock is @unchecked Sendable with internal locking.
    nonisolated(unsafe) static var clock: CaptureSessionClock?

    /// Event ingestor — set during capture startup. When set, events are
    /// enqueued for batch writing instead of direct FFI calls.
    nonisolated(unsafe) static var ingestor: EventIngestor?

    /// Current timestamp in Unix microseconds.
    static func now() -> UInt64 {
        CaptureSessionClock.wallMicros()
    }

    // MARK: - Track 3: Window/App Context

    /// Write an app switch event (Track 3).
    static func appSwitch(
        appName: String,
        bundleID: String?,
        windowTitle: String?,
        url: String?,
        displayID: UInt32?,
        pid: Int32? = nil,
        windowFrame: CGRect? = nil
    ) {
        var fields = envelopeFields(
            track: .windowApp,
            type: "app_switch",
            source: .windowTracker,
            displayID: displayID,
            pid: pid,
            bundleID: bundleID
        )
        fields.append(("app_name", .string(appName)))
        if let windowTitle { fields.append(("window_title", .string(windowTitle))) }
        if let url { fields.append(("url", .string(url))) }
        if let frame = windowFrame {
            fields.append(("window_x", .int32(Int32(frame.origin.x))))
            fields.append(("window_y", .int32(Int32(frame.origin.y))))
            fields.append(("window_w", .int32(Int32(frame.width))))
            fields.append(("window_h", .int32(Int32(frame.height))))
        }

        send(fields, priority: .critical)
    }

    /// Write a window title change event (Track 3).
    static func windowTitleChanged(
        appName: String,
        windowTitle: String,
        url: String?,
        displayID: UInt32? = nil,
        pid: Int32? = nil,
        bundleID: String? = nil
    ) {
        var fields = envelopeFields(
            track: .windowApp,
            type: "window_title_changed",
            source: .windowTracker,
            displayID: displayID,
            pid: pid,
            bundleID: bundleID
        )
        fields.append(("app_name", .string(appName)))
        fields.append(("window_title", .string(windowTitle)))
        if let url { fields.append(("url", .string(url))) }

        send(fields, priority: .normal)
    }

    // MARK: - Track 2: Input

    /// Write an input event (Track 2).
    /// type: "key_down", "mouse_down", "mouse_up", "mouse_move", "scroll", "secure_field"
    static func inputEvent(type: String, details: [String: MsgPackValue], displayID: UInt32? = nil) {
        var fields = envelopeFields(
            track: .input,
            type: type,
            source: .inputMonitor,
            displayID: displayID
        )
        for (key, value) in details.sorted(by: { $0.key < $1.key }) {
            fields.append((key, value))
        }
        send(fields, priority: priorityFor(track: .input, type: type))
    }

    // MARK: - Track 4: Audio

    /// Write an audio metadata event (Track 4).
    /// Types: "audio_segment_open", "audio_segment_close"
    static func audioEvent(type: String, source: AudioSource, details: [String: MsgPackValue] = [:]) {
        var fields = envelopeFields(
            track: .audio,
            type: type,
            source: .audioCapture
        )
        fields.append(("audio_source", .string(source.rawValue)))
        for (key, value) in details.sorted(by: { $0.key < $1.key }) {
            fields.append((key, value))
        }
        send(fields, priority: .normal)
    }

    // MARK: - Track 3: AX Engine Events

    /// Write an AX focused element event (lightweight, on app switch / title change).
    static func axFocusEvent(
        appName: String, bundleId: String,
        windowTitle: String?,
        role: String, title: String?, value: String?,
        identifier: String?, editable: Bool,
        pid: pid_t
    ) {
        var fields = envelopeFields(
            track: .windowApp, type: "ax_focus",
            source: .axEngine, pid: pid,
            bundleID: bundleId
        )
        fields.append(("app_name", .string(appName)))
        if let wt = windowTitle { fields.append(("window_title", .string(wt))) }
        fields.append(("ax_role", .string(role)))
        if let t = title { fields.append(("ax_title", .string(t))) }
        if let v = value { fields.append(("ax_value", .string(v))) }
        if let i = identifier { fields.append(("ax_identifier", .string(i))) }
        fields.append(("ax_editable", .uint8(editable ? 1 : 0)))
        send(fields, priority: .normal)
    }

    /// Write an AX tree snapshot event (reference to full snapshot).
    static func axTreeSnapshot(
        appName: String, windowTitle: String?,
        trigger: String, nodeCount: Int, treeHash: UInt64
    ) {
        var fields = envelopeFields(
            track: .windowApp, type: "ax_tree_snapshot",
            source: .axEngine
        )
        fields.append(("app_name", .string(appName)))
        if let wt = windowTitle { fields.append(("window_title", .string(wt))) }
        fields.append(("trigger", .string(trigger)))
        fields.append(("node_count", .uint32(UInt32(nodeCount))))
        fields.append(("tree_hash", .uint64(treeHash)))
        send(fields, priority: .normal)
    }

    // MARK: - Track 0: Lifecycle Events

    /// Write a lifecycle event (Track 0).
    /// Types: "session_start", "session_end", "sleep_start", "wake_end", "clock_jump_detected"
    static func lifecycleEvent(type: String, details: [String: MsgPackValue] = [:]) {
        var fields = envelopeFields(
            track: .lifecycle,
            type: type,
            source: .lifecycle
        )
        for (key, value) in details.sorted(by: { $0.key < $1.key }) {
            fields.append((key, value))
        }
        send(fields, priority: .critical)
    }

    // MARK: - Envelope Construction

    /// Build the v2 envelope fields that start every event.
    /// Core fields (ts, track, type) are always present for v1 compat.
    /// v2 fields (v, ts_wall_us, ts_mono_ns, seq, session_id, source) added when clock is set.
    private static func envelopeFields(
        track: CaptureTrack,
        type: String,
        source: EventSource,
        displayID: UInt32? = nil,
        pid: Int32? = nil,
        bundleID: String? = nil
    ) -> [(String, MsgPackValue)] {
        let ts = now()
        var fields: [(String, MsgPackValue)] = [
            ("ts", .uint64(ts)),
            ("track", .uint8(track.rawValue)),
            ("type", .string(type)),
        ]

        // v2 envelope fields
        if let clock {
            fields.append(("v", .uint8(2)))
            fields.append(("ts_wall_us", .uint64(ts)))
            fields.append(("ts_mono_ns", .uint64(clock.monoNanos())))
            fields.append(("seq", .uint64(clock.nextSeq())))
            fields.append(("session_id", .string(clock.sessionId)))
            fields.append(("source", .string(source.rawValue)))
        }

        // Optional standard fields
        if let displayID {
            fields.append(("display_id", .uint32(displayID)))
        } else if track != .lifecycle && track != .audio {
            DiagnosticsStore.shared.increment("display_id_unknown_total")
        }
        if let pid { fields.append(("pid", .int32(pid))) }
        if let bundleID { fields.append(("bundle_id", .string(bundleID))) }

        return fields
    }

    // MARK: - Send

    private static func send(_ fields: [(String, MsgPackValue)], priority: EventPriority = .normal) {
        let data = MsgPack.encode(fields)

        if let ingestor {
            // Non-blocking path: enqueue for batch writing
            if !ingestor.enqueue(data, priority: priority) {
                logger.warning("Event dropped: ingest queue full")
            }
        } else {
            // Fallback: direct write (used before ingestor is started)
            do {
                try writeEvent(msgpackData: data)
            } catch {
                logger.error("Failed to write event: \(error, privacy: .public)")
            }
        }
    }

    /// Determine event priority based on type.
    /// Critical: key_down, mouse_down, mouse_up, app_switch, lifecycle events.
    /// Normal: mouse_move, scroll, window_title_changed.
    private static func priorityFor(track: CaptureTrack, type: String) -> EventPriority {
        switch track {
        case .lifecycle:
            return .critical
        case .input:
            switch type {
            case "key_down", "mouse_down", "mouse_up", "secure_field":
                return .critical
            default:
                return .normal
            }
        case .windowApp:
            switch type {
            case "app_switch":
                return .critical
            default:
                return .normal
            }
        default:
            return .normal
        }
    }
}
