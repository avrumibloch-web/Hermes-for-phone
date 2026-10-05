#if os(macOS)
import Foundation
import FoundationModels

/// Runs a command-line program and captures its output. Requires the Mac app to run
/// without the App Sandbox (it's a personal tool, not an App Store app).
enum Shell {
    struct Output: Sendable {
        let status: Int32
        let text: String
        let timedOut: Bool
    }

    /// Collects output from the pipe callbacks and resumes the continuation exactly once.
    private final class Run: @unchecked Sendable {
        let process = Process()
        let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private var continuation: CheckedContinuation<Output, Never>?

        init(_ continuation: CheckedContinuation<Output, Never>) {
            self.continuation = continuation
        }

        func append(_ chunk: Data) {
            lock.lock()
            if data.count < 200_000 { data.append(chunk) }
            lock.unlock()
        }

        func finish(timedOut: Bool) {
            lock.lock()
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            pipe.fileHandleForReading.readabilityHandler = nil
            let text = String(decoding: data, as: UTF8.self)
            lock.unlock()
            let status = process.isRunning ? -1 : process.terminationStatus
            continuation.resume(returning: Output(status: status, text: text, timedOut: timedOut))
        }

        func fail(_ message: String) {
            lock.lock()
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: Output(status: -1, text: message, timedOut: false))
        }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async -> Output {
        await withCheckedContinuation { continuation in
            let run = Run(continuation)
            run.process.executableURL = URL(fileURLWithPath: executable)
            run.process.arguments = arguments
            run.process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            run.process.standardOutput = run.pipe
            run.process.standardError = run.pipe
            run.pipe.fileHandleForReading.readabilityHandler = { handle in
                run.append(handle.availableData)
            }
            run.process.terminationHandler = { _ in
                // Give the readability handler a moment to deliver the last chunk. Not
                // reading to EOF on purpose: a background child could hold the pipe open.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { run.finish(timedOut: false) }
            }
            do {
                try run.process.run()
            } catch {
                run.fail(error.localizedDescription)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard run.process.isRunning else { return }
                run.process.terminate()
                run.finish(timedOut: true)
            }
        }
    }
}

/// Hermes' terminal tool, Mac edition. Off unless enabled in Settings, only offered from
/// the chat window (not Siri or scheduled jobs), with a blocklist for destructive commands
/// since a small model can misfire.
struct TerminalTool: Tool {
    let name = "terminal"
    let description = """
    Run a shell command on the user's Mac (zsh, in the home folder) and get its output. \
    Use for files, disk usage (du, df), processes, brew, git. Read-only commands are preferred. \
    Never delete or overwrite files unless the user explicitly asked for exactly that.
    """
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "The shell command to run")
        var command: String
    }

    static let blocked = [
        "rm -rf", "rm -fr", "rm -r /", "sudo ", "mkfs", "diskutil erase", "diskutil partition", "dd if=", ":(){",
        "shutdown", "reboot", "halt", "> /dev/", "chmod -r 777 /", "chown -r", "launchctl unload", "csrutil",
        "nvram", "killall finder", "killall dock", "| sh", "| bash", "| zsh", "curl | ", "wget | ", "security delete",
    ]

    func call(arguments: Arguments) async throws -> String {
        guard context.settings.allowTerminal else { return "Error: the terminal tool is turned off in Settings." }
        let command = arguments.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = command.lowercased()
        if let hit = Self.blocked.first(where: { lower.contains($0) }) {
            await context.log(name, "blocked: \(command)")
            return "Error: blocked for safety (\(hit.trimmingCharacters(in: .whitespaces))). Ask the user to run it themselves."
        }
        let out = await Shell.run("/bin/zsh", ["-lc", command], timeout: 60)
        await context.log(name, "\(command) → \(out.timedOut ? "timeout" : "exit \(out.status)")")
        let header = out.timedOut ? "Timed out after 60 s. Partial output:" : "exit \(out.status)"
        return header + "\n" + TextUtil.truncate(out.text, to: 3_000)
    }
}

/// "What's using my storage?" without a shell: free space, then the biggest folders in
/// the home directory (or a given folder), measured with `du`.
struct DiskUsageTool: Tool {
    let name = "disk_usage"
    let description = "Show free disk space on the Mac and the largest folders inside the home folder, or inside a given folder."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "Optional folder to inspect, e.g. ~/Library or ~/Downloads. Default: home folder")
        var folder: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var target = home
        if let raw = arguments.folder?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            target = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        var lines: [String] = []
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity {
            lines.append("Free: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))")
        }
        // du -sk per child, sorted. -x stays on one volume; errors (permissions) are ignored.
        let out = await Shell.run("/bin/zsh", ["-c", "du -skx -- \"$1\"/* \"$1\"/.[!.]* 2>/dev/null | sort -rn | head -12", "du", target.path], timeout: 90)
        let rows = out.text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            let path = String(parts[1]).replacingOccurrences(of: home.path, with: "~")
            return "\(ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .file))  \(path)"
        }
        lines.append("Largest in \(target.path.replacingOccurrences(of: home.path, with: "~"))\(out.timedOut ? " (partial, timed out)" : ""):")
        lines += rows.isEmpty ? ["(nothing readable; grant Full Disk Access to Hermes for ~/Library)"] : rows
        let result = lines.joined(separator: "\n")
        await context.log(name, target.lastPathComponent)
        return result
    }
}
#endif
