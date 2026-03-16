import Cocoa
import SwiftUI
@preconcurrency import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let recordingState = RecordingState()
    let permissionManager = PermissionManager()
    private let hotkeyManager = HotkeyManager()

    /// Stored for use by reconcilePermissionBoundSubsystems outside the launch path.
    private var captureDataDir: String?
    private var screenRecorder: ScreenRecorder?
    private var windowTracker: WindowTracker?
    private var inputMonitor: InputMonitor?
    /// Latch: true after we've attempted the Input Monitoring bootstrap once.
    /// Reset on didBecomeActive (user may have just granted permission in System Settings).
    /// Prevents repeated CGEventTap creation on the 30-second timer.
    private var inputMonitoringBootstrapAttempted = false
    private var axTreeLogger: AXTreeLogger?
    private var eventIngestor: EventIngestor?
    private var ocrWorker: OCRWorker?
    private var transcriptWorker: TranscriptWorker?
    private var embeddingWorker: EmbeddingWorker?
    private var audioRecorder: AudioRecorder?
    private var systemAudioWriter: SystemAudioWriter?
    private var statsTimer: Timer?
    private var searchIndexTimer: Timer?
    private var workflowExtractionTimer: Timer?
    private var trainingDataTimer: Timer?
    private var loraTrainingTimer: Timer?
    private var trainingDataGenerator: TrainingDataGenerator?
    private var loraTrainer: LoRATrainer?
    private var onboardingWindow: NSWindow?
    private let searchPanel = SearchPanelController()

    // Intelligence subsystem
    private(set) var llmOrchestrator: LLMOrchestrator?
    private(set) var summaryJobQueue: SummaryJobQueue?

    // Phase 4: Proactive + Context
    private(set) var proactiveStore: ProactiveStore?
    private(set) var trustTuner: TrustTuner?
    private(set) var contextStore: ContextStore?
    private var contextHeartbeat: ContextHeartbeat?
    private var retentionCoordinator: RetentionCoordinator?
    private var proactiveActivityWindow: ProactiveActivityWindowController?
    private var proactiveDeliveryManager: ProactiveDeliveryManager?
    private var proactiveInboxWindow: ProactiveInboxWindowController?
    private var proactiveOverlayController: ProactiveOverlayController?
    /// Provider references for synchronous availability checks (heartbeat gate).
    private var llmProviders: [any LLMProvider] = []
    /// Direct reference to local provider for lifecycle management during shutdown.
    private var localLLMProvider: LocalLLMProvider?
    /// Shared lifecycle manager for text and vision LLM models.
    /// Single instance ensures mutual exclusion on constrained hardware (<48 GB RAM).
    private var sharedModelLifecycle: LocalModelLifecycle?
    /// Vision LLM provider for on-device screenshot understanding.
    private var visionLLMProvider: VisionLLMProvider?
    /// Local text embedder for semantic search (nomic-embed-text-v1.5).
    private var localTextEmbedder: LocalTextEmbedder?

    /// Bridged from MenuBarIcon's @Environment(\.openWindow) at launch.
    /// Used by SearchPanelController to open the Timeline window deterministically.
    var openTimelineAction: OpenWindowAction?

    // Learning mode (Cmd+Shift+L)
    private var learningRecorder: LearningRecorder?
    private var learningIndicatorController: LearningIndicatorController?
    private var procedureReviewController: ProcedureReviewController?

    // Procedure execution (shared executor for kill switch + progress UI)
    private var procedureExecutor: ProcedureExecutor?
    private var executionProgressController: ExecutionProgressController?

    /// True when running inside the XCTest test host. Skips capture subsystem
    /// startup so the test runner can connect without timing out.
    private static let isRunningTests: Bool = {
        // Check multiple indicators: XCTest class, environment variable, or process arguments
        if NSClassFromString("XCTestCase") != nil { return true }
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return true }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return ProcessInfo.processInfo.arguments.contains { $0.contains("xctest") }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When hosted by the test runner, skip all capture/storage initialization
        // to avoid timeouts and permission issues during unit tests.
        if Self.isRunningTests {
            logger.info("Running inside test host — skipping capture startup")
            return
        }

        let dataDir = shadowDataDirectory()

        // Initialize the Rust storage engine
        do {
            try initStorage(dataDir: dataDir)
            let version = coreVersion()
            logger.info("Shadow core initialized (v\(version)), data: \(dataDir)")
        } catch {
            logger.error("Failed to initialize storage: \(error)")
            return
        }

        // Configure MLX GPU cache limit before any model loading
        MLXConfiguration.configure()

        // Determine if onboarding is needed.
        // We check Screen Recording and Accessibility first — these have safe APIs
        // that don't trigger system dialogs. Input Monitoring's check (CGEventTap)
        // triggers a system dialog on macOS Sequoia, so we defer it.
        let onboardingCompleted = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        let screenOk = CGPreflightScreenCaptureAccess()
        let accessibilityOk = AXIsProcessTrusted()

        if onboardingCompleted {
            // Onboarding fully completed (user clicked "Start Shadow").
            // Safe to probe Input Monitoring and start all capture.
            permissionManager.canProbeInputMonitoring = true
            permissionManager.checkAll()
            startAllCapture(dataDir: dataDir)
        } else {
            // Onboarding not yet completed. Show the onboarding flow even if
            // some permissions are already granted (e.g., user granted permissions
            // via the old onboarding or manually but never finished the new flow).
            // The onboarding container will resume at the persisted step.
            permissionManager.screenRecordingGranted = screenOk
            permissionManager.accessibilityGranted = accessibilityOk
            showOnboardingWindow()
        }

        // Register global hotkey (Option+Space → toggle search overlay)
        hotkeyManager.register { [weak self] in
            self?.searchPanel.toggle()
        }

        // Wire learning mode hotkey (Cmd+Shift+L → toggle recording)
        hotkeyManager.learningModeAction = { [weak self] in
            self?.toggleLearningMode()
        }

        // Observe app activation (user returns from System Settings after granting permissions)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let dataDir = self.captureDataDir else { return }
                // Reset the bootstrap latch so a fresh attempt can happen
                // (user may have just granted Input Monitoring in System Settings).
                self.inputMonitoringBootstrapAttempted = false
                self.permissionManager.checkAll()
                self.reconcilePermissionBoundSubsystems(dataDir: dataDir)
            }
        }

        // Refresh UI stats every 30 seconds + check for clock drift + reconcile subsystems
        statsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingState.refreshDaySummary()
                self?.permissionManager.checkAll()

                // Sync recording state from actual ScreenRecorder health.
                if let recorder = self?.screenRecorder {
                    if recorder.isRecording && !(self?.recordingState.isRecording ?? false) {
                        self?.recordingState.isRecording = true
                        if self?.recordingState.todayStartTime == nil {
                            self?.recordingState.todayStartTime = Date()
                        }
                    } else if !recorder.isRecording && (self?.recordingState.isRecording ?? false)
                                && !(self?.recordingState.isPaused ?? false) {
                        self?.recordingState.isRecording = false
                    }
                }

                if let dataDir = self?.captureDataDir {
                    self?.reconcilePermissionBoundSubsystems(dataDir: dataDir)
                }

                // Periodic clock drift check (catches NTP corrections, VM migration, etc.)
                if let clock = EventWriter.clock, let driftUs = clock.checkClockDrift() {
                    let driftMs = driftUs / 1000
                    logger.warning("Clock jump detected: \(driftMs)ms drift")
                    EventWriter.lifecycleEvent(type: "clock_jump_detected", details: [
                        "drift_us": .int32(Int32(clamping: driftUs)),
                        "trigger": .string("periodic_check"),
                    ])
                    DiagnosticsStore.shared.postWarning(
                        severity: .warning,
                        subsystem: "CaptureSession",
                        code: "CLOCK_JUMP_DETECTED",
                        message: "Clock jump of \(driftMs)ms detected during periodic check"
                    )
                }
            }
        }

        // Periodic search index update (every 30 seconds)
        searchIndexTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task.detached(priority: .utility) {
                do {
                    let count = try indexRecentEvents()
                    if count > 0 {
                        logger.info("Search index: indexed \(count) new events")
                    }
                } catch {
                    logger.error("Search indexing failed: \(error, privacy: .public)")
                }
            }
        }

        // Initial index build (catch up on any unindexed events)
        Task.detached(priority: .utility) {
            do {
                let count = try indexRecentEvents()
                logger.info("Initial search index build: \(count) events indexed")
            } catch {
                logger.error("Initial search indexing failed: \(error, privacy: .public)")
            }
        }

        // Initial stats load
        recordingState.refreshDaySummary()
    }

    // MARK: - Capture Startup

    /// Start all capture subsystems. Called directly on launch (no onboarding needed)
    /// or after the onboarding window closes.
    private func startAllCapture(dataDir: String) {
        self.captureDataDir = dataDir

        // Initialize session clock for v2 event envelopes
        if EventWriter.clock == nil {
            let clock = CaptureSessionClock()
            EventWriter.clock = clock
            logger.info("Capture session started: \(clock.sessionId)")

            // Register session in timeline database
            let startTs = CaptureSessionClock.wallMicros()
            do {
                try registerSession(sessionId: clock.sessionId, startTs: startTs)
            } catch {
                logger.error("Failed to register session: \(error)")
            }
        }

        // Start non-blocking event ingest pipeline
        if eventIngestor == nil {
            let ingestor = EventIngestor()
            ingestor.start()
            EventWriter.ingestor = ingestor
            self.eventIngestor = ingestor
        }

        // Emit session_start lifecycle event
        EventWriter.lifecycleEvent(type: "session_start")

        // Mimicry Phase A4: Background workflow extraction (every hour).
        // Scans enriched events for recurring patterns and saves as AX-anchored procedures.
        if workflowExtractionTimer == nil {
            // Delay first extraction by 5 minutes to let data accumulate
            workflowExtractionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task.detached(priority: .utility) {
                    let store = ProcedureStore()
                    let count = await WorkflowExtractor.extractAndSave(store: store)
                    if count > 0 {
                        logger.info("Background workflow extraction: \(count) workflows saved")
                    }
                }
            }
            // Also do an initial extraction 5 minutes after launch
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                let store = ProcedureStore()
                let count = await WorkflowExtractor.extractAndSave(store: store)
                if count > 0 {
                    logger.info("Initial workflow extraction: \(count) workflows saved")
                }
            }
        }

        // Mimicry Phase B: Background training data generation (every 4 hours).
        // Converts enriched click events + video frames into JSONL grounding tuples.
        // Persistent instance retains session counters across timer fires.
        if trainingDataTimer == nil {
            let generator = TrainingDataGenerator()
            self.trainingDataGenerator = generator

            trainingDataTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak generator] _ in
                guard let generator else { return }
                Task.detached(priority: .background) {
                    let count = await generator.generateFromRecentEvents()
                    if count > 0 {
                        logger.info("Training data generation: \(count) tuples generated")
                    }
                }
            }
            // Initial generation 10 minutes after launch
            Task.detached(priority: .background) { [weak generator] in
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
                guard let generator else { return }
                let count = await generator.generateFromRecentEvents()
                if count > 0 {
                    logger.info("Initial training data generation: \(count) tuples generated")
                }
            }
        }

        // Mimicry Phase B: LoRA fine-tuning check (every 6 hours).
        // Checks if enough training data has accumulated and triggers fine-tuning.
        // Persistent instance retains lastRunTime for cooldown enforcement.
        if loraTrainingTimer == nil {
            let generator = self.trainingDataGenerator ?? TrainingDataGenerator()
            if self.trainingDataGenerator == nil {
                self.trainingDataGenerator = generator
            }
            let trainer = LoRATrainer(dataGenerator: generator)
            self.loraTrainer = trainer

            loraTrainingTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak trainer] _ in
                guard let trainer else { return }
                Task.detached(priority: .background) {
                    let success = await trainer.checkAndTrain()
                    if success {
                        logger.info("LoRA training completed successfully")
                    }
                }
            }
        }

        // System audio writer (captures speaker output via SCK)
        // Created before ScreenRecorder so it can be wired to the designated stream.
        if systemAudioWriter == nil {
            let writer = SystemAudioWriter(dataDir: dataDir)
            writer.start()
            self.systemAudioWriter = writer
        }

        // Screen recording is now started by reconcilePermissionBoundSubsystems above.

        // OCR worker (processes recorded frames for text extraction)
        if ocrWorker == nil {
            let worker = OCRWorker()
            worker.start()
            self.ocrWorker = worker
        }

        // Transcript worker (transcribes sealed audio segments)
        // Apple Speech provider is immediately available — start worker now.
        // Whisper loads in background and becomes available later.
        if transcriptWorker == nil {
            let worker = TranscriptWorker()
            let appleProvider = AppleSpeechProvider()
            let orchestrator = TranscriptionOrchestrator(providers: [appleProvider])
            worker.orchestrator = orchestrator
            worker.start()
            self.transcriptWorker = worker

            // Background: discover provisioned Whisper models, try loading in preference
            // order (balanced > fast > accurate). Stop at first successful load.
            // If all candidates fail, keep Apple Speech only.
            Task.detached(priority: .utility) {
                let whisperModelFolder = shadowModelsDir() + "/whisper"
                let candidates = WhisperProfile.discoverProvisionedCandidates(in: whisperModelFolder)
                guard !candidates.isEmpty else {
                    logger.info("No Whisper model provisioned — using Apple Speech only")
                    return
                }

                for profile in candidates {
                    let whisperProvider = await WhisperTranscriptionProvider(
                        modelFolder: whisperModelFolder,
                        profile: profile
                    )
                    if whisperProvider.isAvailable {
                        orchestrator.insertProvider(whisperProvider, at: 0)
                        logger.info("Whisper provider ready (profile: \(profile.displayName))")
                        return
                    }
                    logger.warning("Whisper profile \(profile.displayName) failed to load, trying next candidate")
                }

                logger.info("All Whisper candidates failed to load — using Apple Speech only")
            }
        }

        // LLM orchestrator (meeting summarization)
        // Non-blocking — capture starts immediately, LLM providers load in background.
        if llmOrchestrator == nil {
            let mode = LLMMode(rawValue: UserDefaults.standard.string(forKey: "llmMode") ?? "auto") ?? .auto
            let appleProvider = AppleFoundationProvider()
            let cloudProvider = CloudLLMProvider()
            let openAIProvider = OpenAILLMProvider()
            let sharedLifecycle = LocalModelLifecycle()
            self.sharedModelLifecycle = sharedLifecycle
            let localProvider = LocalLLMProvider(lifecycle: sharedLifecycle)
            self.localLLMProvider = localProvider

            // Order: apple foundation (fastest, ANE), local MLX (GPU), cloud Anthropic, cloud OpenAI.
            // Apple Foundation provider self-gates on request complexity — throws .unavailable
            // for tool-calling or multi-turn requests, letting the orchestrator fall through.
            // Both cloud providers are included; the user's configured preference and API key
            // availability determine which actually gets used.
            let orchestrator = LLMOrchestrator(
                providers: [appleProvider, localProvider, cloudProvider, openAIProvider],
                mode: mode
            )
            self.llmOrchestrator = orchestrator
            self.llmProviders = [appleProvider, localProvider, cloudProvider, openAIProvider]

            let store = SummaryStore()
            let queue = SummaryJobQueue(orchestrator: orchestrator, store: store)
            self.summaryJobQueue = queue
            self.searchPanel.summaryJobQueue = queue
            self.searchPanel.llmOrchestrator = orchestrator

            DiagnosticsStore.shared.setStringGauge("llm_mode", value: mode.rawValue)
            DiagnosticsStore.shared.setGauge("llm_local_fast_model_loaded", value: localProvider.isAvailable ? 1 : 0)

            // Set initial provider/model gauges based on what's configured
            if cloudProvider.isAvailable {
                DiagnosticsStore.shared.setStringGauge("llm_active_provider", value: cloudProvider.providerName)
                DiagnosticsStore.shared.setStringGauge("llm_active_model_id", value: cloudProvider.modelId)
            } else if localProvider.isAvailable {
                DiagnosticsStore.shared.setStringGauge("llm_active_provider", value: localProvider.providerName)
                DiagnosticsStore.shared.setStringGauge("llm_active_model_id", value: localProvider.modelId)
            }

            logger.info("LLM orchestrator initialized (mode=\(mode.rawValue), apple=\(appleProvider.isAvailable), local=\(localProvider.isAvailable), cloud=\(cloudProvider.isAvailable))")

            // Ollama opt-in: add provider only if user has explicitly enabled it
            if UserDefaults.standard.bool(forKey: "ollamaEnabled") {
                let ollamaProvider = OllamaProvider()
                // Insert after local MLX (index 1) but before cloud (index 2)
                Task { await orchestrator.insertProvider(ollamaProvider, at: 2) }
                self.llmProviders.append(ollamaProvider)
                logger.info("Ollama provider enabled by user setting")
            }

            // Auto-provision local models in background if not already downloaded.
            // Shadow remains fully functional with cloud fallback while models download.
            Task.detached(priority: .utility) {
                let hardware = HardwareProfile.detect()
                let plan = ModelProvisioner.plan(for: hardware)

                // Record plan decisions in diagnostics
                let hasFast = plan.models.contains { $0.tier == .fast }
                let hasDeep = plan.models.contains { $0.tier == .deep }
                DiagnosticsStore.shared.setGauge("provisioning_plan_fast", value: hasFast ? 1 : 0)
                DiagnosticsStore.shared.setGauge("provisioning_plan_deep", value: hasDeep ? 1 : 0)

                logger.info("Provisioning plan: \(plan.models.map(\.localDirectoryName).joined(separator: ", "))")
                for warning in plan.warnings {
                    logger.warning("Provisioning: \(warning)")
                }

                // Let the download manager handle filtering via ModelVerifier.isVerified()
                // which does full 4-step verification (structure + config hash + weight fingerprint).
                // The manager returns early if all models are already verified.
                await ModelDownloadManager.shared.startDownloads(plan: plan)
            }
        }

        // Phase 4: Proactive + Context stores
        if proactiveStore == nil {
            let pStore = ProactiveStore()
            let tTuner = TrustTuner()
            let cStore = ContextStore()
            proactiveStore = pStore
            trustTuner = tTuner
            contextStore = cStore

            // Start context heartbeat — provider gate checks mode + consent + availability
            if let orchestrator = llmOrchestrator {
                // Initialize vision LLM provider for on-device screenshot analysis.
                // Shares the lifecycle manager with LocalLLMProvider so mutual exclusion
                // and memory pressure handling coordinate across text and vision models.
                let vlmLifecycle = self.sharedModelLifecycle ?? LocalModelLifecycle()
                let vlmProvider = VisionLLMProvider(lifecycle: vlmLifecycle)
                self.visionLLMProvider = vlmProvider
                logger.info("VisionLLMProvider initialized (available=\(vlmProvider.isAvailable))")

                // Initialize local text embedder for future semantic search integration.
                let textEmbedder = LocalTextEmbedder()
                self.localTextEmbedder = textEmbedder
                logger.info("LocalTextEmbedder initialized (available=\(textEmbedder.isAvailable))")

                // Create shared procedure executor for kill switch + progress UI wiring
                let sharedExecutor = ProcedureExecutor(
                    llmProvider: OrchestratorLLMBridge(orchestrator: orchestrator)
                )
                self.procedureExecutor = sharedExecutor

                // Wire kill switch: Option+Escape -> cancel active execution
                hotkeyManager.killSwitchAction = { [weak self] in
                    // Cancel the agent run (which also stops the underlying command task)
                    self?.searchPanel.cancelAgentRun()
                    // Cancel any active procedure replay
                    guard let executor = self?.procedureExecutor else { return }
                    Task {
                        await executor.cancel()
                    }
                    // Exit background mode if active
                    BackgroundTaskManager.shared.exitBackground()
                    logger.info("Kill switch activated — all agent execution cancelled")
                    DiagnosticsStore.shared.increment("kill_switch_activated_total")
                }

                // Wire execution state -> progress UI
                let progressCtrl = ExecutionProgressController()
                self.executionProgressController = progressCtrl
                progressCtrl.onCancel = { [weak self] in
                    guard let executor = self?.procedureExecutor else { return }
                    Task {
                        await executor.cancel()
                    }
                }

                let agentRegistry = AgentTools.buildDefaultRegistry(
                    visionProvider: vlmProvider,
                    orchestrator: self.llmOrchestrator,
                    procedureExecutor: sharedExecutor,
                    onExecutionStarted: { [weak progressCtrl] procedure in
                        progressCtrl?.show(procedure: procedure)
                    },
                    onExecutionEvent: { [weak progressCtrl] event in
                        progressCtrl?.handleEvent(event)
                    }
                )

                // Inject shared registry into search panel so it uses the same
                // executor (with kill switch + progress UI) as the heartbeat agent
                self.searchPanel.agentToolRegistry = agentRegistry

                // Wire BackgroundTaskManager callbacks for background agent execution
                let bgMgr = BackgroundTaskManager.shared
                bgMgr.onDismissPanel = { [weak self] in
                    self?.searchPanel.hideForBackground()
                }
                bgMgr.onShowPanel = { [weak self] in
                    self?.searchPanel.showWithResults()
                }
                bgMgr.onCancelAgent = { [weak self] in
                    // Cancel the agent run
                    self?.searchPanel.cancelAgentRun()
                    // Cancel any active procedure replay
                    guard let executor = self?.procedureExecutor else { return }
                    Task {
                        await executor.cancel()
                    }
                }

                let heartbeat = ContextHeartbeat(
                    contextStore: cStore,
                    proactiveStore: pStore,
                    trustTuner: tTuner,
                    generate: { request in
                        try await orchestrator.generate(request: request)
                    },
                    toolRegistry: agentRegistry,
                    frameExtractFn: { ts, displayId in
                        let seconds = TimeInterval(ts) / 1_000_000
                        return try await FrameExtractor.extractFrame(
                            at: seconds, displayID: CGDirectDisplayID(displayId)
                        )
                    },
                    isProviderAvailable: {
                        await orchestrator.canGenerateNow
                    }
                )

                // Phase 4A: Overlay + delivery manager
                let overlayCtrl = ProactiveOverlayController()
                overlayCtrl.onOpenInbox = { [weak self] suggestionId in
                    self?.showProactiveInbox(focusSuggestionId: suggestionId)
                }
                self.proactiveOverlayController = overlayCtrl

                let deliveryMgr = ProactiveDeliveryManager(
                    proactiveStore: pStore,
                    trustTuner: tTuner
                )
                deliveryMgr.overlayController = overlayCtrl
                deliveryMgr.onShowInbox = { [weak self] id in
                    self?.showProactiveInbox(focusSuggestionId: id)
                }
                self.proactiveDeliveryManager = deliveryMgr

                // Wire analyzer output to delivery manager
                heartbeat.onSuggestionsGenerated = { [weak deliveryMgr] suggestions in
                    deliveryMgr?.deliverSuggestions(suggestions)
                }

                heartbeat.start()
                self.contextHeartbeat = heartbeat
                logger.info("Context heartbeat started (with proactive delivery)")
            }

            // Wire context store to search panel for context-aware agent runs
            self.searchPanel.contextStore = cStore

            logger.info("Phase 4 stores initialized (proactive + context + delivery)")
        }

        // Embedding worker (CLIP vector embeddings from recorded frames)
        if embeddingWorker == nil {
            let worker = EmbeddingWorker()
            worker.start()
            self.embeddingWorker = worker
        }

        // Retention coordinator (periodic storage cleanup)
        if retentionCoordinator == nil {
            let coordinator = RetentionCoordinator()
            coordinator.start()
            self.retentionCoordinator = coordinator
        }

        // Wire pause/resume
        wirePauseResume()

        // Permission-bound subsystems: window tracking, input monitoring,
        // AX tree logging, screen recording, audio recording.
        // Called LAST so all dependencies (systemAudioWriter, eventIngestor, etc.)
        // are ready before any permission-gated subsystem starts.
        // Also called by didBecomeActive and the 30-second timer for recovery.
        reconcilePermissionBoundSubsystems(dataDir: dataDir)
    }

    private func wirePauseResume() {
        recordingState.onPauseChanged = { [weak self] paused in
            guard let self else { return }
            if paused {
                self.screenRecorder?.pause()
                self.windowTracker?.isPaused = true
                self.inputMonitor?.isPaused = true
                self.audioRecorder?.pause()
                self.systemAudioWriter?.pause()
            } else {
                self.screenRecorder?.resume()
                self.windowTracker?.isPaused = false
                self.inputMonitor?.isPaused = false
                self.audioRecorder?.resume()
                self.systemAudioWriter?.resume()
            }
        }
    }

    // MARK: - Onboarding

    private func showOnboardingWindow() {
        let onboardingView = OnboardingContainerView(permissions: permissionManager)
        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Shadow"
        // No .closable — user must complete onboarding.
        // The only exits are Continue/Skip (step navigation) or completing the flow.
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear

        // Fixed size for the new onboarding experience
        window.setContentSize(NSSize(width: 560, height: 720))
        window.center()

        // Start capture when onboarding closes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onboardingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )

        self.onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func onboardingWindowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onboardingWindow = nil

        // Now that onboarding is done, enable full permission probing
        // and start capture subsystems.
        permissionManager.canProbeInputMonitoring = true
        permissionManager.checkAll()

        let dataDir = shadowDataDirectory()
        startAllCapture(dataDir: dataDir)
    }

    private func startScreenCapture(dataDir: String) {
        guard screenRecorder == nil else { return }

        let hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess {
            logger.info("Screen Recording not granted — will retry when permission is detected via reconciler.")
            return
        }

        logger.info("Screen Recording permission granted.")

        let recorder = ScreenRecorder(dataDir: dataDir)
        recorder.systemAudioWriter = systemAudioWriter
        self.screenRecorder = recorder

        Task {
            do {
                try await recorder.startCapture()
                self.recordingState.isRecording = true
                self.recordingState.todayStartTime = Date()
            } catch {
                logger.error("Failed to start screen capture: \(error, privacy: .public)")
                await recorder.stopCapture()
                self.screenRecorder = nil
            }
        }
    }

    // MARK: - Permission-Bound Subsystem Reconciliation

    /// Start permission-dependent subsystems that aren't yet running.
    ///
    /// Idempotent: safe to call repeatedly. Each subsystem is started only
    /// if its permission is granted AND it is not already active. Does NOT
    /// stop subsystems on permission revocation (that is a separate concern).
    ///
    /// Called from:
    /// - startAllCapture (launch path, after all core infrastructure is ready)
    /// - NSApplication.didBecomeActiveNotification (user returns from System Settings)
    /// - 30-second statsTimer (fallback)
    ///
    /// Manages four permission-bound subsystems:
    /// - Screen Recording: ScreenRecorder (depends on systemAudioWriter)
    /// - Input Monitoring: InputMonitor (recreated if tap is dead/stale)
    /// - Accessibility: WindowTracker + AXTreeLogger
    /// - Microphone: AudioRecorder
    private func reconcilePermissionBoundSubsystems(dataDir: String) {
        // Screen Recording
        if permissionManager.screenRecordingGranted && screenRecorder == nil {
            startScreenCapture(dataDir: dataDir)
        }

        // Input Monitoring
        // Check isCapturing (not just nil) because the monitor can exist with
        // a dead or disabled CGEventTap after a stale permission grant.
        if permissionManager.inputMonitoringGranted {
            let needsRestart = inputMonitor == nil || !(inputMonitor?.isCapturing ?? false)
            if needsRestart {
                inputMonitor?.stopMonitoring()
                let monitor = InputMonitor()
                self.inputMonitor = monitor
                monitor.startMonitoring()
                if let treeLogger = axTreeLogger {
                    monitor.onUserActivity = { [weak treeLogger] in
                        treeLogger?.recordUserActivity()
                    }
                }
                if monitor.isCapturing {
                    logger.info("Input monitoring started via reconciler")
                }
            }
        } else if inputMonitor == nil
                    && permissionManager.canProbeInputMonitoring
                    && !inputMonitoringBootstrapAttempted {
            // One-shot bootstrap: the probe can give false negatives on Sequoia,
            // so the permission flag may be wrong. Try once per launch/activation
            // cycle. The latch prevents repeated CGEventTap creation on the
            // 30-second timer. Reset on didBecomeActive (user returns from
            // System Settings).
            inputMonitoringBootstrapAttempted = true
            let monitor = InputMonitor()
            monitor.startMonitoring()
            if monitor.isCapturing {
                self.inputMonitor = monitor
                permissionManager.inputMonitoringGranted = true
                if let treeLogger = axTreeLogger {
                    monitor.onUserActivity = { [weak treeLogger] in
                        treeLogger?.recordUserActivity()
                    }
                }
                logger.info("Input monitoring bootstrap succeeded (probe was false negative)")
            } else {
                monitor.stopMonitoring()
                logger.info("Input monitoring bootstrap failed (permission not granted)")
            }
        }

        // Accessibility (WindowTracker + AXTreeLogger)
        if permissionManager.accessibilityGranted {
            if windowTracker == nil {
                let tracker = WindowTracker()
                self.windowTracker = tracker
                tracker.startTracking()
                logger.info("Window tracking started via reconciler")
            }
            if axTreeLogger == nil {
                let treeLogger = AXTreeLogger()
                self.axTreeLogger = treeLogger
                windowTracker?.axTreeLogger = treeLogger
                treeLogger.startPeriodicCapture()
                inputMonitor?.onUserActivity = { [weak treeLogger] in
                    treeLogger?.recordUserActivity()
                }
                logger.info("AX tree logger started via reconciler")
            }
        }

        // Microphone
        if permissionManager.microphoneGranted && audioRecorder == nil {
            let recorder = AudioRecorder(dataDir: dataDir)
            recorder.start()
            self.audioRecorder = recorder
            logger.info("Audio recording started via reconciler")
        }

        // Sync permission state from actual subsystem health.
        // The PermissionManager probe can give false negatives on macOS Sequoia
        // (creating a test CGEventTap reports disabled while the real tap works).
        // Trust the real monitor's health over the probe.
        if let monitor = inputMonitor, monitor.isCapturing {
            permissionManager.inputMonitoringGranted = true
        }

        // Sync recording state from actual ScreenRecorder health.
        if let recorder = screenRecorder, recorder.isRecording,
           !recordingState.isRecording {
            recordingState.isRecording = true
            if recordingState.todayStartTime == nil {
                recordingState.todayStartTime = Date()
            }
        }
    }

    /// Open the Proactive Activity inspection window. Called from Diagnostics.
    func showProactiveInbox(focusSuggestionId: UUID? = nil) {
        guard let store = proactiveStore else {
            logger.warning("Cannot open Proactive Inbox: stores not initialized")
            return
        }

        if proactiveInboxWindow == nil {
            let controller = ProactiveInboxWindowController(proactiveStore: store)
            // Wire deep-link through the canonical SearchPanelController path
            controller.onOpenTimeline = { [weak self] ts, displayId in
                self?.searchPanel.openTimeline(at: ts, displayID: displayId)
            }
            controller.onFeedback = { [weak self] suggestionId, eventType in
                self?.proactiveDeliveryManager?.recordFeedback(
                    suggestionId: suggestionId,
                    eventType: eventType
                )
            }
            proactiveInboxWindow = controller
        }

        proactiveInboxWindow?.focusSuggestionId = focusSuggestionId
        proactiveInboxWindow?.showOrFocus()
    }

    func showProactiveActivity() {
        guard let store = proactiveStore, let tuner = trustTuner else {
            logger.warning("Cannot open Proactive Activity: stores not initialized")
            return
        }

        if proactiveActivityWindow == nil {
            let controller = ProactiveActivityWindowController(
                proactiveStore: store,
                trustTuner: tuner
            )
            // Wire deep-link through the canonical SearchPanelController path
            controller.onOpenTimeline = { [weak self] ts, displayId in
                self?.searchPanel.openTimeline(at: ts, displayID: displayId)
            }
            proactiveActivityWindow = controller
        }

        proactiveActivityWindow?.showOrFocus()
    }

    // MARK: - Learning Mode

    /// Toggle learning mode on/off. Called by HotkeyManager when Cmd+Shift+L is pressed.
    private func toggleLearningMode() {
        if let recorder = learningRecorder {
            // Learning mode is active — stop and synthesize
            stopLearningMode(recorder: recorder)
        } else {
            // Start learning mode
            startLearningMode()
        }
    }

    private func startLearningMode() {
        let recorder = LearningRecorder()
        self.learningRecorder = recorder

        // Wire input forwarding
        inputMonitor?.learningRecorder = recorder

        // Show indicator
        let indicator = LearningIndicatorController()
        indicator.show()
        self.learningIndicatorController = indicator

        // Start recording
        Task {
            await recorder.startRecording()
        }

        logger.info("Learning mode started")
        DiagnosticsStore.shared.increment("learning_mode_start_total")
    }

    private func stopLearningMode(recorder: LearningRecorder) {
        // Disconnect input forwarding
        inputMonitor?.learningRecorder = nil

        // Dismiss indicator
        learningIndicatorController?.dismiss()
        learningIndicatorController = nil

        logger.info("Learning mode stopped — synthesizing procedure")
        DiagnosticsStore.shared.increment("learning_mode_stop_total")

        // Capture orchestrator reference for synthesis
        let orchestrator = llmOrchestrator
        self.learningRecorder = nil

        Task {
            let actions = await recorder.stopRecording()

            guard !actions.isEmpty else {
                logger.info("No actions recorded — skipping synthesis")
                return
            }

            // Synthesize procedure via LLM
            guard let orchestrator else {
                logger.warning("No LLM orchestrator — cannot synthesize procedure")
                return
            }

            // Use the orchestrator to get a provider for synthesis
            do {
                let synthesizer = ProcedureSynthesizer(llmProvider: OrchestratorLLMBridge(orchestrator: orchestrator))
                let template = try await synthesizer.synthesize(actions)

                // Show review panel
                await MainActor.run {
                    let reviewController = ProcedureReviewController()
                    reviewController.show(template: template) { [weak self] finalTemplate in
                        // Save the procedure
                        Task {
                            let store = ProcedureStore()
                            try await store.save(finalTemplate)
                            logger.info("Procedure saved: '\(finalTemplate.name)'")
                            DiagnosticsStore.shared.increment("procedure_saved_total")
                        }
                    }
                    self.procedureReviewController = reviewController
                }
            } catch {
                logger.error("Procedure synthesis failed: \(error, privacy: .public)")
                DiagnosticsStore.shared.increment("procedure_synthesis_fail_total")
            }
        }
    }

    private func toggleTimeline() {
        if let window = NSApp.windows.first(where: { $0.title == "Shadow Timeline" }) {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Remove onboarding observer FIRST — prevents startAllCapture() from
        // firing when NSApp closes the window during shutdown.
        if let window = onboardingWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        }

        // Emit session_end lifecycle event before shutting down capture
        EventWriter.lifecycleEvent(type: "session_end")

        // Finalize session in timeline database
        let now = CaptureSessionClock.wallMicros()
        if let clock = EventWriter.clock {
            do {
                try finalizeSession(sessionId: clock.sessionId, endTs: now)
            } catch {
                logger.error("Failed to finalize session: \(error)")
            }
        }

        // Close any open focus interval
        do { try closeFocusInterval(endTs: now) } catch {
            logger.error("Failed to close focus interval: \(error)")
        }

        statsTimer?.invalidate()
        searchIndexTimer?.invalidate()
        workflowExtractionTimer?.invalidate()
        trainingDataTimer?.invalidate()
        loraTrainingTimer?.invalidate()
        contextHeartbeat?.stop()
        retentionCoordinator?.stop()
        axTreeLogger?.stopPeriodicCapture()
        hotkeyManager.unregister()

        // All shutdown work is async (audio writer finalization, screen capture stop).
        // Use .terminateLater and reply when done.
        Task {
            // Cancel any in-progress model downloads before shutdown
            await ModelDownloadManager.shared.cancelAll()

            // Unload local LLM model, VLM, and text embedder to free GPU memory
            await self.localLLMProvider?.shutdown()
            await self.visionLLMProvider?.unload()
            await self.localTextEmbedder?.unload()

            // Stop audio subsystems first — await writer finalization, then emit
            // Track 4 close events before the ingestor drains.
            await self.audioRecorder?.stop()
            await self.systemAudioWriter?.stop()

            self.ocrWorker?.stop()
            self.transcriptWorker?.stop()
            self.embeddingWorker?.stop()
            self.windowTracker?.stopTracking()
            self.inputMonitor?.stopMonitoring()

            // Stop screen recorder (also async — stops SCK streams)
            if let recorder = self.screenRecorder {
                await recorder.stopCapture()
            }

            // Stop ingestor (drains remaining queued events synchronously)
            self.eventIngestor?.stop()
            EventWriter.ingestor = nil

            do { try flushAndRotate() } catch { logger.error("Failed to flush: \(error)") }
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    private func shadowDataDirectory() -> String {
        shadowDataDir()
    }
}

/// Canonical path for Shadow's data directory. Used by AppDelegate and any other
/// code that needs to locate stored data without going through the Rust layer.
func shadowDataDir() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".shadow/data").path
}

/// Canonical path for Shadow's models directory (~/.shadow/models).
/// Models are downloaded by provisioning scripts, not shipped in-app.
func shadowModelsDir() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".shadow/models").path
}
