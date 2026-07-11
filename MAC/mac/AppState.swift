import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

struct Skill: Identifiable {
    var id: String { path }
    let name: String
    let desc: String
    let path: String
    let enabled: Bool
}

struct GlossaryEntry: Identifiable {
    let id = UUID()
    let category: String
    let term: String
    let desc: String
}

let ProxyPort = 8787

final class AppState: ObservableObject {
    // Launch config
    @Published var agent: String = "Claude"
    @Published var folder: String = Paths.home
    @Published var model: String = "Default"
    @Published private var claudeLaunchModel = "Default"
    @Published private var codexLaunchModel = "Default"
    @Published private var hermesLaunchModel = "Default"
    @Published var hermesProvider = "auto"
    @Published var hermesProfile = ""
    @Published var permission: String = "Bypass – skip all prompts"
    @Published var headroom = false
    @Published var rtk = false
    @Published var caveman = false
    @Published var continueLast = false
    @Published var extraArgs = ""

    // Live status
    @Published var proxyRunning = false
    @Published var rtkInstalled = false
    @Published var cavemanInstalled = false
    @Published var videoInstalled = false
    @Published var agentSkillsInstalled = false
    @Published var recents: [String] = []

    // Embedded in-app terminals (the Workspace tab).
    let terminals = TerminalManager()

    // Optional local Ollama server. Constructing this never starts a process.
    let ollama = OllamaService()

    // When set, ContentView switches to this tab (0 = Workspace) so spawned sessions are visible.
    @Published var pendingTab: Int? = nil

    // Skills
    @Published var skills: [Skill] = []
    @Published var skillsSummary = ""
    @Published var hermesSkills: [Skill] = []
    @Published var hermesSkillsSummary = ""

    // Native agent memory/context and MCP inventories.
    @Published var claudeAutoMemory = true
    @Published var codexMemories = false
    @Published var codexContextWindow = ""
    @Published var codexCompactLimit = ""
    @Published var hermesCompression = true
    @Published var hermesCompressionThreshold = "50"
    @Published var mcpClaude = "Not checked yet."
    @Published var mcpCodex = "Not checked yet."
    @Published var mcpHermes = "Not checked yet."
    @Published var mcpStatus = ""
    @Published var mcpBusy = false

    // Shared access tokens & API keys (Settings → Access & API keys).
    // Persisted to ~/.claude-manager/credentials.env, injected into every
    // terminal this app launches — reusable by any project.
    @Published var creds: [String: String] = [:]

    // Setup / detection
    @Published var statusLine = ""
    @Published var setupLog = "Ready. Use the buttons above to install or update the Claude toolchain.\n"
    @Published var cliUpdateStatus = "CLI updates not checked yet."
    @Published var setupBusy = false

    // Ollama models (Settings → Ollama models; runtime is built into Hydra)
    @Published var ollamaTag = ""
    @Published var ollamaCtxText = String(OllamaService.contextLength())
    @Published var ollamaMenuTags: [String] = []
    @Published var ollamaModelsStatus = ""

    // Glossary
    let glossary: [GlossaryEntry] = Glossary.all

    let claudeModelOptions = ModelCatalog.claude
    let chatGPTModelOptions = ModelCatalog.codex
    let agentOptions = ["Claude", "Codex", "Hermes"]
    let hermesProviderOptions = HermesIntegration.providerOptions
    let permissionOptions = ["Bypass – skip all prompts", "Plan mode (read-only)",
                             "Accept edits automatically", "Ask for each action"]

    func launchModelOptions(for agent: String) -> [String] {
        if agent == "Hermes" { return HermesIntegration.modelSuggestions(forProviderID: hermesProvider) }
        return (agent == "Codex" || agent == "ChatGPT") ? chatGPTModelOptions : claudeModelOptions
    }

    func setAgent(_ next: String) {
        guard agentOptions.contains(next) else { return }
        rememberVisibleModel()
        agent = next
        model = storedModel(for: next)
        sanitizeLaunchModel()
        saveSettings()
    }

