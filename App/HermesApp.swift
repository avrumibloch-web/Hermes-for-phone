import SwiftUI
import HermesKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@main
struct HermesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var chat = ChatViewModel()

    init() {
        #if os(iOS)
        HermesRuntime.registerBackgroundTasks()
        #else
        MacScheduler.shared.start()
        #endif
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
                #if os(iOS)
                runLearningLoopWhileBackgrounding()
                #endif
                Task { await HermesRuntime.scheduleBackgroundWork() }
            default:
                break
            }
        }

        #if os(macOS)
        // Keeps Hermes reachable from the menu bar after the window is closed, so scheduled
        // jobs keep running on time: the Mac is the always-on half.
        MenuBarExtra("Hermes", systemImage: "sparkles") {
            Button("Run due jobs now") {
                Task { if let agent = try? await HermesRuntime.ready() { await agent.runDueJobs() } }
            }
            Button("Run learning review now") {
                Task { if let agent = try? await HermesRuntime.ready() { await agent.runPendingReviews(limit: 5) } }
            }
            Divider()
            Button("Quit Hermes") { NSApplication.shared.terminate(nil) }
        }
        #endif
    }

    #if os(iOS)
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
    #endif
}

#if os(iOS)
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
#endif

#if os(macOS)
/// On the Mac the app can simply stay running (menu bar), so cron is a real clock: check
/// every minute for due jobs, and run the learning loop when the Mac has been idle a while.
final class MacScheduler: @unchecked Sendable {
    static let shared = MacScheduler()
    private var timer: Timer?
    private var tick = 0

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fire()
        }
    }

    private func fire() {
        tick += 1
        let reviewNow = tick % 15 == 0
        Task.detached(priority: .utility) {
            guard let agent = try? await HermesRuntime.ready() else { return }
            await agent.runDueJobs()
            if reviewNow { await agent.runPendingReviews(limit: 2) }
        }
    }
}
#endif
