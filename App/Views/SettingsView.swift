import SwiftUI
import HermesKit
import HermesLocalModels

struct SettingsView: View {
    @State private var settings = HermesSettings.load()
    @State private var onDeviceStatus = "Checking…"
    @State private var smartStatus = ""
    @State private var downloading = false
    @State private var lastAction: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Apple on-device model", value: onDeviceStatus)
                    Picker("Smart model", selection: $settings.smartModel) {
                        Text("Off").tag(SmartModel.off)
                        Text("Local open model (MLX)").tag(SmartModel.local)
                        Text("Apple Private Cloud Compute").tag(SmartModel.privateCloud)
                    }
                    if settings.smartModel != .off {
                        if !smartStatus.isEmpty { LabeledContent("Status", value: smartStatus) }
                        Toggle("Use it for every request", isOn: $settings.useSmartModelForEverything)
                        Toggle("Use it for hard requests", isOn: $settings.autoEscalate)
                            .disabled(settings.useSmartModelForEverything)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text(modelFooter)
                }

                if settings.smartModel == .local {
                    Section {
                        Picker("Model", selection: $settings.localModelID) {
                            ForEach(MLXLocalModel.recommended) { entry in
                                Text("\(entry.id.split(separator: "/").last ?? "") — \(entry.note)").tag(entry.id)
                            }
                            if !MLXLocalModel.recommended.contains(where: { $0.id == settings.localModelID }) {
                                Text(settings.localModelID).tag(settings.localModelID)
                            }
                        }
                        TextField("Or any mlx-community model id", text: $settings.localModelID)
                            .autocorrectionDisabled()
                        Stepper("Context: \(settings.localContextTokens / 1024)K tokens", value: $settings.localContextTokens, in: 4_096...65_536, step: 4_096)
                        Toggle("Let it think first (slower, smarter)", isOn: $settings.localModelReasoning)
                        Button(downloading ? "Downloading…" : "Download / load model") { download() }
                            .disabled(downloading)
                    } header: {
                        Text("Local model")
                    } footer: {
                        Text("Downloads once from Hugging Face, then runs offline on this device's GPU. Bigger context uses more memory.")
                    }
                }

                Section("Tools") {
                    Toggle("Allow web_fetch (HTTP GET)", isOn: $settings.allowNetworkTools)
                    #if os(macOS)
                    Toggle("Allow terminal commands (chat window only)", isOn: $settings.allowTerminal)
                    #endif
                    Stepper("Max tools per request: \(settings.maxToolsPerTurn)", value: $settings.maxToolsPerTurn, in: 3...10)
                }

                Section {
                    Toggle("Learn from conversations", isOn: $settings.backgroundReview)
                    Stepper("Memory budget: \(settings.memoryCharLimit) chars", value: $settings.memoryCharLimit, in: 400...3_000, step: 100)
                    Stepper("Profile budget: \(settings.userCharLimit) chars", value: $settings.userCharLimit, in: 300...2_000, step: 100)
                    Button("Run learning review now") { run(label: "Reviewed sessions:") { await $0.runPendingReviews(limit: 5) } }
                } header: {
                    Text("Learning")
                } footer: {
                    Text("Memory and profile are added to every request; larger budgets leave less room for conversation in the on-device model's 8K context.")
                }

                Section {
                    Stepper("New conversation after \(settings.siriSessionIdleMinutes) idle min", value: $settings.siriSessionIdleMinutes, in: 5...240, step: 5)
                } header: {
                    Text("Siri (optional voice trigger)")
                } footer: {
                    Text("Say \"Ask Hermes\", then your request. Siri only passes it along; Hermes' own models do the work.")
                }

                Section {
                    Button("Run due jobs now") { run(label: "Jobs run:") { await $0.runDueJobs() } }
                } header: {
                    Text("Scheduled jobs")
                } footer: {
                    #if os(macOS)
                    Text("On the Mac, jobs run on time while Hermes is running (it stays in the menu bar).")
                    #else
                    Text("For exact timing: Shortcuts › Automation › + › Time of Day › choose a time › add \"Run Hermes Scheduled Jobs\" › Run Immediately. Otherwise jobs run when iOS grants background time or when you open the app.")
                    #endif
                }

                if let lastAction {
                    Section { Text(lastAction).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .task { await refreshStatus() }
            .onChange(of: settings) { _, new in
                Task {
                    await HermesRuntime.apply(new)
                    await refreshStatus()
                }
            }
        }
    }

    private var modelFooter: String {
        switch settings.smartModel {
        case .off:
            return "Everything runs on Apple's on-device model: fast, offline, free. Add a smart model for harder requests."
        case .local:
            return "Hard requests (or all, if chosen) go to an open model running on this device. Free and offline after the download. Type /fast to force Apple's model."
        case .privateCloud:
            return "Hard requests go to Apple's larger server model (32K context, reasoning). No cost, but a daily limit per iCloud account, and it needs internet. Type /fast to stay on-device."
        }
    }

    private func refreshStatus() async {
        guard let agent = try? await HermesRuntime.ready() else { onDeviceStatus = "Failed to start"; return }
        let models = ModelProvider(local: await agent.localModel)
        onDeviceStatus = models.onDeviceUnavailableReason() ?? "Ready"
        switch settings.smartModel {
        case .off: smartStatus = ""
        case .local: smartStatus = await models.unavailableReason(.local) ?? "Ready"
        case .privateCloud: smartStatus = models.privateCloudUnavailableReason() ?? "Ready"
        }
    }

    private func download() {
        downloading = true
        Task {
            defer { downloading = false }
            guard let agent = try? await HermesRuntime.ready(), let local = await agent.localModel else { return }
            do {
                try await local.preload()
                lastAction = "\(local.displayName) is ready."
            } catch {
                lastAction = "Download failed: \(error.localizedDescription)"
            }
            await refreshStatus()
        }
    }

    private func run(label: String, _ work: @escaping (HermesAgent) async -> Int) {
        Task {
            guard let agent = try? await HermesRuntime.ready() else { return }
            let n = await work(agent)
            lastAction = "\(label) \(n)"
        }
    }
}