    func setLaunchModel(_ next: String) {
        model = next
        rememberVisibleModel()
        saveSettings()
    }

    func defaultModel(for agent: String) -> String {
        storedModel(for: agent)
    }

    func setDefaultModel(_ next: String, for agent: String) {
        let normalized = normalizedModel(next, for: agent)
        if agent == "Hermes" {
            hermesLaunchModel = normalized
        } else if agent == "Codex" || agent == "ChatGPT" {
            codexLaunchModel = normalized
        } else {
            claudeLaunchModel = normalized
        }
        if self.agent == agent || (self.agent == "Codex" && agent == "ChatGPT") {
            model = normalized
        }
        saveSettings()
    }

    func setHermesProviderLabel(_ label: String) {
        hermesProvider = HermesIntegration.providerID(forLabel: label)
        if hermesProvider == "custom" {
            let choices = HermesIntegration.modelSuggestions(forProviderID: hermesProvider)
            if !choices.contains(hermesLaunchModel) {
                hermesLaunchModel = choices.first ?? "Default"
                if agent == "Hermes" { model = hermesLaunchModel }
            }
        }
        saveSettings()
    }

    func cliModelName(_ selection: String) -> String {
        let key = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch key {
        case "fable", "claudefable5": return "claude-fable-5"
        case "opus", "claudeopus48": return "claude-opus-4-8"
        case "sonnet", "claudesonnet5", "claudesonnet46": return "claude-sonnet-5"
        case "haiku", "claudehaiku45", "claudehaiku4520251001": return "claude-haiku-4-5"
        case "chatgpt5.6", "gpt5.6": return "gpt-5.6-sol"
        case "chatgpt5.5": return "gpt-5.5"
        default: return selection
        }
    }

    private func normalizedModel(_ selection: String, for agent: String) -> String {
        if agent == "Hermes" { return HermesIntegration.normalizedModel(selection) }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("Default") == .orderedSame { return "Default" }
        let normalized = cliModelName(trimmed)
        return launchModelOptions(for: agent).contains(normalized) ? normalized : "Default"
    }

    private func rememberVisibleModel() {
        let normalized = normalizedModel(model, for: agent)
        if agent == "Hermes" {
            hermesLaunchModel = normalized
        } else if agent == "Codex" || agent == "ChatGPT" {
            codexLaunchModel = normalized
        } else {
            claudeLaunchModel = normalized
        }
    }

    private func storedModel(for agent: String) -> String {
        if agent == "Hermes" { return normalizedModel(hermesLaunchModel, for: agent) }
        return normalizedModel((agent == "Codex" || agent == "ChatGPT") ? codexLaunchModel : claudeLaunchModel, for: agent)
    }

    private var eventTimer: Timer?
    private var statusTimer: Timer?

    init() {
        Paths.ensureDirs()
        terminals.app = self
        loadSettings()
        sanitizeLaunchModel()
        creds = CredStore.load()
        refreshRecents()
        refreshAll()
        loadSkills()
        clearOldEvents()
        startTimers()
        autoInstallBundledSkillsIfEmpty()   // seed bundled skills once (marker-guarded)
        provisionNativeToolchain()          // make claude/rtk/caveman native — no manual download
        ensureDefaultCompressionFirstRun()  // first run only: quietly enable RTK + Caveman (parity with Windows)
    }

