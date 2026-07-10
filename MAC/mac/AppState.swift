import SwiftUI
import Combine

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
    @Published var recents: [String] = []

    // Embedded in-app terminals (the Workspace tab).
    let terminals = TerminalManager()

    // When set, ContentView switches to this tab (0 = Workspace) so spawned sessions are visible.
    @Published var pendingTab: Int? = nil

    // Skills
    @Published var skills: [Skill] = []
    @Published var skillsSummary = ""

    // Shared access tokens & API keys (Settings → Access & API keys).
    // Persisted to ~/.claude-manager/credentials.env, injected into every
    // terminal this app launches — reusable by any project.
    @Published var creds: [String: String] = [:]

    // Setup / detection
    @Published var statusLine = ""
    @Published var setupLog = "Ready. Use the buttons above to install or update the Claude toolchain.\n"
    @Published var setupBusy = false

    // Glossary
    let glossary: [GlossaryEntry] = Glossary.all

    let claudeModelOptions = ["Default", "opus", "sonnet", "haiku", "fable", "claude-fable-5",
                              "claude-opus-4-8", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5"]
    let chatGPTModelOptions = ["Default", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                               "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark"]
    var modelOptions: [String] { claudeModelOptions }
    let agentOptions = ["Claude", "Codex"]
    let permissionOptions = ["Bypass – skip all prompts", "Plan mode (read-only)",
                             "Accept edits automatically", "Ask for each action"]

    func launchModelOptions(for agent: String) -> [String] {
        (agent == "Codex" || agent == "ChatGPT") ? chatGPTModelOptions : claudeModelOptions
    }

    func cliModelName(_ selection: String) -> String {
        let key = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch key {
        case "chatgpt5.6", "gpt5.6": return "gpt-5.6-sol"
        case "chatgpt5.5": return "gpt-5.5"
        default: return selection
        }
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
        for line in text.split(separator: "\n") {
            let l = String(line)
            if l.hasPrefix("agent=") {
                let v = String(l.dropFirst(6))
                if agentOptions.contains(v) { agent = v }
            }
            else if l.hasPrefix("model=") { let v = String(l.dropFirst(6)); if !v.isEmpty { model = v } }
            else if l.hasPrefix("headroom=") { headroom = l.dropFirst(9).trimmingCharacters(in: .whitespaces) == "1" }
            else if l.hasPrefix("cont=") { continueLast = l.dropFirst(5).trimmingCharacters(in: .whitespaces) == "1" }
            else if l.hasPrefix("extra=") { extraArgs = String(l.dropFirst(6)) }
            else if l.hasPrefix("perm=") {
                let v = String(l.dropFirst(5))
                if permissionOptions.contains(v) { permission = v }
            }
        }
        sanitizeLaunchModel()
    }

    func sanitizeLaunchModel() {
        if agent == "Codex" || agent == "ChatGPT" {
            let normalized = cliModelName(model)
            if launchModelOptions(for: agent).contains(normalized) { model = normalized }
        }
        if !launchModelOptions(for: agent).contains(model) { model = "Default" }
    }

    func saveSettings() {
        let lines = [
            "agent=" + agent,
            "model=" + model.trimmingCharacters(in: .whitespaces),
            "headroom=" + (headroom ? "1" : "0"),
            "perm=" + permission,
            "cont=" + (continueLast ? "1" : "0"),
            "extra=" + extraArgs.trimmingCharacters(in: .whitespaces)
        ]
        FS.write(Paths.settingsFile, lines.joined(separator: "\n"))
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
        proxyRunning = Self.portOpen(ProxyPort)
        rtk = rtkInstalled
        caveman = cavemanInstalled
        updateStatusLine()
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
    var allCoreInstalled: Bool {
        let sh = Shell.shared
        return sh.onPath("claude") && sh.onPath("codex") && sh.onPath("node") && rtkInstalled && cavemanInstalled
    }

    func updateStatusLine() {
        let sh = Shell.shared
        func mark(_ ok: Bool) -> String { ok ? "OK" : "—" }
        let node = sh.onPath("node")
        statusLine = "Claude \(mark(sh.onPath("claude")))   Codex \(mark(sh.onPath("codex")))   Node \(mark(node))   RTK \(mark(sh.onPath("rtk") && rtkInstalled))   Caveman \(mark(cavemanInstalled))   Headroom \(mark(sh.onPath("headroom")))   Skills \(countSkills())"
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
                sh.bash("npx -y github:JuliusBrussee/caveman --only claude", timeout: 120)
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
                terminals.setStatus(parts[0], parts[1])
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
