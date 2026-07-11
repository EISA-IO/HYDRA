import Foundation

/// Stable boundary between Hydra and the Hermes CLI.
///
/// Hydra intentionally never rewrites ~/.hermes/config.yaml or ~/.hermes/.env.
/// Provider/model/profile choices are per-process CLI overrides, while Hermes keeps
/// ownership of authentication, migrations and updates.
/// Canonical model catalogs — one source of truth shared by the Claude/Codex
/// launch pickers (AppState) and the Hermes provider→model mapping below.
enum ModelCatalog {
    static let claude = ["Default", "claude-fable-5", "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"]
    static let codex = ["Default", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                        "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark"]
    /// Local Ollama tags: the recommended seeds plus common local coding models.
    static let ollamaLocal = ["ornith:9b", "ornith:35b", "qwen3-coder:30b", "gpt-oss:20b"]
    /// OpenRouter: the curated allow-list of vendor-prefixed IDs Hydra supports.
    static let openRouter = ["moonshotai/kimi-k2.7-code", "z-ai/glm-5.2", "deepseek/deepseek-v4-flash"]
}

enum HermesIntegration {
    static let providerOptions = [
        "Hermes default",
        "ChatGPT / Codex OAuth",
        "Claude / Anthropic",
        "Ollama (local)",
        "OpenRouter"
    ]

    /// "Hermes default" (auto) can land on any provider, so offer a cross-section.
    static let modelSuggestions = [
        "Default",
        "gpt-5.6-sol",
        "gpt-5.5",
        "claude-sonnet-5",
        "claude-opus-4-8",
        "qwen3-coder:30b",
        "gpt-oss:20b"
    ]

    static func modelSuggestions(forProviderID providerID: String) -> [String] {
        switch normalizedProviderID(providerID) {
        case "openai-codex": return ModelCatalog.codex      // Codex OAuth serves the same models as the Codex CLI
        case "anthropic": return ModelCatalog.claude        // Anthropic serves the same models as the Claude CLI
        case "custom": return ModelCatalog.ollamaLocal      // must be an installed/pullable Ollama tag
        case "openrouter": return ModelCatalog.openRouter
        default: return modelSuggestions
        }
    }

    private static let providerByLabel = [
        "Hermes default": "auto",
        "ChatGPT / Codex OAuth": "openai-codex",
        "Claude / Anthropic": "anthropic",
        "Ollama (local)": "custom",
        "OpenRouter": "openrouter"
    ]

    static func providerID(forLabel label: String) -> String {
        providerByLabel[label] ?? "auto"
    }

    static func normalizedProviderID(_ value: String) -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return providerByLabel.values.contains(key) ? key : "auto"
    }

    static func providerLabel(forID id: String) -> String {
        let normalized = normalizedProviderID(id)
        return providerByLabel.first(where: { $0.value == normalized })?.key ?? "Hermes default"
    }

    static func normalizedModel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Default") != .orderedSame else {
            return "Default"
        }
        guard trimmed.count <= 200,
              let regex = try? NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:/@+\\-]{0,199}$") else {
            return "Default"
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return regex.firstMatch(in: trimmed, range: range)?.range == range ? trimmed : "Default"
    }

    static func validProfile(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard value.count <= 64,
              let regex = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$") else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range)?.range == range
    }

    static func launchCommand(model: String, providerID: String, profile: String,
                              resume: Bool, extra: String, startupPrompt: String?) -> String? {
        let cleanProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validProfile(cleanProfile) else { return nil }

        var command = "hermes"
        if !cleanProfile.isEmpty { command += " -p " + TerminalLauncher.shellQuote(cleanProfile) }
        command += " --tui"

        let provider = normalizedProviderID(providerID)
        if provider != "auto" { command += " --provider " + TerminalLauncher.shellQuote(provider) }

        let cleanModel = normalizedModel(model)
        if cleanModel != "Default" { command += " --model " + TerminalLauncher.shellQuote(cleanModel) }
        if resume { command += " --continue" }

        let cleanExtra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanExtra.isEmpty { command += " " + cleanExtra }
        if let prompt = startupPrompt, !prompt.isEmpty {
            command += " " + TerminalLauncher.shellQuote(prompt)
        }
        return command
    }

    static func environmentOverrides(providerID: String) -> [String: String] {
        guard normalizedProviderID(providerID) == "custom" else { return [:] }
        return [
            "OPENROUTER_BASE_URL": "http://127.0.0.1:11434/v1",
            "OPENAI_API_KEY": "no-key-required"
        ]
    }
}