    // ---- persistence (same key=value format as the Windows settings.txt) ----
    func loadSettings() {
        guard let text = FS.read(Paths.settingsFile) else { return }
        var legacyModel: String?
        var foundClaudeModel = false
        var foundCodexModel = false
        var foundHermesModel = false
        for line in text.split(separator: "\n") {
            let l = String(line)
            if l.hasPrefix("agent=") {
                let v = String(l.dropFirst(6))
                if agentOptions.contains(v) { agent = v }
            }
            else if l.hasPrefix("model=") {
                let v = String(l.dropFirst(6))
                if !v.isEmpty { legacyModel = v; model = v }
            }
            else if l.hasPrefix("claudeModel=") {
                let v = String(l.dropFirst(12))
                if !v.isEmpty { claudeLaunchModel = v; foundClaudeModel = true }
            }
            else if l.hasPrefix("codexModel=") {
                let v = String(l.dropFirst(11))
                if !v.isEmpty { codexLaunchModel = v; foundCodexModel = true }
            }
            else if l.hasPrefix("hermesModel=") {
                let v = String(l.dropFirst(12))
                if !v.isEmpty { hermesLaunchModel = v; foundHermesModel = true }
            }
            else if l.hasPrefix("hermesProvider=") {
                hermesProvider = HermesIntegration.normalizedProviderID(String(l.dropFirst(15)))
            }
            else if l.hasPrefix("hermesProfile=") {
                let v = String(l.dropFirst(14)).trimmingCharacters(in: .whitespacesAndNewlines)
                if HermesIntegration.validProfile(v) { hermesProfile = v }
            }
            else if l.hasPrefix("headroom=") { headroom = l.dropFirst(9).trimmingCharacters(in: .whitespaces) == "1" }
            else if l.hasPrefix("cont=") { continueLast = l.dropFirst(5).trimmingCharacters(in: .whitespaces) == "1" }
            else if l.hasPrefix("extra=") { extraArgs = String(l.dropFirst(6)) }
            else if l.hasPrefix("perm=") {
                let v = String(l.dropFirst(5))
                if permissionOptions.contains(v) { permission = v }
            }
        }
        if let legacyModel {
            if agent == "Hermes", !foundHermesModel {
                hermesLaunchModel = legacyModel
            } else if (agent == "Codex" || agent == "ChatGPT"), !foundCodexModel {
                codexLaunchModel = legacyModel
            } else if !foundClaudeModel {
                claudeLaunchModel = legacyModel
            }
        }
        model = storedModel(for: agent)
        sanitizeLaunchModel()
    }

    func sanitizeLaunchModel() {
        model = normalizedModel(model, for: agent)
        rememberVisibleModel()
    }

    func saveSettings() {
        rememberVisibleModel()
        let lines = [
            "agent=" + agent,
            "model=" + model.trimmingCharacters(in: .whitespaces),
            "claudeModel=" + claudeLaunchModel,
            "codexModel=" + codexLaunchModel,
            "hermesModel=" + hermesLaunchModel,
            "hermesProvider=" + HermesIntegration.normalizedProviderID(hermesProvider),
            "hermesProfile=" + (HermesIntegration.validProfile(hermesProfile) ? hermesProfile : ""),
            "headroom=" + (headroom ? "1" : "0"),
            "perm=" + permission,
            "cont=" + (continueLast ? "1" : "0"),
            "extra=" + extraArgs.trimmingCharacters(in: .whitespaces)
        ]
        FS.write(Paths.settingsFile, lines.joined(separator: "\n"))
    }

    // ---- backup & sync ----
    // Portable settings snapshot. NEVER includes credentials, API keys or tokens —
    // by design (CredStore is deliberately not read here), so exports and git pushes
    // stay safe to share. Lives in this file for access to the private model fields.
    func settingsAsJsonData() -> Data? {
        rememberVisibleModel()
        let rec = Self.recommendedOllamaModels().map { $0.group.isEmpty ? $0.tag : "\($0.group)|\($0.tag)" }
        let dict: [String: Any] = [
            "agent": agent,
            "claudeModel": claudeLaunchModel,
            "codexModel": codexLaunchModel,
            "hermesModel": hermesLaunchModel,
            "hermesProvider": HermesIntegration.normalizedProviderID(hermesProvider),
            "hermesProfile": HermesIntegration.validProfile(hermesProfile) ? hermesProfile : "",
            "headroom": headroom,
            "permission": permission,
            "continueLast": continueLast,
            "extraFlags": extraArgs.trimmingCharacters(in: .whitespaces),
            "ollamaContext": OllamaService.contextLength(),
            "ollamaRecommended": rec
        ]
        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    func exportSettingsJson() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hydra-settings.json"
        panel.title = "Export Hydra settings (no credentials included)"
        guard panel.runModal() == .OK, let url = panel.url, let data = settingsAsJsonData() else { return }
        do {
            try data.write(to: url)
            log("OK Settings exported to \(url.path) (credentials are never included).")
        } catch { log("ERR export: \(error.localizedDescription)") }
    }

