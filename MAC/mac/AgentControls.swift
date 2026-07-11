import SwiftUI
import AppKit

// Native agent configuration lives in each CLI's own files. Hydra only edits
// documented keys and keeps a side-by-side .hydra.bak before rewriting a file.
extension AppState {
    private var hermesProfileArguments: [String] {
        let profile = hermesProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty || !HermesIntegration.validProfile(profile) ? [] : ["-p", profile]
    }
    private var hermesProfileCommand: String {
        let profile = hermesProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty || !HermesIntegration.validProfile(profile) ? "hermes" : "hermes -p " + TerminalLauncher.shellQuote(profile)
    }

    func openManagedText(_ path: String, initial: String = "") {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if !FS.exists(path) { FS.write(path, initial) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openManagedFolder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func jsonBool(_ path: String, _ key: String, fallback: Bool) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? Bool else { return fallback }
        return value
    }

    private static func setJSONBool(_ path: String, _ key: String, _ value: Bool) throws {
        var object: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Hydra", code: 1, userInfo: [NSLocalizedDescriptionKey: "The settings file is not a JSON object."])
            }
            object = parsed
            try? FileManager.default.removeItem(atPath: path + ".hydra.bak")
            try? FileManager.default.copyItem(atPath: path, toPath: path + ".hydra.bak")
        }
        object[key] = value
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func tomlValue(_ path: String, _ key: String) -> String {
        guard let text = FS.read(path) else { return "" }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard line.hasPrefix(key) else { continue }
            let tail = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard tail.hasPrefix("=") else { continue }
            return tail.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return ""
    }

    private static func setTomlValue(_ path: String, _ key: String, _ value: String?) throws {
        var lines = (FS.read(path) ?? "").components(separatedBy: .newlines)
        let tableIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        var top = Array(lines[..<tableIndex])
        let tables = tableIndex < lines.endIndex ? Array(lines[tableIndex...]) : []
        top.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(key)
                && trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
        if let value, !value.isEmpty {
            top.append("\(key) = \(value)")
        }
        lines = top + tables
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        if FS.exists(path) {
            try? FileManager.default.removeItem(atPath: path + ".hydra.bak")
            try? FileManager.default.copyItem(atPath: path, toPath: path + ".hydra.bak")
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func validOptionalTokens(_ text: String, label: String) throws -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return nil }
        guard let value = Int(clean), value >= 1024 else {
            throw NSError(domain: "Hydra", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(label) must be blank or at least 1,024 tokens."])
        }
        return String(value)
    }

    func setClaudeAutoMemory(_ enabled: Bool) {
        do {
            try Self.setJSONBool(Paths.claudeSettings, "autoMemoryEnabled", enabled)
            claudeAutoMemory = enabled
        } catch { alert("Claude settings", error.localizedDescription); refreshAgentControls() }
    }

    func setCodexMemories(_ enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.shared.run("codex", ["features", enabled ? "enable" : "disable", "memories"], timeout: 30)
            DispatchQueue.main.async {
                if result.code != 0 { self.alert("Codex memories", result.err.isEmpty ? "Codex could not update the feature." : result.err) }
                self.refreshAgentControls()
            }
        }
    }

    func applyCodexContext() {
        do {
            let window = try Self.validOptionalTokens(codexContextWindow, label: "Context window")
            let compact = try Self.validOptionalTokens(codexCompactLimit, label: "Auto-compact threshold")
            try Self.setTomlValue(Paths.codexConfig, "model_context_window", window)
            try Self.setTomlValue(Paths.codexConfig, "model_auto_compact_token_limit", compact)
        } catch { alert("Codex context", error.localizedDescription) }
    }

    func setHermesCompression(_ enabled: Bool) {
        setHermesConfig("compression.enabled", value: enabled ? "true" : "false")
    }

    func applyHermesThreshold() {
        guard let percent = Int(hermesCompressionThreshold), (10...95).contains(percent) else {
            alert("Hermes context", "Compression threshold must be between 10 and 95 percent."); return
        }
        setHermesConfig("compression.threshold", value: String(format: "%.2f", Double(percent) / 100.0))
    }

