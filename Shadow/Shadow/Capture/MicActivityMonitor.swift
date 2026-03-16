import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "MicActivityMonitor")

/// Monitors the system default input audio device to detect when any app
/// starts or stops using the microphone. Uses CoreAudio property listeners
/// on `kAudioDevicePropertyDeviceIsRunningSomewhere`.
///
/// Thread safety discipline:
/// - All public API is `@MainActor`.
/// - CoreAudio callbacks dispatch to main actor for state mutation.
/// - `guardedState` (OSAllocatedUnfairLock) protects the minimal state
///   that CoreAudio callbacks read synchronously (device ID for listener removal).
///
/// Debounce policy:
/// - Activation: 2-second delay to avoid false triggers from brief mic probes.
/// - Deactivation: 30-second cooldown to avoid segment churn during pauses
///   in conversation. NOTE: deactivation via property change only works when
///   Shadow is NOT actively capturing mic audio (see self-trigger note below).
///
/// Self-trigger note:
/// When Shadow starts its own AVCaptureSession for mic capture, it contributes
/// to `kAudioDevicePropertyDeviceIsRunningSomewhere`. This means the property
/// stays `true` even after external apps stop using the mic. Deactivation
/// callbacks will NOT fire while Shadow is recording. AudioRecorder handles
/// deactivation independently via `AVCaptureDevice.isInUseByAnotherApplication`
/// KVO observation — no capture interruption needed.
final class MicActivityMonitor: Sendable {

    /// Callback fired when mic becomes active (after activation debounce).
    nonisolated(unsafe) var onMicActive: (@MainActor () -> Void)?

    /// Callback fired when mic becomes inactive (after deactivation cooldown).
    /// NOTE: Will NOT fire while AudioRecorder is actively capturing. See class doc.
    nonisolated(unsafe) var onMicInactive: (@MainActor () -> Void)?

    // MARK: - Constants

    private let activationDelay: TimeInterval = 2.0
    private let deactivationCooldown: TimeInterval = 30.0

    // MARK: - Guarded state (CoreAudio callback access)

    private struct GuardedState: Sendable {
        /// The AudioDeviceID we're currently listening on. 0 = none.
        var monitoredDeviceID: AudioDeviceID = 0
        var isStopped: Bool = true
    }

    private let guardedState = OSAllocatedUnfairLock(initialState: GuardedState())

    // MARK: - Main-actor-only state

    /// Whether the mic is currently considered active (after debounce).
    nonisolated(unsafe) private var _isMicActive = false

    /// Debounce timers. Main-actor confined.
    nonisolated(unsafe) private var activationTimer: Timer?
    nonisolated(unsafe) private var deactivationTimer: Timer?

    /// Property listener blocks stored for cleanup.
    nonisolated(unsafe) private var runningListenerBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    // MARK: - Public API

    @MainActor
    var isMicActive: Bool { _isMicActive }

    @MainActor
    func start() {
        guardedState.withLock { $0.isStopped = false }
        installDefaultDeviceListener()
        let deviceID = currentDefaultInputDevice()
        if deviceID != kAudioObjectUnknown {
            startMonitoringDevice(deviceID)
        } else {
            logger.info("No default input device found — will monitor for device changes")
        }
        logger.info("MicActivityMonitor started")
    }

    @MainActor
    func stop() {
        guardedState.withLock { $0.isStopped = true }
        activationTimer?.invalidate()
        activationTimer = nil
        deactivationTimer?.invalidate()
        deactivationTimer = nil

        removeRunningListener()
        removeDefaultDeviceListener()

        if _isMicActive {
            _isMicActive = false
        }
        logger.info("MicActivityMonitor stopped")
    }

    // MARK: - Device Monitoring

    @MainActor
    private func startMonitoringDevice(_ deviceID: AudioDeviceID) {
        removeRunningListener()

        guardedState.withLock { $0.monitoredDeviceID = deviceID }

        let isRunning = isDeviceRunning(deviceID)
        logger.info("Monitoring device \(deviceID), currently running: \(isRunning)")

        if isRunning && !_isMicActive {
            scheduleActivation()
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let stopped = self.guardedState.withLock { $0.isStopped }
            guard !stopped else { return }

            let running = self.isDeviceRunning(deviceID)
            Task { @MainActor in
                self.handleRunningStateChanged(running)
            }
        }

        runningListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        if status != noErr {
            logger.error("Failed to add running listener on device \(deviceID): \(status)")
        }
    }

    @MainActor
    private func removeRunningListener() {
        let deviceID = guardedState.withLock { $0.monitoredDeviceID }
        guard deviceID != 0, let block = runningListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        runningListenerBlock = nil
        guardedState.withLock { $0.monitoredDeviceID = 0 }
    }

    // MARK: - Default Device Change Listener

    @MainActor
    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let stopped = self.guardedState.withLock { $0.isStopped }
            guard !stopped else { return }

            let newDevice = self.currentDefaultInputDevice()
            Task { @MainActor in
                self.handleDefaultDeviceChanged(newDevice)
            }
        }

        defaultDeviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            logger.error("Failed to add default input device listener: \(status)")
        }
    }

    @MainActor
    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    @MainActor
    private func handleDefaultDeviceChanged(_ newDevice: AudioDeviceID) {
        let currentDevice = guardedState.withLock { $0.monitoredDeviceID }
        guard newDevice != currentDevice else { return }

        logger.info("Default input device changed: \(currentDevice) → \(newDevice)")

        if newDevice == kAudioObjectUnknown {
            removeRunningListener()
            if _isMicActive {
                handleRunningStateChanged(false)
            }
        } else {
            startMonitoringDevice(newDevice)
        }
    }

    // MARK: - Running State Changes (with debounce)

    @MainActor
    private func handleRunningStateChanged(_ isRunning: Bool) {
        if isRunning {
            deactivationTimer?.invalidate()
            deactivationTimer = nil

            if !_isMicActive {
                scheduleActivation()
            }
        } else {
            activationTimer?.invalidate()
            activationTimer = nil

            if _isMicActive {
                scheduleDeactivation()
            }
        }
    }

    @MainActor
    private func scheduleActivation() {
        guard activationTimer == nil else { return }

        activationTimer = Timer.scheduledTimer(withTimeInterval: activationDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.activationTimer = nil

                let deviceID = self.guardedState.withLock { $0.monitoredDeviceID }
                guard deviceID != 0, self.isDeviceRunning(deviceID) else { return }

                self._isMicActive = true
                logger.info("Mic became active (after \(self.activationDelay)s debounce)")
                self.onMicActive?()
            }
        }
    }

    @MainActor
    private func scheduleDeactivation() {
        guard deactivationTimer == nil else { return }

        deactivationTimer = Timer.scheduledTimer(withTimeInterval: deactivationCooldown, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.deactivationTimer = nil

                let deviceID = self.guardedState.withLock { $0.monitoredDeviceID }
                if deviceID != 0, self.isDeviceRunning(deviceID) {
                    return
                }

                self._isMicActive = false
                logger.info("Mic became inactive (after \(self.deactivationCooldown)s cooldown)")
                self.onMicInactive?()
            }
        }
    }

    // MARK: - CoreAudio Queries

    private func currentDefaultInputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        if status != noErr {
            logger.error("Failed to get default input device: \(status)")
            return kAudioObjectUnknown
        }
        return deviceID
    }

    private func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        if status != noErr {
            return false
        }
        return isRunning != 0
    }
}
