import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ModelSetupStep")

/// Step 3 of onboarding: Model setup.
///
/// The user selects how to power Shadow's intelligence: Auto (recommended),
/// Cloud AI (Anthropic API key), Local AI (on-device MLX model), or Skip.
///
/// The "wow" moment: after configuring a provider, the user sees a live AI test.
/// The ghost speaks. Text streams character by character. Shadow comes alive.
///
/// Three paths:
/// - **Auto:** Shadow chooses the best available provider.
/// - **Cloud:** User enters an Anthropic API key, tests it, sees streaming response.
/// - **Local:** Hardware-aware model list, download, auto-test after download.
/// - **Skip:** Records without AI. Can configure later in Settings.
struct ModelSetupStepView: View {
    @Binding var ghostMood: GhostMood

    /// Called when the user taps Continue (after successful AI test or skip).
    let onContinue: @MainActor () -> Void

    // MARK: - Path Selection

    private enum AIPath: String, CaseIterable {
        case auto
        case cloud
        case local
    }

    @State private var selectedPath: AIPath = .auto
    @State private var skipped: Bool = false

    // MARK: - Cloud State

    @State private var apiKey: String = ""
    @State private var cloudTestState: TestState = .idle
    @State private var cloudErrorMessage: String = ""

    // MARK: - Local State

    @State private var hardwareProfile: HardwareProfile?
    @State private var localModels: [LocalModelSpec] = []
    @State private var localInsufficientRAM: Bool = false
    @State private var downloadState: DownloadState = .idle
    @State private var localTestState: TestState = .idle
    @State private var localErrorMessage: String = ""
    @State private var localLoadingStage: String = ""

    // MARK: - AI Test Streaming

    @State private var aiResponseText: String = ""
    @State private var aiVisibleCount: Int = 0
    @State private var streamingTimer: Timer?

    // MARK: - Pre-existing State

    @State private var existingCloudKey: Bool = false
    @State private var existingLocalModel: Bool = false

    // MARK: - Download Polling

    @State private var downloadPollTimer: Timer?
    @State private var loadingStageTimer: Timer?

    // MARK: - Continue Enablement

    private var canContinue: Bool {
        if skipped { return true }
        switch selectedPath {
        case .auto:
            return cloudTestState == .success
                || localTestState == .success
                || existingCloudKey
                || existingLocalModel
        case .cloud:
            return cloudTestState == .success || existingCloudKey
        case .local:
            return localTestState == .success || existingLocalModel
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Top section: ghost + title
            headerSection

            // Scrollable path selection
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    autoOption
                    cloudOption
                    localOption
                    skipOption
                }
                .padding(.horizontal, 32)
            }

            // AI test response area (shown after a successful test)
            if !aiResponseText.isEmpty {
                aiResponseSection
            }

            Spacer()
                .frame(minHeight: 8, maxHeight: 16)

            // Continue button
            continueSection