    private func setHermesConfig(_ key: String, value: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.shared.run("hermes", self.hermesProfileArguments + ["config", "set", key, value], timeout: 30)
            DispatchQueue.main.async {
                if result.code != 0 { self.alert("Hermes context", result.err.isEmpty ? "Hermes could not update its configuration." : result.err) }
                self.refreshAgentControls()
            }
        }
    }

    func runHermesMemory(_ arguments: String, task: String) {
        guard Shell.shared.onPath("hermes") else { alert("Hermes not installed", "Install Hermes from Settings first."); return }
        runInWorkspace(hermesProfileCommand + " " + arguments, cwd: folder,
                       note: task, agentLabel: "Hermes", modelLabel: "Memory", taskLabel: task)
    }

    func manageHermesSkills(_ command: String = "skills") {
        runHermesMemory(command, task: "Manage Hermes skills")
    }

    func refreshAgentControls() {
        let claude = Self.jsonBool(Paths.claudeSettings, "autoMemoryEnabled", fallback: true)
        let context = Self.tomlValue(Paths.codexConfig, "model_context_window")
        let compact = Self.tomlValue(Paths.codexConfig, "model_auto_compact_token_limit")
        DispatchQueue.global(qos: .utility).async {
            let features = Shell.shared.run("codex", ["features", "list"], timeout: 30)
            let codexMemory = features.out.split(separator: "\n").contains { line in
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                return fields.first == "memories" && fields.last == "true"
            }
            let hermes = Shell.shared.run("hermes", self.hermesProfileArguments + ["config", "show"], timeout: 30)
            let compression = !hermes.out.split(separator: "\n").contains { line in
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return clean.hasPrefix("enabled:") && (clean.hasSuffix("no") || clean.hasSuffix("off") || clean.hasSuffix("false"))
            }
            let threshold = hermes.out.split(separator: "\n").compactMap { line -> String? in
                guard line.localizedCaseInsensitiveContains("Threshold:") else { return nil }
                return line.split(whereSeparator: { !$0.isNumber }).first.map(String.init)
            }.first ?? "50"
            DispatchQueue.main.async {
                self.claudeAutoMemory = claude
                self.codexMemories = codexMemory
                self.codexContextWindow = context
                self.codexCompactLimit = compact
                self.hermesCompression = compression
                self.hermesCompressionThreshold = threshold
            }
        }
    }

    private static func mcpDisplay(_ result: RunResult, unavailable: String) -> String {
        let text = [result.out, result.err].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return result.code == 0 ? "No MCP servers configured." : unavailable
    }

    func refreshMCP() {
        guard !mcpBusy else { return }
        mcpBusy = true; mcpStatus = "Checking \(folder)…"
        mcpClaude = "Checking native CLI…"; mcpCodex = "Checking native CLI…"; mcpHermes = "Checking native CLI…"
        let cwd = FS.isDir(folder) ? folder : Paths.home
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = Shell.shared.run("claude", ["mcp", "list"], cwd: cwd, timeout: 30)
            let codex = Shell.shared.run("codex", ["mcp", "list"], cwd: cwd, timeout: 30)
            let hermes = Shell.shared.run("hermes", self.hermesProfileArguments + ["mcp", "list"], cwd: cwd, timeout: 30)
            DispatchQueue.main.async {
                self.mcpClaude = Self.mcpDisplay(claude, unavailable: "Claude CLI is unavailable or MCP discovery failed.")
                self.mcpCodex = Self.mcpDisplay(codex, unavailable: "Codex CLI is unavailable or MCP discovery failed.")
                self.mcpHermes = Self.mcpDisplay(hermes, unavailable: "Hermes CLI is unavailable or MCP discovery failed.")
                self.mcpStatus = "Updated \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) · \(cwd)"
                self.mcpBusy = false
            }
        }
    }
}

