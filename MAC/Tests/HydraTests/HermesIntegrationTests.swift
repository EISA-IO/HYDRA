import Testing
@testable import Hydra

@Test("Hermes provider labels map to stable upstream provider IDs")
func hermesProviderMapping() {
    #expect(HermesIntegration.providerID(forLabel: "ChatGPT / Codex OAuth") == "openai-codex")
    #expect(HermesIntegration.providerID(forLabel: "Claude / Anthropic") == "anthropic")
    #expect(HermesIntegration.providerID(forLabel: "Ollama (local)") == "custom")
    #expect(HermesIntegration.providerID(forLabel: "OpenRouter") == "openrouter")
    #expect(HermesIntegration.normalizedProviderID("future-provider") == "auto")
    // Provider suggestions must mirror what each provider actually serves: the
    // Claude/Codex catalogs the rest of the app uses, real Ollama tags, and
    // vendor-prefixed OpenRouter IDs.
    #expect(HermesIntegration.modelSuggestions(forProviderID: "anthropic") == ModelCatalog.claude)
    #expect(!HermesIntegration.modelSuggestions(forProviderID: "anthropic").contains { $0.hasPrefix("gpt-") })
    #expect(HermesIntegration.modelSuggestions(forProviderID: "openai-codex") == ModelCatalog.codex)
    #expect(!HermesIntegration.modelSuggestions(forProviderID: "openai-codex").contains { $0.hasPrefix("claude-") })
    #expect(HermesIntegration.modelSuggestions(forProviderID: "custom") == ModelCatalog.ollamaLocal)
    #expect(HermesIntegration.modelSuggestions(forProviderID: "custom").allSatisfy { $0.contains(":") })
    #expect(HermesIntegration.modelSuggestions(forProviderID: "openrouter")
        == ["moonshotai/kimi-k2.7-code", "z-ai/glm-5.2", "deepseek/deepseek-v4-flash"])
    #expect(HermesIntegration.modelSuggestions(forProviderID: "openrouter").allSatisfy { $0.contains("/") })
}

@Test("Hermes profiles follow the upstream portable profile-name contract")
func hermesProfileValidation() {
    #expect(HermesIntegration.validProfile(""))
    #expect(HermesIntegration.validProfile("work_2"))
    #expect(HermesIntegration.validProfile("openrouter-lab"))
    #expect(!HermesIntegration.validProfile("Work"))
    #expect(!HermesIntegration.validProfile("-work"))
    #expect(!HermesIntegration.validProfile("work profile"))
    #expect(Paths.hermesProfileHome("client-a") == Paths.hermesHome + "/profiles/client-a")
    #expect(Paths.hermesProfileHome("../escape") == Paths.hermesHome)
}

@Test("Hermes launch overrides are quoted and do not mutate global configuration")
func hermesLaunchCommand() {
    let command = HermesIntegration.launchCommand(
        model: "anthropic/claude-sonnet-4.6",
        providerID: "openrouter",
        profile: "client-a",
        resume: true,
        extra: "--verbose",
        startupPrompt: "review this repo"
    )
    #expect(command != nil)
    #expect(command!.contains("hermes -p 'client-a' --tui"))
    #expect(command!.contains("--provider 'openrouter'"))
    #expect(command!.contains("--model 'anthropic/claude-sonnet-4.6'"))
    #expect(command!.contains("--continue --verbose 'review this repo'"))
    #expect(HermesIntegration.normalizedModel("model; touch /tmp/nope") == "Default")
    #expect(HermesIntegration.normalizedModel("qwen3-coder:30b") == "qwen3-coder:30b")
}

@Test("Ollama uses Hermes custom-provider environment only for that process")
func hermesOllamaEnvironment() {
    let env = HermesIntegration.environmentOverrides(providerID: "custom")
    #expect(env["OPENROUTER_BASE_URL"] == "http://127.0.0.1:11434/v1")
    #expect(env["OPENAI_API_KEY"] == "no-key-required")
    #expect(HermesIntegration.environmentOverrides(providerID: "anthropic").isEmpty)
}