            Spacer()
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            ghostMood = .neutral
            checkPreExistingState()
            detectHardware()
        }
        .onDisappear {
            cleanupTimers()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Spacer()
                .frame(height: 24)

            // Ghost in top area
            ExpressiveGhostView(mood: $ghostMood, size: 80)
                .frame(width: 80, height: 80)

            Spacer()
                .frame(height: 12)

            Text("Give Shadow a mind")
                .font(.title)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Text("Shadow uses AI to understand your screen,\nanswer questions, and learn your patterns.\nChoose how to power it.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()
                .frame(height: 14)
        }
    }

    // MARK: - Auto Option

    private var autoOption: some View {
        optionCard(
            selected: selectedPath == .auto,
            action: { selectedPath = .auto; skipped = false }
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    radioCircle(selected: selectedPath == .auto)
                    Text("Auto")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("(Recommended)")
                        .font(.callout)
                        .foregroundStyle(OnboardingTheme.accent)
                }

                Text("Uses local AI when available, cloud when needed. Best of both.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 28)

                // Show pre-existing provider status
                if selectedPath == .auto {
                    VStack(alignment: .leading, spacing: 4) {
                        if existingCloudKey {
                            statusRow(icon: "checkmark.circle.fill", color: .green, text: "Cloud AI available.")
                        }
                        if existingLocalModel {
                            statusRow(icon: "checkmark.circle.fill", color: .green, text: "Local model ready.")
                        }
                        if !existingCloudKey && !existingLocalModel {
                            Text("Set up Cloud AI or Local AI below to get started.")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(.leading, 28)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Cloud Option

    private var cloudOption: some View {
        optionCard(
            selected: selectedPath == .cloud,
            action: { selectedPath = .cloud; skipped = false }
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    radioCircle(selected: selectedPath == .cloud)
                    Text("Cloud AI")
                        .font(.headline)
                        .foregroundStyle(.white)
                }

                Text("Powered by Claude. Fast, deep thinking.\nRequires an Anthropic API key.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 28)

                if selectedPath == .cloud {
                    cloudConfigSection
                        .padding(.leading, 28)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var cloudConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cloudTestState == .success {
                statusRow(icon: "checkmark.circle.fill", color: .green, text: "Connected. Shadow is thinking with Claude.")
            } else if existingCloudKey && cloudTestState == .idle {
                // Pre-existing API key found in Keychain
                statusRow(icon: "checkmark.circle.fill", color: .green, text: "API key found. Cloud AI is ready.")

                Button {
                    // Allow re-testing or replacing the key
                    existingCloudKey = false
                } label: {
                    Text("Change key")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .disabled(cloudTestState == .testing)

                    Button {
                        testCloudAPI()
                    } label: {
                        if cloudTestState == .testing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 56)
                        } else {
                            Text("Test")
                                .frame(width: 56)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(OnboardingTheme.accent)
                    .disabled(apiKey.isEmpty || cloudTestState == .testing)
                }

                if !cloudErrorMessage.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Text(cloudErrorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            if cloudTestState == .success {
                Text("You can also add a local model later for fully offline intelligence.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Local Option

    private var localOption: some View {
        optionCard(
            selected: selectedPath == .local,
            dimmed: localInsufficientRAM,
            action: {
                if !localInsufficientRAM {
                    selectedPath = .local
                    skipped = false
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    radioCircle(selected: selectedPath == .local)
                    Text("Local AI")
                        .font(.headline)
                        .foregroundStyle(.white)
                }

                Text("Runs entirely on your Mac. Nothing leaves this machine.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 28)

                if localInsufficientRAM {
                    Text("Your Mac needs at least 16 GB of RAM for local AI. Use Cloud AI instead.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 28)
                        .padding(.top, 2)
                } else if selectedPath == .local {
                    localConfigSection
                        .padding(.leading, 28)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var localConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(localModels, id: \.localDirectoryName) { spec in
                localModelRow(spec: spec)
            }

            if localTestState == .success {
                statusRow(icon: "checkmark.circle.fill", color: .green, text: "Local AI is ready. Everything runs on this Mac.")
            } else if existingLocalModel && localTestState == .idle && downloadState == .idle {
                statusRow(icon: "checkmark.circle.fill", color: .green, text: "Local model already downloaded. Ready to use.")
            }

            if !localErrorMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(localErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func localModelRow(spec: LocalModelSpec) -> some View {
        let isDownloaded = LocalModelRegistry.isDownloaded(spec)
        let displayName = modelDisplayName(spec)
        let sizeGB = String(format: "%.1f", spec.estimatedMemoryGB)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(displayName) (\(sizeGB) GB)")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)

                Spacer()

                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else if downloadState == .downloading {
                    // Do nothing here, progress shown below
                } else if case .failed = downloadState {
                    Button("Retry") {
                        startDownload(spec: spec)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(OnboardingTheme.accent)
                } else {
                    Button("Download") {
                        startDownload(spec: spec)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(OnboardingTheme.accent)
                }
            }

            Text("Good for summaries, search, and quick questions.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            if downloadState == .downloading && !isDownloaded {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(OnboardingTheme.accent)

                    Text("Downloading \(displayName) (\(sizeGB) GB)...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            if localTestState == .testing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(localLoadingStage.isEmpty ? "Loading model..." : localLoadingStage)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Skip Option

    private var skipOption: some View {
        VStack(spacing: 6) {
            Divider()
                .overlay(.white.opacity(0.1))

            Button {
                selectedPath = .auto
                skipped = true
                logger.info("User chose to skip model setup")
            } label: {
                Text("Or skip for now")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("Shadow records without AI. You can set this up later in Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    // MARK: - AI Response Section

    private var aiResponseSection: some View {
        VStack(spacing: 8) {
            Divider()
                .overlay(.white.opacity(0.1))
                .padding(.horizontal, 32)

            let visibleText = String(aiResponseText.prefix(aiVisibleCount))
            Text(visibleText)
                .font(.title3)
                .foregroundStyle(OnboardingTheme.accent)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Continue Section

    private var continueSection: some View {
        Button {
            logger.info("User tapped Continue on model setup step")
            // Save llmMode to UserDefaults
            let modeValue: String
            switch selectedPath {
            case .auto: modeValue = "auto"
            case .cloud: modeValue = "cloudOnly"
            case .local: modeValue = "localOnly"
            }
            UserDefaults.standard.set(modeValue, forKey: "llmMode")

            if !skipped {
                UserDefaults.standard.set(true, forKey: "onboardingModelTestPassed")
            }

            // Ensure cloud consent is set when continuing with cloud capability.
            // The test path sets this in testCloudAPI(), but if the user continues
            // with a pre-existing key (without re-testing), we must set it here.
            // Without this, CloudLLMProvider.generate() throws .consentRequired.
            if existingCloudKey || cloudTestState == .success {
                UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")
            }

            onContinue()
        } label: {
            Text("Continue")
                .frame(minWidth: OnboardingTheme.primaryButtonMinWidth, minHeight: 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(OnboardingTheme.accent)
        .disabled(!canContinue)
    }

    // MARK: - Shared UI Components

    @ViewBuilder
    private func optionCard(
        selected: Bool,
        dimmed: Bool = false,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        // When the card is already selected, render as a plain container
        // instead of a Button. This avoids nesting interactive controls
        // (SecureField, inner Buttons) inside an outer Button, which causes
        // accessibility issues and event-stealing in SwiftUI.
        let cardContent = content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? OnboardingTheme.accentSoft : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? OnboardingTheme.accent.opacity(0.5) : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
            )

        if selected {
            cardContent
                .opacity(dimmed ? 0.5 : 1.0)
        } else {
            Button(action: action) {
                cardContent
            }
            .buttonStyle(.plain)
            .opacity(dimmed ? 0.5 : 1.0)
        }
    }

    private func radioCircle(selected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? OnboardingTheme.accent : .white.opacity(0.3), lineWidth: 1.5)
                .frame(width: 18, height: 18)
            if selected {
                Circle()
                    .fill(OnboardingTheme.accent)
                    .frame(width: 10, height: 10)
            }
        }
    }

    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.callout)
            Text(text)
                .font(.callout)
                .foregroundStyle(color)
        }
    }

    private func modelDisplayName(_ spec: LocalModelSpec) -> String {
        if spec.localDirectoryName.contains("7B") { return "Qwen 7B" }
        if spec.localDirectoryName.contains("32B") { return "Qwen 32B" }
        return spec.localDirectoryName
    }

    // MARK: - Pre-Existing State Check

    private func checkPreExistingState() {
        // Check Keychain for existing API key (primary source)
        if let data = KeychainHelper.load(
            service: "com.shadow.app.llm",
            account: "anthropic-api-key"
        ), let key = String(data: data, encoding: .utf8), !key.isEmpty {
            existingCloudKey = true
            logger.info("Pre-existing cloud API key found in Keychain")
        }

        // Also check the environment variable fallback, matching
        // CloudLLMProvider.resolveAPIKey() which checks SHADOW_ANTHROPIC_API_KEY
        // after Keychain. Without this, onboarding reports cloud as unavailable
        // even though the runtime provider would resolve the env var and work.
        if !existingCloudKey,
           let envKey = ProcessInfo.processInfo.environment["SHADOW_ANTHROPIC_API_KEY"],
           !envKey.isEmpty {
            existingCloudKey = true
            logger.info("Pre-existing cloud API key found in environment")
        }

        // Check for existing local models
        if LocalModelRegistry.isDownloaded(LocalModelRegistry.fastDefault) {
            existingLocalModel = true
            logger.info("Pre-existing local model found")
        }
    }

    // MARK: - Hardware Detection

    private func detectHardware() {
        let profile = HardwareProfile.detect()
        hardwareProfile = profile

        if profile.totalRAMGB < 16 {
            localInsufficientRAM = true
            localModels = []
            logger.info("Insufficient RAM for local AI: \(profile.totalRAMGB) GB")
        } else {
            localInsufficientRAM = false
            var models: [LocalModelSpec] = [LocalModelRegistry.fastDefault]
            if profile.totalRAMGB >= 48 {
                models.append(LocalModelRegistry.deepDefault)
            }
            localModels = models
            logger.info("Local AI available: \(models.count) model(s) for \(profile.totalRAMGB) GB RAM")
        }
    }

    // MARK: - Cloud API Test

    private func testCloudAPI() {
        guard !apiKey.isEmpty else { return }

        cloudTestState = .testing
        cloudErrorMessage = ""

        // Save key to Keychain
        guard let keyData = apiKey.data(using: .utf8) else {
            cloudErrorMessage = "Invalid key format."
            cloudTestState = .failed
            return
        }

        let saved = KeychainHelper.save(
            service: "com.shadow.app.llm",
            account: "anthropic-api-key",
            data: keyData
        )

        guard saved else {
            cloudErrorMessage = "Could not save API key to Keychain."
            cloudTestState = .failed
            return
        }

        // Set consent gate BEFORE calling generate()
        UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")

        logger.info("Cloud API test: key saved, consent set, calling generate()")

        Task { @MainActor in
            do {
                let provider = CloudLLMProvider()
                let request = makeTestRequest()
                let response = try await provider.generate(request: request)

                existingCloudKey = true
                cloudTestState = .success
                logger.info("Cloud API test succeeded: \(response.content.count) chars")
                startResponseStreaming(text: response.content)
            } catch let error as LLMProviderError {
                handleCloudError(error)
            } catch {
                cloudErrorMessage = "Could not reach the Anthropic API. Check your internet connection."
                cloudTestState = .failed
                logger.error("Cloud API test failed: \(error, privacy: .public)")
            }
        }
    }

    private func handleCloudError(_ error: LLMProviderError) {
        switch error {
        case .terminalFailure(let reason) where reason.contains("401"):
            cloudErrorMessage = "That key didn't work. Check that it starts with \"sk-ant-\" and try again."
            apiKey = ""
            // Clean up the bad key
            KeychainHelper.delete(service: "com.shadow.app.llm", account: "anthropic-api-key")
        case .transientFailure(let underlying) where underlying.contains("429"):
            cloudErrorMessage = "API is rate limited. Try again in a moment."
        case .timeout:
            cloudErrorMessage = "The request timed out. Try again."
        case .consentRequired:
            // Should never happen since we set consent above. Log and retry.
            logger.error("BUG: consentRequired after setting consent. Retrying.")
            UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")
            cloudErrorMessage = "Unexpected error. Please try again."
        default:
            cloudErrorMessage = "Could not reach the Anthropic API. Check your internet connection."
        }
        cloudTestState = .failed
        logger.warning("Cloud API test error: \(cloudErrorMessage)")
    }

    // MARK: - Local Model Download

    private func startDownload(spec: LocalModelSpec) {
        downloadState = .downloading
        localErrorMessage = ""

        logger.info("Starting download for \(spec.localDirectoryName)")

        let plan = ProvisioningPlan(
            models: [spec],
            estimatedDiskUsageGB: spec.estimatedMemoryGB,
            estimatedPeakMemoryGB: spec.estimatedMemoryGB,
            warnings: []
        )

        // Start the download in a background task
        Task {
            await ModelDownloadManager.shared.startDownloads(plan: plan)
        }

        // Poll for completion every 2 seconds
        startDownloadPolling(spec: spec)
    }

    private func startDownloadPolling(spec: LocalModelSpec) {
        downloadPollTimer?.invalidate()
        downloadPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [spec] _ in
            MainActor.assumeIsolated {
                pollDownloadStatus(spec: spec)
            }
        }
    }

    private func pollDownloadStatus(spec: LocalModelSpec) {
        Task<Void, Never> { @MainActor in
            let status = await ModelDownloadManager.shared.status(for: spec)
            switch status {
            case .completed:
                downloadPollTimer?.invalidate()
                downloadPollTimer = nil
                downloadState = .completed
                existingLocalModel = true
                logger.info("Download complete for \(spec.localDirectoryName)")
                // Auto-test after download
                testLocalModel()
            case .failed(let reason):
                downloadPollTimer?.invalidate()
                downloadPollTimer = nil
                downloadState = .failed(reason)
                localErrorMessage = "Download failed. Check your internet connection and try again."
                logger.error("Download failed for \(spec.localDirectoryName): \(reason)")
            case .downloading:
                break // Still downloading, continue polling
            case .pending:
                break // Not started yet, continue polling
            }
        }
    }

    // MARK: - Local Model Test

    private func testLocalModel() {
        localTestState = .testing
        localErrorMessage = ""
        localLoadingStage = "Loading model..."

        // Multi-stage loading indicator (timer-driven, not actual progress)
        var loadingSeconds: Int = 0
        loadingStageTimer?.invalidate()
        loadingStageTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                loadingSeconds += 1
                if loadingSeconds >= 10 {
                    localLoadingStage = "Almost ready..."
                } else if loadingSeconds >= 5 {
                    localLoadingStage = "Warming up..."
                }
            }
        }

        logger.info("Local model test: loading and generating")

        Task { @MainActor in
            do {
                let provider = LocalLLMProvider()
                let request = makeTestRequest()
                let response = try await provider.generate(request: request)

                loadingStageTimer?.invalidate()
                loadingStageTimer = nil
                localTestState = .success
                logger.info("Local model test succeeded: \(response.content.count) chars")
                startResponseStreaming(text: response.content)
            } catch let error as LLMProviderError {
                handleLocalError(error)
            } catch {
                loadingStageTimer?.invalidate()
                loadingStageTimer = nil
                localErrorMessage = "This model could not load on your Mac. Try cloud AI instead."
                localTestState = .failed
                logger.error("Local model test failed: \(error, privacy: .public)")
            }
        }
    }

    private func handleLocalError(_ error: LLMProviderError) {
        loadingStageTimer?.invalidate()
        loadingStageTimer = nil

        switch error {
        case .unavailable:
            localErrorMessage = "This model could not load on your Mac. Try cloud AI instead."
        case .timeout:
            localErrorMessage = "The request timed out. Try again."
        case .transientFailure:
            localErrorMessage = "This model could not load on your Mac. Try cloud AI instead."
        default:
            localErrorMessage = "This model could not load on your Mac. Try cloud AI instead."
        }
        localTestState = .failed
        logger.warning("Local model test error: \(localErrorMessage)")
    }

    // MARK: - Test Request

    private func makeTestRequest() -> LLMRequest {
        LLMRequest(
            systemPrompt: "You are Shadow, an AI that watches the user's screen and helps them search and understand their day. The user just set you up. Respond warmly in one short sentence. Do not use em dashes.",
            userPrompt: "Hello.",
            tools: [],
            maxTokens: 100,
            temperature: 0.7,
            responseFormat: .text
        )
    }

    // MARK: - Response Streaming Simulation

    /// Reveal the AI response text character by character (35ms per char).
    /// Ghost mouth opens during streaming, closes on completion.
    private func startResponseStreaming(text: String) {
        aiResponseText = text
        aiVisibleCount = 0
        ghostMood = .speaking

        streamingTimer?.invalidate()
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard aiVisibleCount < aiResponseText.count else {
                    streamingTimer?.invalidate()
                    streamingTimer = nil
                    // Brief happy, then neutral
                    ghostMood = .happy
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        MainActor.assumeIsolated {
                            ghostMood = .neutral
                        }
                    }
                    return
                }
                aiVisibleCount += 1
            }
        }
    }

    // MARK: - Cleanup

    private func cleanupTimers() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
        loadingStageTimer?.invalidate()
        loadingStageTimer = nil
    }
}

// MARK: - State Enums

private enum TestState: Equatable {
    case idle
    case testing
    case success
    case failed
}

private enum DownloadState: Equatable {
    case idle
    case downloading
    case completed
    case failed(String)
}