struct SettingsHubView: View {
    @EnvironmentObject var app: AppState
    @State private var section = "Launch & agents"
    private let sections = ["Launch & agents", "Memory & context", "Compression", "System & updates"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings").font(.system(size: 21, weight: .bold)).foregroundStyle(.white)
                Text("Launch behavior, agent memory, context budgets, and maintenance — grouped by purpose.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            Picker("Settings section", selection: $section) {
                ForEach(sections, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 680)
            ScrollView {
                Group {
                    switch section {
                    case "Memory & context": MemoryContextPane()
                    case "Compression": CompressionSettingsPane()
                    case "System & updates": SystemSettingsPane()
                    default: LaunchSettingsPane()
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(22)
        .onAppear { app.refreshAll(); app.refreshAgentControls() }
    }
}

struct LaunchSettingsPane: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCap(text: "1  Choose what New Terminal starts")
                    Text("This only chooses the agent. Each agent keeps its own default model below.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    Picker("", selection: Binding(get: { app.agent }, set: { app.setAgent($0) })) {
                        ForEach(app.agentOptions, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
                    Text("Pressing + New Terminal opens \(app.agent) in your selected project folder.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCap(text: "2  Set the Claude and Codex default models")
                    Text("These defaults are remembered separately and apply only to new terminals. “Default” lets that CLI choose its current default model.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 7) {
                            FieldLabel(text: "Claude Code")
                            DarkPicker(options: app.launchModelOptions(for: "Claude"), selection: Binding(
                                get: { app.defaultModel(for: "Claude") },
                                set: { app.setDefaultModel($0, for: "Claude") }))
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            FieldLabel(text: "Codex")
                            DarkPicker(options: app.launchModelOptions(for: "Codex"), selection: Binding(
                                get: { app.defaultModel(for: "Codex") },
                                set: { app.setDefaultModel($0, for: "Codex") }))
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCap(text: "3  Map Hermes to an LLM")
                    Text("Choose where Hermes authenticates, then choose or type the model that provider should run.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 7) {
                            FieldLabel(text: "Provider / account")
                            DarkPicker(options: app.hermesProviderOptions, selection: Binding(
                                get: { HermesIntegration.providerLabel(forID: app.hermesProvider) },
                                set: { app.setHermesProviderLabel($0) }))
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            FieldLabel(text: "Hermes model ID")
                            HStack(spacing: 6) {
                                DarkField(placeholder: "Default", text: Binding(
                                    get: { app.defaultModel(for: "Hermes") },
                                    set: { app.setDefaultModel($0, for: "Hermes") }), mono: true)
                                Menu("Suggestions") {
                                    ForEach(HermesIntegration.modelSuggestions(forProviderID: app.hermesProvider), id: \.self) { model in
                                        Button(model) { app.setDefaultModel(model, for: "Hermes") }
                                    }
                                }.menuStyle(.borderlessButton)
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            FieldLabel(text: "Profile (optional)")
                            DarkField(placeholder: "default", text: $app.hermesProfile, mono: true)
                                .onChange(of: app.hermesProfile) { app.saveSettings(); app.loadSkills() }
                        }
                    }
                    Text("Hermes will use  \(HermesIntegration.providerLabel(forID: app.hermesProvider))  →  \(app.defaultModel(for: "Hermes") == "Default" ? "provider default model" : app.defaultModel(for: "Hermes"))")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accentHi)
                    FlowButtons { [
                        AnyView(Button("Configure Hermes accounts") { app.configureHermes() }.accentButton()),
                        AnyView(Button("Install / repair") { app.installHermes() }.ghostButton()),
                        AnyView(Button("Doctor") { app.doctorHermes() }.ghostButton()),
                        AnyView(Button("Check update") { app.checkHermesUpdate() }.ghostButton())
                    ] }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCap(text: "4  Session behavior")
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 7) {
                            FieldLabel(text: "Claude / Codex permissions")
                            DarkPicker(options: app.permissionOptions, selection: $app.permission)
                                .onChange(of: app.permission) { app.saveSettings() }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            FieldLabel(text: "Conversation")
                            Toggle("Resume the previous conversation when supported", isOn: $app.continueLast)
                                .toggleStyle(.checkbox).onChange(of: app.continueLast) { app.saveSettings() }
                        }
                    }
                    FieldLabel(text: "Extra launch flags (advanced, optional)")
                    DarkField(placeholder: "--effort high", text: $app.extraArgs, mono: true)
                        .onChange(of: app.extraArgs) { app.saveSettings() }
                }
            }
        }
    }
}

