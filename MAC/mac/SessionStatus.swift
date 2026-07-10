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

struct SessionEventPayload: Equatable {
    let model: String?

    static func decode(_ data: Data) -> SessionEventPayload? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionEventPayload(model: raw?.isEmpty == false ? raw : nil)
    }
}

enum TerminalPresentation {
    static func modelLabel(configured: String) -> String {
        let value = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.caseInsensitiveCompare("Default") == .orderedSame {
            return "Resolving model…"
        }
        return value
    }

    static func tabHint(task: String, folder: String) -> String {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty && task.caseInsensitiveCompare("Interactive session") != .orderedSame {
            return task
        }
        let project = URL(fileURLWithPath: folder).lastPathComponent
        return project.isEmpty ? "Workspace" : project
    }

    static func taskLabel(startupPrompt: String?, resume: Bool) -> String {
        guard let raw = startupPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return resume ? "Resume last session" : "Interactive session"
        }
        let prompt = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let lower = prompt.lowercased()
        if lower.contains("complete saas") || lower.contains("vision.md") { return "Build SaaS" }
        if lower.contains("deploy.md") || lower.contains("deployed to") { return "Deploy project" }
        if lower.contains("subscriptions.md") || lower.contains("subscription infrastructure") { return "Implement billing" }
        if lower.contains("playbook.md") { return "Run project mission" }
        if prompt.count <= 42 { return prompt }
        return String(prompt.prefix(41)) + "…"
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
            "SessionStart": entry("ready"),
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
        let ready = command(id: id, event: "ready", eventsDirectory: eventsDirectory)
        let work = command(id: id, event: "work", eventsDirectory: eventsDirectory)
        let notify = command(id: id, event: "notify", eventsDirectory: eventsDirectory)
        let stop = command(id: id, event: "stop", eventsDirectory: eventsDirectory, jsonOutput: true)
        return """
        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = "\(tomlString(ready))"
        timeout = 5

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
        let file = TerminalLauncher.shellQuote(prefix) + "$(date +%s)_$RANDOM.evt"
        let capture = "file=\(file); tmp=\"${file}.tmp\"; cat > \"$tmp\"; mv \"$tmp\" \"$file\""
        return jsonOutput ? capture + "; printf '{}'" : capture
    }

    private static func tomlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
