import Foundation
import FoundationModels
#if canImport(UIKit)
import UIKit
#endif

struct DeviceStatusTool: Tool {
    let name = "device_status"
    let description = "Get the iPhone's battery level and charging state, Low Power Mode, thermal state and free storage."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "Set true to include free storage")
        var includeStorage: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        let result = await DeviceStatus.report(includeStorage: arguments.includeStorage)
        await context.log(name, result)
        return result
    }
}

/// Shared by the `device_status` tool and the "Get Phone Status" App Intent.
public enum DeviceStatus {
    public static func report(includeStorage: Bool) async -> String {
        var parts: [String] = []
        #if canImport(UIKit)
        let battery = await MainActor.run { () -> (Float, UIDevice.BatteryState) in
            UIDevice.current.isBatteryMonitoringEnabled = true
            return (UIDevice.current.batteryLevel, UIDevice.current.batteryState)
        }
        if battery.0 >= 0 {
            let state: String
            switch battery.1 {
            case .charging: state = "charging"
            case .full: state = "full"
            case .unplugged: state = "on battery"
            default: state = "unknown"
            }
            parts.append("Battery \(Int((battery.0 * 100).rounded()))% (\(state))")
        }
        #endif
        let info = ProcessInfo.processInfo
        parts.append("Low Power Mode \(info.isLowPowerModeEnabled ? "on" : "off")")
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "normal"
        case .fair: thermal = "warm"
        case .serious: thermal = "hot"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        parts.append("Thermal \(thermal)")
        if includeStorage,
           let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            parts.append("Free storage \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        return parts.joined(separator: ". ") + "."
    }
}

/// Runs one of the user's Shortcuts by name. This is the escape hatch to everything Apple
/// doesn't expose to third-party apps directly (HomeKit scenes, Messages, Music, Focus,
/// other apps' actions). iOS only allows it while Hermes is in the foreground: it opens the
/// Shortcuts app via URL scheme.
struct RunShortcutTool: Tool {
    let name = "run_shortcut"
    let description = "Run one of the user's Shortcuts by its exact name, optionally passing text input. Use for home control, messages, music and other apps."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "Exact Shortcut name")
        var shortcutName: String
        @Guide(description: "Optional text passed as the Shortcut's input")
        var input: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var components = URLComponents(string: "shortcuts://run-shortcut")!
        var items = [URLQueryItem(name: "name", value: arguments.shortcutName)]
        if let input = arguments.input, !input.isEmpty {
            items += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)]
        }
        components.queryItems = items
        guard let url = components.url else { return "Error: invalid shortcut name." }
        #if canImport(UIKit)
        let opened: Bool = await MainActor.run {
            guard UIApplication.shared.applicationState == .active else { return false }
            UIApplication.shared.open(url)
            return true
        }
        await context.log(name, "\(arguments.shortcutName): \(opened ? "started" : "needs foreground")")
        return opened
            ? "Started Shortcut \"\(arguments.shortcutName)\". Its result isn't returned to Hermes."
            : "Error: Shortcuts can only be started while Hermes is open on screen."
        #else
        return "Error: Shortcuts aren't available on this platform."
        #endif
    }
}
