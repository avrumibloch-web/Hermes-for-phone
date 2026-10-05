import SwiftUI
import UIKit
import HermesKit

@main
struct HermesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var chat = ChatViewModel()

    init() {
        HermesRuntime.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView(model: chat)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                MemoryView()
                    .tabItem { Label("Memory", systemImage: "brain") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task {
                _ = await Notifier.requestPermission()
                // Skills can change (the agent writes its own), so refresh the values Siri
                // accepts in "Run <skill> with Hermes".
                HermesShortcuts.updateAppShortcutParameters()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    guard let agent = try? await HermesRuntime.ready() else { return }
                    await agent.runDueJobs()
                }
            case .background:
                runLearningLoopWhileBackgrounding()
                Task { await HermesRuntime.scheduleBackgroundWork() }
            default:
                break
            }
        }
    }

    /// The learning loop runs right after the user leaves the app, inside the ~30 s iOS
    /// grants a backgrounding app; anything left over waits for the charging-only task.
    @MainActor
    private func runLearningLoopWhileBackgrounding() {
        let assertion = BackgroundAssertion()
        let work = Task {
            if let agent = try? await HermesRuntime.ready() {
                await agent.runPendingReviews(limit: 1)
            }
            await assertion.end()
        }
        assertion.begin { work.cancel() }
    }
}

/// Wraps UIApplication's begin/endBackgroundTask so the identifier isn't a captured var.
@MainActor
final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin(onExpire: @escaping () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: "hermes.review") { [weak self] in
            onExpire()
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