    func importSettingsJson() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.title = "Import Hydra settings"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("ERR import: could not read that file as JSON."); return
        }
        if let v = dict["agent"] as? String, agentOptions.contains(v) { agent = v }
        if let v = dict["claudeModel"] as? String, !v.isEmpty { claudeLaunchModel = v }
        if let v = dict["codexModel"] as? String, !v.isEmpty { codexLaunchModel = v }
        if let v = dict["hermesModel"] as? String, !v.isEmpty { hermesLaunchModel = HermesIntegration.normalizedModel(v) }
        if let v = dict["hermesProvider"] as? String { hermesProvider = HermesIntegration.normalizedProviderID(v) }
        if let v = dict["hermesProfile"] as? String, HermesIntegration.validProfile(v) { hermesProfile = v }
        if let v = dict["headroom"] as? Bool { headroom = v }
        if let v = dict["permission"] as? String, permissionOptions.contains(v) { permission = v }
        if let v = dict["continueLast"] as? Bool { continueLast = v }
        if let v = dict["extraFlags"] as? String { extraArgs = v }
        if let v = dict["ollamaContext"] as? Int, v > 0 {
            OllamaService.saveContextLength(v)
            ollamaCtxText = String(v)
        }
        if let rec = dict["ollamaRecommended"] as? [String], !rec.isEmpty {
            try? FileManager.default.createDirectory(atPath: Paths.ollamaDir, withIntermediateDirectories: true)
            FS.write(Paths.ollamaRecFile, rec.joined(separator: "\n") + "\n")
        }
        model = storedModel(for: agent)
        saveSettings()
        refreshOllamaModels()
        log("OK Settings imported from \(url.path).")
    }

    // ---- shared credentials ----
    func setCred(_ key: String, _ value: String) {
        if value.isEmpty { creds.removeValue(forKey: key) } else { creds[key] = value }
        CredStore.save(creds)
    }

    /// Export every stored credential into a child-process environment.
    /// GH_TOKEN is aliased from GITHUB_TOKEN so the gh CLI picks it up too.
    func applyCreds(to env: inout [String: String]) {
        for (k, v) in creds where !v.isEmpty { env[k] = v }
        if let gh = creds["GITHUB_TOKEN"], !gh.isEmpty, env["GH_TOKEN"] == nil {
            env["GH_TOKEN"] = gh
        }
    }

    func refreshRecents() {
        guard let text = FS.read(Paths.recentFile) else { recents = []; return }
        var seen = Set<String>()
        // NOTE: deliberately NO FS.isDir() here — stat-ing recent paths in Desktop/Documents/
        // Downloads at startup fires macOS privacy (TCC) prompts. Folders are validated at
        // launch time instead, where a clear alert is shown if one has vanished.
        recents = text.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func saveRecent(_ path: String) {
        var list = [path]
        for r in recents where r != path && !list.contains(r) { list.append(r) }
        if list.count > 15 { list = Array(list.prefix(15)) }
        FS.write(Paths.recentFile, list.joined(separator: "\n"))
        recents = list
    }

    // ---- detection ----
    func refreshAll() {
        rtkInstalled = Self.isRtkInstalled()
        cavemanInstalled = Self.isCavemanInstalled()
        videoInstalled = Self.isVideoInstalled()
        agentSkillsInstalled = Self.isAgentSkillsInstalled()
        proxyRunning = Self.portOpen(ProxyPort)
        ollama.refresh()
        rtk = rtkInstalled
        caveman = cavemanInstalled
        updateStatusLine()
        refreshOllamaModels()
    }

    static func isRtkInstalled() -> Bool {
        let claude = FS.read(Paths.claudeSettings)?.range(of: "rtk hook", options: .caseInsensitive) != nil
        let codex = FS.exists(Paths.codexRtk)
            && (FS.read(Paths.codexAgents)?.range(of: "RTK.md", options: .caseInsensitive) != nil)
        return claude || codex
    }
    static func isCavemanInstalled() -> Bool {
        // Plugin install (installed_plugins.json) …
        if let s = FS.read(Paths.pluginsFile), s.range(of: "caveman", options: .caseInsensitive) != nil { return true }
        // … or the standalone-hooks fallback the installer uses when the plugin path isn't
        // available (e.g. claude not yet on PATH). Those wire ~/.claude/hooks/caveman-*.js.
        if FS.exists(Paths.home + "/.claude/hooks/caveman-config.js") { return true }
        if let s = FS.read(Paths.claudeSettings), s.range(of: "caveman", options: .caseInsensitive) != nil { return true }
        if let s = FS.read(Paths.codexAgents), s.range(of: "claude-manager-caveman-codex", options: .caseInsensitive) != nil { return true }
        return false
    }
    static func isVideoInstalled() -> Bool {
        if FS.exists(Paths.skillsDir + "/watch/SKILL.md") { return true }
        if FS.exists(Paths.codexSkillsDir + "/watch/SKILL.md") { return true }
        if let s = FS.read(Paths.pluginsFile), s.range(of: "watch@claude-video", options: .caseInsensitive) != nil { return true }
        if FS.exists(Paths.home + "/.claude/plugins/marketplaces/claude-video/.claude-plugin/plugin.json") { return true }
        return false
    }
    static func isAgentSkillsInstalled() -> Bool {
        FS.exists(Paths.skillsDir + "/using-agent-skills/SKILL.md")
        && FS.exists(Paths.codexSkillsDir + "/using-agent-skills/SKILL.md")
    }
    static func portOpen(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    /// True once the core toolchain is fully present — used to hide "Install everything"
    /// and let the Setup tab focus on keeping things up to date. Headroom is optional.
    var ollamaBuiltIn: Bool { FileManager.default.isExecutableFile(atPath: Paths.ollamaExe) }
    var hermesPlatformSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    var allCoreInstalled: Bool {
        let sh = Shell.shared
        let hermesReady = !hermesPlatformSupported || sh.onPath("hermes")
        return sh.onPath("claude") && sh.onPath("codex") && hermesReady && sh.onPath("node") && rtkInstalled && cavemanInstalled && videoInstalled && agentSkillsInstalled && ollamaBuiltIn
    }

    func updateStatusLine() {
        let sh = Shell.shared
        func mark(_ ok: Bool) -> String { ok ? "OK" : "—" }
        let node = sh.onPath("node")
        let hermesMark = hermesPlatformSupported ? mark(sh.onPath("hermes")) : "N/A (Intel)"
        statusLine = "Claude \(mark(sh.onPath("claude")))   Codex \(mark(sh.onPath("codex")))   Hermes \(hermesMark)   Node \(mark(node))   RTK \(mark(sh.onPath("rtk") && rtkInstalled))   Caveman \(mark(cavemanInstalled))   Video \(mark(videoInstalled))   AgentSkills \(mark(agentSkillsInstalled))   Ollama \(mark(ollamaBuiltIn))   Headroom \(mark(sh.onPath("headroom")))   Skills \(countSkills())"
    }

    func countSkills() -> Int {
        FS.dirs(Paths.skillsDir).filter { FS.exists($0 + "/SKILL.md") }.count
    }

    // ---- first-run default compression (RTK input + Caveman output) ----
    private func ensureDefaultCompressionFirstRun() {
        let firstRun = !FS.exists(Paths.settingsFile)
        guard firstRun else { return }
        saveSettings() // stamp the file so this only runs once
        DispatchQueue.global(qos: .utility).async {
            let sh = Shell.shared
            if !Self.isRtkInstalled(), sh.onPath("rtk") {
                sh.run("rtk", ["init", "-g", "--auto-patch"], timeout: 30)
            }
            if !Self.isCavemanInstalled(), sh.onPath("npx") {
                sh.bash("npx -y github:JuliusBrussee/caveman --only claude --only codex", timeout: 120)
            }
            DispatchQueue.main.async { self.refreshAll() }
        }
    }

    // ---- skills ----
    func loadSkills() {
        var list: [Skill] = []
        for (root, enabled) in [(Paths.skillsDir, true), (Paths.disabledDir, false)] {
            for dir in FS.dirs(root) {
                let md = dir + "/SKILL.md"
                guard FS.exists(md) else { continue }
                let meta = Self.readMeta(md)
                list.append(Skill(name: FS.base(dir), desc: meta.desc, path: dir, enabled: enabled))
            }
        }
        skills = list.sorted { ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased()) }
        let en = list.filter { $0.enabled }.count
        let dis = list.count - en
        skillsSummary = "\(en) enabled" + (dis > 0 ? "  •  \(dis) disabled" : "")

        let hermesRoot = Paths.hermesProfileHome(hermesProfile) + "/skills"
        hermesSkills = FS.dirs(hermesRoot).compactMap { dir in
            let md = dir + "/SKILL.md"
            guard FS.exists(md) else { return nil }
            let meta = Self.readMeta(md)
            return Skill(name: FS.base(dir), desc: meta.desc, path: dir, enabled: true)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        hermesSkillsSummary = "\(hermesSkills.count) installed" + (hermesProfile.isEmpty ? "" : " in \(hermesProfile)")
    }

    static func readMeta(_ path: String) -> (name: String, desc: String) {
        guard let text = FS.read(path) else { return ("", "") }
        var name = "", desc = "", dashes = 0, inFm = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                dashes += 1
                if dashes == 1 { inFm = true; continue }
                if dashes >= 2 { break }
            }
            if inFm {
                if name.isEmpty && line.hasPrefix("name:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                else if desc.isEmpty && line.hasPrefix("description:") { desc = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces) }
            }
        }
        return (name, desc)
    }

    // ---- live session status via hook event files ----
    private func startTimers() {
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.drainEvents() }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.proxyRunning = Self.portOpen(ProxyPort)
            self?.ollama.refresh()
        }
    }

    private func clearOldEvents() {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: Paths.eventsDir)) ?? [] {
            try? FileManager.default.removeItem(atPath: Paths.eventsDir + "/" + f)
        }
    }

    private func drainEvents() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.eventsDir)) ?? []
        guard !files.isEmpty else {
            // Prune sessions whose Terminal tab was closed long ago (>2h) if they went silent.
            return
        }
        for f in files where f.hasSuffix(".evt") {
            // format: <id>__<ev>__<ticks>.evt
            let parts = f.replacingOccurrences(of: ".evt", with: "").components(separatedBy: "__")
            if parts.count >= 2 {
                let path = Paths.eventsDir + "/" + f
                let payload = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(SessionEventPayload.decode)
                terminals.applyEvent(id: parts[0], event: parts[1], payload: payload)
            }
            try? FileManager.default.removeItem(atPath: Paths.eventsDir + "/" + f)
        }
    }

    // ---- compression advisory (never let the tools step on each other) ----
    var compressionAdvisory: (String, Color) {
        if headroom && rtk {
            return ("⚠ Headroom + RTK both compress shell output — redundant. Pick one input tool (RTK for shell noise, Headroom for MCP/RAG/files).", Theme.yellow)
        } else if !headroom && !rtk && !caveman {
            return ("No compression active. Tip: RTK (input) + Caveman (output) is the clean, non-overlapping combo.", Theme.textDim)
        } else {
            let both = (rtk || headroom) && caveman
            return ("Clean combo — these streams don't overlap." + (both ? "  Input + output both covered." : ""), Theme.green)
        }
    }
}
