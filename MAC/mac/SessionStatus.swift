import Foundation

enum TerminalStatus: Equatable {
    case ready
    case working
    case waitingForUser
    case stoppedOrTokenLimit

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .working: return "Working"
        case .waitingForUser: return "Waiting for User"
        case .stoppedOrTokenLimit: return "Stopped / Token Limit"
        }
    }

    func applying(event: String) -> TerminalStatus {
        if self == .stoppedOrTokenLimit { return self }
        switch event {
        case "work": return .working
        case "stop", "notify": return .waitingForUser
        case "failure", "exited": return .stoppedOrTokenLimit
        default: return self
        }
    }
}

enum SessionHookConfig {
    static func claudeHooks(id: String, eventsDirectory: String) -> [String: Any] {
        func entry(_ event: String) -> [[String: Any]] {
            [["hooks": [[
                "type": "command",
                "command": command(id: id, event: event, eventsDirectory: eventsDirectory)
            ]]]]
        }
        return [
            "UserPromptSubmit": entry("work"),
            "Notification": [[
                "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
                "hooks": [[
                    "type": "command",
                    "command": command(id: id, event: "notify", eventsDirectory: eventsDirectory)
                ]]
            ]],
            "Stop": entry("stop"),
            "StopFailure": entry("failure")
        ]
    }

    static func codexProfile(id: String, eventsDirectory: String) -> String {
        let work = command(id: id, event: "work", eventsDirectory: eventsDirectory)
        let notify = command(id: id, event: "notify", eventsDirectory: eventsDirectory)
        let stop = command(id: id, event: "stop", eventsDirectory: eventsDirectory, jsonOutput: true)
        return """
        [[hooks.UserPromptSubmit]]
        [[hooks.UserPromptSubmit.hooks]]
        type = "command"
        command = "\(tomlString(work))"
        timeout = 5

        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = "\(tomlString(notify))"
        timeout = 5

        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = "\(tomlString(stop))"
        timeout = 5
        """
    }

    private static func command(id: String, event: String, eventsDirectory: String,
                                jsonOutput: Bool = false) -> String {
        let prefix = eventsDirectory + "/\(id)__\(event)__"
        let touch = "touch " + TerminalLauncher.shellQuote(prefix) + "$(date +%s)_$RANDOM.evt"
        return jsonOutput ? touch + "; printf '{}'" : touch
    }

    private static func tomlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
