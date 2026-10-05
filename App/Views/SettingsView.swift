import SwiftUI
import HermesKit

struct SettingsView: View {
    @State private var settings = HermesSettings.load()
    @State private var status = "Checking…"
    @State private var lastAction: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("On-device model", value: status)
                    Toggle("Allow Private Cloud Compute", isOn: $settings.allowPrivateCloud)
                    Toggle("Escalate hard requests automatically", isOn: $settings.autoEscalate)
                        .disabled(!settings.allowPrivateCloud)
                } header: {
                    Text("Model")
                } footer: {
                    Text("Off: everything runs on this iPhone. On: /think, and requests that look hard when escalation is on, go to Apple's Private Cloud Compute model (larger, 32K context).")
                }

                Section("Tools") {
                    Toggle("Allow web_fetch (HTTP GET)", isOn: $settings.allowNetworkTools)
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
                    Text("Memory and profile are injected into every request; larger budgets leave less room for conversation in the on-device model's 8K context.")
                }

                Section {
                    Stepper("New conversation after \(settings.siriSessionIdleMinutes) idle min", value: $settings.siriSessionIdleMinutes, in: 5...240, step: 5)
                } header: {
                    Text("Siri")
                } footer: {
                    Text("Say \"Ask Hermes\" to Siri, then your request.")
                }

                Section {
                    Button("Run due jobs now") { run(label: "Jobs run:") { await $0.runDueJobs() } }
                } header: {
                    Text("Scheduled jobs")
                } footer: {
                    Text("For exact timing: Shortcuts › Automation › + › Time of Day › choose a time › add \"Run Hermes Scheduled Jobs\" › Run Immediately. Otherwise jobs run when iOS grants background time or when you open the app.")
                }

                if let lastAction {
                    Section { Text(lastAction).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .task {
                guard let agent = try? await HermesRuntime.ready() else { status = "Failed to start"; return }
                status = await agent.availabilityProblem() ?? "Ready"
            }
            .onChange(of: settings) { _, new in
                Task { try? await HermesRuntime.ready().update(settings: new) }
            }
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