struct MemoryContextPane: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    SectionCap(text: "Claude memory & context")
                    Text("CLAUDE.md and per-project auto-memory are loaded into new sessions.").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    Toggle("Enable Claude auto-memory", isOn: Binding(get: { app.claudeAutoMemory }, set: { app.setClaudeAutoMemory($0) })).toggleStyle(.checkbox)
                    FlowButtons { [
                        AnyView(Button("User CLAUDE.md") { app.openManagedText(Paths.home + "/.claude/CLAUDE.md", initial: "# Claude user instructions\n") }.ghostButton()),
                        AnyView(Button("Project CLAUDE.md") { app.openManagedText(app.folder + "/CLAUDE.md", initial: "# Project context for Claude\n") }.ghostButton()),
                        AnyView(Button("Auto-memory folder") { app.openManagedFolder(Paths.home + "/.claude/projects") }.ghostButton()),
                        AnyView(Button("Claude settings") { app.openManagedText(Paths.claudeSettings, initial: "{}\n") }.ghostButton())
                    ] }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    SectionCap(text: "Codex memory & context")
                    Text("Memories are experimental and off by default. Blank context values keep model defaults.").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    Toggle("Enable Codex memories", isOn: Binding(get: { app.codexMemories }, set: { app.setCodexMemories($0) })).toggleStyle(.checkbox)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) { FieldLabel(text: "Context window tokens"); DarkField(placeholder: "model default", text: $app.codexContextWindow, mono: true) }
                        VStack(alignment: .leading, spacing: 6) { FieldLabel(text: "Auto-compact threshold"); DarkField(placeholder: "model default", text: $app.codexCompactLimit, mono: true) }
                        Button("Apply") { app.applyCodexContext() }.accentButton().padding(.top, 20)
                    }
                    FlowButtons { [
                        AnyView(Button("User AGENTS.md") { app.openManagedText(Paths.codexAgents, initial: "# Codex user instructions\n") }.ghostButton()),
                        AnyView(Button("Project AGENTS.md") { app.openManagedText(app.folder + "/AGENTS.md", initial: "# Project instructions\n") }.ghostButton()),
                        AnyView(Button("Codex config") { app.openManagedText(Paths.codexConfig) }.ghostButton())
                    ] }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    SectionCap(text: "Hermes memory & context")
                    Text("Built-in MEMORY.md and USER.md stay active; one external memory provider can be connected.").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    Toggle("Enable automatic context compression", isOn: Binding(get: { app.hermesCompression }, set: { app.setHermesCompression($0) })).toggleStyle(.checkbox)
                    HStack(spacing: 10) {
                        FieldLabel(text: "Compression threshold")
                        DarkField(placeholder: "50", text: $app.hermesCompressionThreshold, mono: true).frame(width: 85)
                        Text("%").foregroundStyle(Theme.textDim)
                        Button("Apply") { app.applyHermesThreshold() }.accentButton()
                    }
                    FlowButtons { [
                        AnyView(Button("Memory setup") { app.runHermesMemory("memory setup", task: "Configure Hermes memory") }.ghostButton()),
                        AnyView(Button("Memory status") { app.runHermesMemory("memory status", task: "Hermes memory status") }.ghostButton()),
                        AnyView(Button("Built-in only") { app.runHermesMemory("memory off", task: "Use built-in Hermes memory") }.ghostButton()),
                        AnyView(Button("MEMORY.md") { app.openManagedText(Paths.hermesProfileHome(app.hermesProfile) + "/memories/MEMORY.md", initial: "# Long-term memory\n") }.ghostButton()),
                        AnyView(Button("USER.md") { app.openManagedText(Paths.hermesProfileHome(app.hermesProfile) + "/memories/USER.md", initial: "# User preferences\n") }.ghostButton()),
                        AnyView(Button("Project .hermes.md") { app.openManagedText(app.folder + "/.hermes.md", initial: "# Project context for Hermes\n") }.ghostButton())
                    ] }
                }
            }
            Button("Refresh memory & context state") { app.refreshAgentControls() }.ghostButton()
        }
    }
}

