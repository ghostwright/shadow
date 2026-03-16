import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SettingsView")

/// Main Settings view. Replaces the placeholder in ShadowApp.swift.
///
/// Sections:
/// - Intelligence: API key management, cloud consent, model status
/// - Models: local model provisioning status
/// - Mimicry Learning: enriched click stats, workflow extraction, training data
struct SettingsView: View {
    // MARK: - State

    // Anthropic
    @State private var apiKeyField: String = ""
    @State private var apiKeyStatus: APIKeyStatus = .checking
    @State private var testInProgress: Bool = false
    @State private var testResultMessage: String = ""
    @State private var testResultSuccess: Bool = false

    // OpenAI
    @State private var openAIKeyField: String = ""
    @State private var openAIKeyStatus: APIKeyStatus = .checking
    @State private var openAITestInProgress: Bool = false
    @State private var openAITestResultMessage: String = ""
    @State private var openAITestResultSuccess: Bool = false

    // Cloud consent (shared across providers)
    @State private var cloudConsentGranted: Bool = false

    // Mimicry stats (loaded async)
    @State private var enrichedClickCount: Int64 = 0
    @State private var procedureCount: Int = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        Form {
            intelligenceSection
            modelsSection
            mimicryLearningSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 450)
        .onAppear {
            loadAPIKeyStatus()
            loadOpenAIKeyStatus()
            loadMimicryStats()
            cloudConsentGranted = UserDefaults.standard.bool(forKey: "llmCloudConsentGranted")

            // Refresh stats every 10 seconds while visible
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor in
                    loadMimicryStats()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Intelligence Section

    private var intelligenceSection: some View {
        Section {
            // API key status row
            HStack {
                Label("Anthropic API Key", systemImage: "key.fill")
                Spacer()
                apiKeyStatusBadge
            }

            // API key entry
            if apiKeyStatus != .connected {
                HStack(spacing: 8) {
                    SecureField("sk-ant-...", text: $apiKeyField)
                        .textFieldStyle(.roundedBorder)
                        .disabled(testInProgress)

                    Button {
                        saveAndTestAPIKey()
                    } label: {
                        if testInProgress {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Save & Test")
                                .frame(width: 60)
                        }
                    }
                    .disabled(apiKeyField.isEmpty || testInProgress)
                }
            } else {
                HStack {
                    Text("Key stored in Keychain")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Key") {
                        removeAPIKey()
                    }
                    .foregroundStyle(.red)
                }
            }

            // Test result
            if !testResultMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: testResultSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testResultSuccess ? .green : .red)
                    Text(testResultMessage)
                        .font(.callout)
                        .foregroundStyle(testResultSuccess ? .green : .red)
                }
            }

            Divider()

            // OpenAI API key status row
            HStack {
                Label("OpenAI API Key", systemImage: "key.fill")
                Spacer()
                openAIKeyStatusBadge
            }

            // OpenAI key entry
            if openAIKeyStatus != .connected {
                HStack(spacing: 8) {
                    SecureField("sk-...", text: $openAIKeyField)
                        .textFieldStyle(.roundedBorder)
                        .disabled(openAITestInProgress)

                    Button {
                        saveAndTestOpenAIKey()
                    } label: {
                        if openAITestInProgress {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Save & Test")
                                .frame(width: 60)
                        }
                    }
                    .disabled(openAIKeyField.isEmpty || openAITestInProgress)
                }
            } else {
                HStack {
                    Text("Key stored in Keychain")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Key") {
                        removeOpenAIKey()
                    }
                    .foregroundStyle(.red)
                }
            }

            // OpenAI test result
            if !openAITestResultMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: openAITestResultSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(openAITestResultSuccess ? .green : .red)
                    Text(openAITestResultMessage)
                        .font(.callout)
                        .foregroundStyle(openAITestResultSuccess ? .green : .red)
                }
            }

            Divider()

            // Cloud consent toggle
            Toggle(isOn: $cloudConsentGranted) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow cloud AI")
                    Text("Send data to Anthropic or OpenAI for summarization and agent tasks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: cloudConsentGranted) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "llmCloudConsentGranted")
                logger.info("Cloud consent set to \(newValue)")
            }
        } header: {
            Text("Intelligence")
        } footer: {
            Text("API keys are stored securely in the macOS Keychain. You can also set SHADOW_ANTHROPIC_API_KEY or SHADOW_OPENAI_API_KEY environment variables.")
                .font(.caption)
        }
    }

    // MARK: - Models Section

    private var modelsSection: some View {
        Section("Models") {
            modelRow(
                name: "Qwen 7B (Fast)",
                spec: LocalModelRegistry.fastDefault,
                description: "Summaries, quick questions, tool calling"
            )
            modelRow(
                name: "Qwen 32B (Deep)",
                spec: LocalModelRegistry.deepDefault,
                description: "Complex reasoning and analysis"
            )
            modelRow(
                name: "Qwen VL 7B (Vision)",
                spec: LocalModelRegistry.visionDefault,
                description: "Screenshot understanding"
            )
            modelRow(
                name: "ShowUI-2B (Grounding)",
                spec: LocalModelRegistry.groundingDefault,
                description: "UI element grounding for Mimicry"
            )
            modelRow(
                name: "Nomic Embed (Search)",
                spec: LocalModelRegistry.embedDefault,
                description: "Semantic text search"
            )
        }
    }

    private func modelRow(name: String, spec: LocalModelSpec, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(String(format: "%.1f GB", spec.estimatedMemoryGB))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if LocalModelRegistry.isDownloaded(spec) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Mimicry Learning Section

    private var mimicryLearningSection: some View {
        Section {
            // Enriched clicks
            HStack {
                Label("Enriched Clicks", systemImage: "cursorarrow.click.2")
                Spacer()
                Text("\(enrichedClickCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Extracted workflows
            HStack {
                Label("Extracted Workflows", systemImage: "arrow.triangle.branch")
                Spacer()
                Text("\(procedureCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Grounding model status
            HStack {
                Label("Grounding Model", systemImage: "eye.trianglebadge.exclamationmark")
                Spacer()
                if LocalModelRegistry.isDownloaded(LocalModelRegistry.groundingDefault) {
                    Text("Available")
                        .foregroundStyle(.green)
                } else {
                    Text("Not downloaded")
                        .foregroundStyle(.orange)
                }
            }

            // LoRA adapter status
            HStack {
                Label("LoRA Adapter", systemImage: "brain.head.profile.fill")
                Spacer()
                if hasLoRAAdapter() {
                    Text("Installed")
                        .foregroundStyle(.green)
                } else {
                    Text("Not yet trained")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mimicry Learning")
        } footer: {
            Text("Mimicry passively learns from your interactions. Enriched clicks capture what you click, workflows extract recurring patterns, and the grounding model learns your specific desktop layout. More data means better automated task execution.")
                .font(.caption)
        }
    }

    // MARK: - API Key Status Badge

    @ViewBuilder
    private var apiKeyStatusBadge: some View {
        switch apiKeyStatus {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .connected:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        case .notConfigured:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Not configured")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .envVarOnly:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Via env var")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var openAIKeyStatusBadge: some View {
        switch openAIKeyStatus {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .connected:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        case .notConfigured:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Not configured")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .envVarOnly:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Via env var")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Actions

    private func loadAPIKeyStatus() {
        // Check Keychain
        if let data = KeychainHelper.load(
            service: "com.shadow.app.llm",
            account: "anthropic-api-key"
        ), let key = String(data: data, encoding: .utf8), !key.isEmpty {
            apiKeyStatus = .connected
            return
        }

        // Check env var
        if let envKey = ProcessInfo.processInfo.environment["SHADOW_ANTHROPIC_API_KEY"],
           !envKey.isEmpty {
            apiKeyStatus = .envVarOnly
            return
        }

        apiKeyStatus = .notConfigured
    }

    private func saveAndTestAPIKey() {
        guard !apiKeyField.isEmpty else { return }

        testInProgress = true
        testResultMessage = ""

        guard let keyData = apiKeyField.data(using: .utf8) else {
            testResultMessage = "Invalid key format."
            testResultSuccess = false
            testInProgress = false
            return
        }

        // Save to Keychain
        let saved = KeychainHelper.save(
            service: "com.shadow.app.llm",
            account: "anthropic-api-key",
            data: keyData
        )

        guard saved else {
            testResultMessage = "Could not save to Keychain."
            testResultSuccess = false
            testInProgress = false
            return
        }

        // Enable cloud consent for the test
        UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")
        cloudConsentGranted = true

        // Make a small test API call
        Task { @MainActor in
            do {
                let provider = CloudLLMProvider()
                let request = LLMRequest(
                    systemPrompt: "Respond with exactly: OK",
                    userPrompt: "Test connection.",
                    maxTokens: 10,
                    temperature: 0.0,
                    responseFormat: .text
                )
                _ = try await provider.generate(request: request)

                testResultMessage = "Connection verified."
                testResultSuccess = true
                apiKeyStatus = .connected
                apiKeyField = ""
                logger.info("API key test succeeded")
            } catch let error as LLMProviderError {
                switch error {
                case .terminalFailure(let reason) where reason.contains("401"):
                    testResultMessage = "Invalid API key. Check that it starts with sk-ant- and try again."
                    KeychainHelper.delete(service: "com.shadow.app.llm", account: "anthropic-api-key")
                    apiKeyStatus = .notConfigured
                case .timeout:
                    testResultMessage = "Request timed out. Try again."
                default:
                    testResultMessage = "Connection failed: \(error.localizedDescription)"
                }
                testResultSuccess = false
                logger.warning("API key test failed: \(testResultMessage)")
            } catch {
                testResultMessage = "Connection failed. Check your internet."
                testResultSuccess = false
                logger.error("API key test failed: \(error, privacy: .public)")
            }

            testInProgress = false
        }
    }

    private func removeAPIKey() {
        KeychainHelper.delete(service: "com.shadow.app.llm", account: "anthropic-api-key")
        apiKeyStatus = .notConfigured
        apiKeyField = ""
        testResultMessage = ""
        logger.info("API key removed from Keychain")
    }

    // MARK: - OpenAI Key Actions

    private func loadOpenAIKeyStatus() {
        // Check Keychain
        if let data = KeychainHelper.load(
            service: OpenAILLMProvider.keychainService,
            account: OpenAILLMProvider.keychainAccount
        ), let key = String(data: data, encoding: .utf8), !key.isEmpty {
            openAIKeyStatus = .connected
            return
        }

        // Check env var
        if let envKey = ProcessInfo.processInfo.environment["SHADOW_OPENAI_API_KEY"],
           !envKey.isEmpty {
            openAIKeyStatus = .envVarOnly
            return
        }

        openAIKeyStatus = .notConfigured
    }

    private func saveAndTestOpenAIKey() {
        guard !openAIKeyField.isEmpty else { return }

        openAITestInProgress = true
        openAITestResultMessage = ""

        guard let keyData = openAIKeyField.data(using: .utf8) else {
            openAITestResultMessage = "Invalid key format."
            openAITestResultSuccess = false
            openAITestInProgress = false
            return
        }

        // Save to Keychain
        let saved = KeychainHelper.save(
            service: OpenAILLMProvider.keychainService,
            account: OpenAILLMProvider.keychainAccount,
            data: keyData
        )

        guard saved else {
            openAITestResultMessage = "Could not save to Keychain."
            openAITestResultSuccess = false
            openAITestInProgress = false
            return
        }

        // Enable cloud consent for the test
        UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")
        cloudConsentGranted = true

        // Make a small test API call
        Task { @MainActor in
            do {
                let provider = OpenAILLMProvider()
                let request = LLMRequest(
                    systemPrompt: "Respond with exactly: OK",
                    userPrompt: "Test connection.",
                    maxTokens: 10,
                    temperature: 0.0,
                    responseFormat: .text
                )
                _ = try await provider.generate(request: request)

                openAITestResultMessage = "Connection verified."
                openAITestResultSuccess = true
                openAIKeyStatus = .connected
                openAIKeyField = ""
                logger.info("OpenAI API key test succeeded")
            } catch let error as LLMProviderError {
                switch error {
                case .terminalFailure(let reason) where reason.contains("401"):
                    openAITestResultMessage = "Invalid API key. Check that it starts with sk- and try again."
                    KeychainHelper.delete(
                        service: OpenAILLMProvider.keychainService,
                        account: OpenAILLMProvider.keychainAccount
                    )
                    openAIKeyStatus = .notConfigured
                case .timeout:
                    openAITestResultMessage = "Request timed out. Try again."
                default:
                    openAITestResultMessage = "Connection failed: \(error.localizedDescription)"
                }
                openAITestResultSuccess = false
                logger.warning("OpenAI API key test failed: \(openAITestResultMessage)")
            } catch {
                openAITestResultMessage = "Connection failed. Check your internet."
                openAITestResultSuccess = false
                logger.error("OpenAI API key test failed: \(error, privacy: .public)")
            }

            openAITestInProgress = false
        }
    }

    private func removeOpenAIKey() {
        KeychainHelper.delete(
            service: OpenAILLMProvider.keychainService,
            account: OpenAILLMProvider.keychainAccount
        )
        openAIKeyStatus = .notConfigured
        openAIKeyField = ""
        openAITestResultMessage = ""
        logger.info("OpenAI API key removed from Keychain")
    }

    private func loadMimicryStats() {
        // Enriched click count from Rust FFI
        do {
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let weekAgo = now - (7 * 24 * 3600 * 1_000_000)
            enrichedClickCount = Int64(try countEnrichedClicks(startUs: weekAgo, endUs: now))
        } catch {
            enrichedClickCount = 0
        }

        // Procedure count from ProcedureStore
        Task {
            let store = ProcedureStore()
            let all = await store.listAll()
            await MainActor.run {
                procedureCount = all.count
            }
        }
    }

    private func hasLoRAAdapter() -> Bool {
        let adapterPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/data/training/adapters/active")
        return FileManager.default.fileExists(atPath: adapterPath.path)
    }
}

// MARK: - Supporting Types

private enum APIKeyStatus {
    case checking
    case connected
    case notConfigured
    case envVarOnly
}