struct CompressionSettingsPane: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCap(text: "Token compression")
                    ToggleRow(title: "RTK — filter shell/test/build output", status: app.rtkInstalled ? "Installed" : "Not installed",
                              statusColor: app.rtkInstalled ? Theme.green : Theme.yellow, isOn: $app.rtk) { on in if on != app.rtkInstalled { app.setRtk(on) } }
                    Divider().overlay(Color.white.opacity(0.05))
                    ToggleRow(title: "Caveman — compress agent replies", status: app.cavemanInstalled ? "Installed" : "Not installed",
                              statusColor: app.cavemanInstalled ? Theme.green : Theme.yellow, isOn: $app.caveman) { on in if on != app.cavemanInstalled { app.setCaveman(on) } }
                    Divider().overlay(Color.white.opacity(0.05))
                    ToggleRow(title: "Headroom — compress tool output per launch", status: app.proxyRunning ? "Proxy running" : "Starts on launch",
                              statusColor: app.proxyRunning ? Theme.green : Theme.yellow, isOn: $app.headroom) { _ in app.saveSettings() }
                    Text(app.compressionAdvisory.0).font(.system(size: 11)).foregroundStyle(app.compressionAdvisory.1)
                }
            }
            CredentialsSection()
        }
    }
}

struct SystemSettingsPane: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    SectionCap(text: "Backup & sync")
                    Text("Portable JSON excludes credentials and API keys.").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    FlowButtons { [
                        AnyView(Button("Fetch latest from GitHub") { app.fetchLatestFromGit() }.blueButton()),
                        AnyView(Button("Export settings") { app.exportSettingsJson() }.ghostButton()),
                        AnyView(Button("Import settings") { app.importSettingsJson() }.ghostButton())
                    ] }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCap(text: "Install & updates")
                    Text(app.statusLine.isEmpty ? "Detecting…" : app.statusLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textDim)
                    FlowButtons { [
                        AnyView(Button(app.allCoreInstalled ? "Update core packages" : "Install everything") { app.allCoreInstalled ? app.updateCore() : app.installEverything() }.accentButton()),
                        AnyView(Button("Check CLI updates") { app.checkCLIUpdates() }.ghostButton()),
                        AnyView(Button("Install / repair Hermes") { app.installHermes() }.ghostButton()),
                        AnyView(Button("Re-check") { app.refreshAll() }.ghostButton()),
                        AnyView(Button("Open Ollama tab") { app.pendingTab = 5 }.ghostButton())
                    ] }
                    LogPane(text: app.setupLog).frame(minHeight: 220)
                }
            }
        }
    }
}

struct MCPView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("MCP integrations").font(.system(size: 21, weight: .bold)).foregroundStyle(.white)
                Text("Every server visible to Claude, Codex, or the selected Hermes profile — reported by each native CLI.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 8) {
                Button(app.mcpBusy ? "Checking…" : "Refresh all") { app.refreshMCP() }.accentButton().disabled(app.mcpBusy)
                Button("Claude MCP help") { app.runInWorkspace("claude mcp --help", cwd: app.folder, note: "Claude MCP commands", agentLabel: "Claude", modelLabel: "MCP", taskLabel: "Claude MCP help") }.ghostButton()
                Button("Codex config") { app.openManagedText(Paths.codexConfig) }.ghostButton()
                Button("Hermes MCP manager") { app.runHermesMemory("mcp", task: "Hermes MCP manager") }.ghostButton()
                Text(app.mcpStatus).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MCPAgentCard(name: "Claude", subtitle: "User, project, local, plugin, and claude.ai connectors", text: app.mcpClaude)
                    MCPAgentCard(name: "Codex", subtitle: "Servers merged from the active Codex config", text: app.mcpCodex)
                    MCPAgentCard(name: "Hermes", subtitle: "Servers for profile \(app.hermesProfile.isEmpty ? "default" : app.hermesProfile)", text: app.mcpHermes)
                }.frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(22)
        .onAppear { app.refreshMCP() }
    }
}

struct MCPAgentCard: View {
    let name: String
    let subtitle: String
    let text: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textDim)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 105, maxHeight: 150)
                .padding(10).background(Color.black.opacity(0.28)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
