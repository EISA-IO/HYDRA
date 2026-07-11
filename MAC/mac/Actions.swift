import SwiftUI
import AppKit

// ============================================================================
// Launch — the heart of the app: start a Claude session in a Terminal tab with
// the chosen model, permission mode, compression, continue flag and extra args,
// wiring per-session hooks so we can show live status.
// ============================================================================
extension AppState {
    func permissionFlag() -> String {
        if permission.hasPrefix("Bypass") { return " --dangerously-skip-permissions" }
        if permission.hasPrefix("Plan") { return " --permission-mode plan" }
        if permission.hasPrefix("Accept") { return " --permission-mode acceptEdits" }
        return ""
    }

    func codexPermissionFlags() -> String {
        " --dangerously-bypass-approvals-and-sandbox"
    }

    var launchButtonLabel: String {
        var tail = ""
        if agent != "Hermes" {
            if headroom { tail += " +Headroom" }
            if rtk { tail += " +RTK" }
            if caveman { tail += " +Caveman" }
        }
        let m = model.trimmingCharacters(in: .whitespaces).isEmpty ? "Default" : model
        return "Launch \(agent)  (\(m))\(tail)"
    }

    /// Write a per-session settings.json whose hooks touch event files so the app
    /// can reflect working/idle/waiting status for this Terminal tab.
    private func writeSessionSettings(id: String, rtk: Bool, caveman: Bool) -> String {
        var hooks = SessionHookConfig.claudeHooks(id: id, eventsDirectory: Paths.eventsDir)
        // RTK (input compression) is a global PreToolUse hook. Claude MERGES hooks across
        // settings sources and DEDUPES identical command strings, so re-declaring it in this
        // per-session file guarantees it runs in this embedded terminal — even if the user's
        // global hook were ever missing/overridden — without ever double-compressing. It also
        // makes the per-terminal RTK toggle actually meaningful.
        if rtk {
            hooks["PreToolUse"] = [[
                "matcher": "Bash|PowerShell",
                "hooks": [["type": "command", "command": "rtk hook claude"]]
            ]]
        }
        var root: [String: Any] = ["hooks": hooks]
        var marketplaces: [String: Any] = [:]
        var enabledPlugins: [String: Any] = [:]
        // Plugin enabled state is not guaranteed to merge from user settings when we pass
        // --settings, so declare required plugins per-session.
        if caveman {
            marketplaces["caveman"] = ["source": ["source": "github", "repo": "JuliusBrussee/caveman"]]
            enabledPlugins["caveman@caveman"] = true
        }
        if Self.isAgentSkillsInstalled() {
            marketplaces["addy-agent-skills"] = ["source": ["source": "github", "repo": "addyosmani/agent-skills"]]
            enabledPlugins["agent-skills@addy-agent-skills"] = true
        }
        if !marketplaces.isEmpty {
            root["extraKnownMarketplaces"] = marketplaces
        }
        if !enabledPlugins.isEmpty {
            root["enabledPlugins"] = enabledPlugins
        }
        let path = Paths.sessDir + "/" + id + ".settings.json"
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return path
    }

    private func writeCodexSessionProfile(id: String) -> (name: String, path: String) {
        let name = "hydra-" + id
        let path = Paths.codexDir + "/" + name + ".config.toml"
        FS.write(path, SessionHookConfig.codexProfile(id: id, eventsDirectory: Paths.eventsDir) + "\n")
        return (name, path)
    }

    private func ensureCodexCavemanInstructions() {
        try? FileManager.default.createDirectory(atPath: Paths.codexDir, withIntermediateDirectories: true)
        let existing = FS.read(Paths.codexAgents) ?? ""
        if existing.contains(CodexCaveman.startMarker),
           let sr = existing.range(of: CodexCaveman.startMarker),
           let er = existing.range(of: CodexCaveman.endMarker, range: sr.upperBound..<existing.endIndex) {
            let updated = String(existing[..<sr.lowerBound]) + CodexCaveman.block + String(existing[er.upperBound...])
            FS.write(Paths.codexAgents, updated.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        } else {
            FS.write(Paths.codexAgents, (existing.trimmingCharacters(in: .whitespacesAndNewlines) + CodexCaveman.block).trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        }
    }

    private func ensureCodexCompressionForLaunch(useRtk: Bool, useCaveman: Bool) {
        var changed = false
        if useRtk, Shell.shared.onPath("rtk") {
            _ = Shell.shared.run("rtk", ["init", "-g", "--codex"], timeout: 30)
            changed = true
        }
        if useCaveman {
            ensureCodexCavemanInstructions()
            installBundledCavemanForCodexIfPossible()
            changed = true
        }
        if changed { refreshAll() }
    }

    /// Auto-trust a folder in ~/.claude.json so the CLI never shows the trust prompt.
    private func trustFolder(_ folder: String) {
        let cfg = Paths.claudeJson
        guard let text = FS.read(cfg) else { return }
        let key = "\"" + (folder as NSString).standardizingPath + "\""
        if let ki = text.range(of: key) {
            let field = "\"hasTrustDialogAccepted\":"
            guard let fi = text.range(of: field, range: ki.upperBound..<text.endIndex) else { return }
            var ve = fi.upperBound
            while ve < text.endIndex, text[ve] != ",", text[ve] != "}" { ve = text.index(after: ve) }
            let cur = String(text[fi.upperBound..<ve]).trimmingCharacters(in: .whitespaces)
            if cur == "true" { return }
            try? (text as NSString).replacingCharacters(in: NSRange(fi.upperBound..<ve, in: text), with: "true")
                .write(toFile: cfg, atomically: true, encoding: .utf8)
        } else if let pi = text.range(of: "\"projects\":"),
                  let brace = text.range(of: "{", range: pi.upperBound..<text.endIndex) {
            let after = brace.upperBound
            var p = after
            while p < text.endIndex, text[p].isWhitespace { p = text.index(after: p) }
            let empty = p < text.endIndex && text[p] == "}"
            let entry = key + ":{\"allowedTools\":[],\"hasTrustDialogAccepted\":true,\"projectOnboardingSeenCount\":1}"
            let ins = empty ? entry : entry + ","
            let updated = String(text[text.startIndex..<after]) + ins + String(text[after...])
            try? FileManager.default.copyItem(atPath: cfg, toPath: cfg + ".cmbak")
            FS.write(cfg, updated)
        }
    }

    /// Launch a Claude session as an embedded terminal tab inside the Workspace.
    /// `modelOverride` lets a caller (e.g. the SaaS builder) pick the model for THIS session
    /// without changing the global default.
    func launch(folder rawFolder: String? = nil, startupPrompt: String? = nil, modelOverride: String? = nil, agentOverride: String? = nil) {
        let f = (rawFolder ?? folder).trimmingCharacters(in: .whitespaces)
        guard FS.isDir(f) else {
            alert("Folder not found", f); return
        }
        let selectedAgent = (agentOverride == "ChatGPT") ? "Codex" : (agentOverride ?? agent)
        if headroom && selectedAgent == "Claude" && !ensureProxy() { return }

        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())
        let selectedModel = (modelOverride ?? model).trimmingCharacters(in: .whitespaces)
        let m = selectedAgent == "Hermes" ? HermesIntegration.normalizedModel(selectedModel) : cliModelName(selectedModel)
        let extra = extraArgs.trimmingCharacters(in: .whitespaces)
        var cli: String
        var cleanupPaths: [String] = []
        let selectedHermesProvider = HermesIntegration.normalizedProviderID(hermesProvider)
        if selectedAgent == "Hermes" {
            // Ollama's default repeat_penalty (1.1) corrupts long repetitive code —
            // local sessions run a "<tag>-hydra" variant with the penalty off. When the
            // server isn't up yet, the wait-for-API path re-enters launch and derives it then.
            let hermesModel = selectedHermesProvider == "custom" && AppState.portOpen(OllamaPort)
                ? ollamaCodeSafeModel(m) : m
            guard let command = HermesIntegration.launchCommand(
                model: hermesModel, providerID: selectedHermesProvider, profile: hermesProfile,
                resume: continueLast, extra: extra, startupPrompt: startupPrompt
            ) else {
                alert("Invalid Hermes profile", "Use 1–64 lowercase letters, numbers, underscores or hyphens; the first character must be a letter or number.")
                return
            }
            if selectedHermesProvider == "custom" {
                guard AppState.portOpen(OllamaPort) || OllamaService.installedExecutable() != nil else {
                    alert("Ollama not available", "Install the built-in Ollama runtime from Settings, then launch this Hermes backend again.")
                    return
                }
                // Hermes' system prompt (29 tools + every enabled skill) overflows small
                // Ollama windows; truncation silently drops earlier instructions and the
                // model stalls, repeats lines, or mangles long files. Guarantee 32k.
                let needCtxBump = OllamaService.contextLength() < 32768
                if needCtxBump { OllamaService.saveContextLength(32768) }
                if needCtxBump, ollama.state == .runningOwned || ollama.state == .starting {
                    // Restart the owned server so the larger window applies to THIS
                    // session: stop it, wait for the port to free, then re-enter launch —
                    // the wait-for-API path below brings it back with the new context.
                    guard !hermesLocalLaunchPending else {
                        alert("Hermes is waiting for Ollama", "Hydra is still restarting the local API with a larger context window. The Hermes session will open automatically when it is ready.")
                        return
                    }
                    hermesLocalLaunchPending = true
                    ollama.stop()
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        for _ in 0..<25 where AppState.portOpen(OllamaPort) { Thread.sleep(forTimeInterval: 0.2) }
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.hermesLocalLaunchPending = false
                            self.launch(folder: f, startupPrompt: startupPrompt,
                                        modelOverride: modelOverride, agentOverride: selectedAgent)
                        }
                    }
                    return
                }
                if !AppState.portOpen(OllamaPort) {
                    guard !hermesLocalLaunchPending else {
                        alert("Hermes is waiting for Ollama", "Hydra is still starting the local API. The Hermes session will open automatically when it is ready.")
                        return
                    }
                    hermesLocalLaunchPending = true
                    ollama.start()
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        var ready = false
                        for _ in 0..<75 {
                            if AppState.portOpen(OllamaPort) { ready = true; break }
                            Thread.sleep(forTimeInterval: 0.2)
                        }
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.hermesLocalLaunchPending = false
                            self.ollama.refresh()
                            guard ready else {
                                self.alert("Hermes + Ollama", "Hydra started Ollama, but its local API did not become ready within 15 seconds. Hermes was not launched, so it will not burn through three failed API retries.")
                                return
                            }
                            self.launch(folder: f, startupPrompt: startupPrompt,
                                        modelOverride: modelOverride, agentOverride: selectedAgent)
                        }
                    }
                    return
                }
            }
            HermesIntegration.removeMirroredSkills(profile: hermesProfile)   // Hermes runs on its own skills ecosystem
            cli = command
        } else if selectedAgent == "Codex" {
            // Compression is provisioned by Settings. Keep network/plugin installation off
            // this main-thread button path so a terminal tab appears immediately.
            let profile = writeCodexSessionProfile(id: id)
            cleanupPaths.append(profile.path)
            cli = "codex --profile \(TerminalLauncher.shellQuote(profile.name)) --enable hooks --dangerously-bypass-hook-trust -C \(TerminalLauncher.shellQuote(f))"
            if !m.isEmpty && m != "Default" { cli += " --model \(TerminalLauncher.shellQuote(m))" }
            if codexEffort != "Default" { cli += " -c model_reasoning_effort=\\\"\(codexEffort.lowercased())\\\"" }
            cli += codexPermissionFlags()
            if !extra.isEmpty { cli += " " + extra }
            if continueLast {
                cli += " resume --last"
            } else if let p = startupPrompt, !p.isEmpty {
                cli += " " + TerminalLauncher.shellQuote(p)
            }
        } else {
            trustFolder(f)
            let settings = writeSessionSettings(id: id, rtk: rtk, caveman: caveman)
            cleanupPaths.append(settings)
            cli = "claude --settings \(TerminalLauncher.shellQuote(settings))"
            if !m.isEmpty && m != "Default" { cli += " --model \(m)" }
            if claudeEffort != "Default" { cli += " --effort \(claudeEffort.lowercased())" }
            cli += permissionFlag()
            if continueLast { cli += " --continue" }
            if !extra.isEmpty { cli += " " + extra }
            if let p = startupPrompt, !p.isEmpty { cli += " " + TerminalLauncher.shellQuote(p) }
        }

        // Run inside a login shell in the target folder so PATH/shims resolve; exec so the
        // CLI owns the PTY. When the agent exits, the shell ends and the tab shows "exited".
        let shellCommand = "cd \(TerminalLauncher.shellQuote(f)) && exec \(cli)"

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.shared.path
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["CODEX_HOME"] = Paths.codexDir
        if headroom && selectedAgent == "Claude" { env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(ProxyPort)" }
        applyCreds(to: &env)   // shared tokens/keys (Settings → Access & API keys)
        if selectedAgent == "Hermes" {
            for (key, value) in HermesIntegration.environmentOverrides(providerID: selectedHermesProvider) {
                env[key] = value
            }
        }
        let envArr = env.map { "\($0.key)=\($0.value)" }

        terminals.spawn(id: id, folder: f, shellCommand: shellCommand, env: envArr,
                        agent: selectedAgent,
                        model: selectedAgent == "Hermes" && m == "Default" ? "Hermes default" : sessionModelLabel(m),
                        task: taskLabel(startupPrompt: startupPrompt),
                        headroom: selectedAgent == "Claude" ? headroom : false,
                        rtk: selectedAgent == "Hermes" ? false : rtk,
                        caveman: selectedAgent == "Hermes" ? false : caveman,
                        cleanupPaths: cleanupPaths)
        saveRecent(f)
        saveSettings()
        refreshRecents()
        pendingTab = 0   // jump to the Workspace so the new session is visible
    }

    /// Run a plain shell command inside a new embedded Workspace terminal tab (NOT Claude),
    /// then drop into an interactive login shell so output stays visible and any prompts work.
    /// Used by the SaaS lifecycle (installs, logins, deploys) so everything stays in-app.
    func runInWorkspace(_ command: String, cwd: String, note: String? = nil,
                        agentLabel: String = "Shell", modelLabel: String = "Local shell",
                        taskLabel: String? = nil) {
        let f = cwd.trimmingCharacters(in: .whitespaces)
        guard FS.isDir(f) else { alert("Folder not found", f); return }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())
        let banner = note.map { "echo \(TerminalLauncher.shellQuote($0)); " } ?? ""
        let shellCommand = "cd \(TerminalLauncher.shellQuote(f)) && \(banner)\(command); echo; echo '— finished · shell stays open —'; exec $SHELL -l"
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.shared.path
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        applyCreds(to: &env)   // shared tokens/keys (Settings → Access & API keys)
        let envArr = env.map { "\($0.key)=\($0.value)" }
        terminals.spawn(id: id, folder: f, shellCommand: shellCommand, env: envArr,
                        agent: agentLabel, model: modelLabel,
                        task: taskLabel ?? shellTaskLabel(note: note, command: command),
                        headroom: false, rtk: false, caveman: false)
        saveRecent(f)
        pendingTab = 0
    }

    func launchOllamaTerminal() {
        guard let executable = OllamaService.installedExecutable() else {
            alert("Ollama", "Ollama isn't built into Hydra yet. Use Settings → \"Install everything\" (or its Ollama button) to add the built-in runtime — nothing is installed system-wide.")
            return
        }
        let running = Self.portOpen(OllamaPort)
        let command = OllamaService.terminalCommand(executable: executable, serverRunning: running)
        let cwd = FS.isDir(folder) ? folder : Paths.home
        let note = running
            ? "Ollama is already running. Showing loaded models; shell stays open for Ollama commands."
            : "Starting Ollama locally on 127.0.0.1:\(OllamaPort). Keep this terminal open to keep the server running."
        runInWorkspace(command, cwd: cwd, note: note,
                       agentLabel: "Ollama", modelLabel: "Local server",
                       taskLabel: running ? "Manage local models" : "Serve local models")
    }

    private func sessionModelLabel(_ cliModel: String) -> String {
        TerminalPresentation.modelLabel(configured: cliModel)
    }

    private func taskLabel(startupPrompt: String?) -> String {
        TerminalPresentation.taskLabel(startupPrompt: startupPrompt, resume: continueLast)
    }

    private func shellTaskLabel(note: String?, command: String) -> String {
        let raw = (note?.isEmpty == false ? note! : command)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "—", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count <= 42 { return raw.isEmpty ? "Shell command" : raw }
        let cut = raw.index(raw.startIndex, offsetBy: 41)
        return String(raw[..<cut]) + "..."
    }

    @discardableResult
    func ensureProxy() -> Bool {
        if Self.portOpen(ProxyPort) { proxyRunning = true; return true }
        guard Shell.shared.onPath("headroom") else {
            alert("Headroom not found", "Install Headroom (Setup tab), or turn off 'Route through Headroom'.")
            return false
        }
        // Start the proxy in an embedded Workspace tab — controlling Terminal.app via
        // AppleScript would fire a macOS Automation permission prompt.
        runInWorkspace("headroom proxy", cwd: Paths.home, note: "Headroom proxy — leave this tab running.")
        // Never poll from the SwiftUI action handler. Claude does not contact Headroom until
        // the first prompt, so the proxy can finish booting while both tabs remain responsive.
        return true
    }

    // ---- compression toggles ----
    func setRtk(_ install: Bool) {
        guard Shell.shared.onPath("rtk") else {
            alert("RTK not on PATH", "Install RTK from the Setup tab first, then try again.")
            rtk = rtkInstalled
            return
        }
        setupLog += (install ? "Installing" : "Removing") + " RTK hook…\n"
        DispatchQueue.global(qos: .userInitiated).async {
            let args = install ? ["init", "-g", "--auto-patch"] : ["init", "-g", "--uninstall"]
            _ = Shell.shared.run("rtk", args, timeout: 60)
            DispatchQueue.main.async {
                self.rtkInstalled = Self.isRtkInstalled()
                self.rtk = self.rtkInstalled
                self.updateStatusLine()
                self.setupLog += "RTK hook \(self.rtkInstalled ? "installed" : "removed").\n"
            }
        }
    }

    func setCaveman(_ install: Bool) {
        guard Shell.shared.onPath("npx") else {
            alert("npx not found", "Install Node.js 18+ (Setup tab), then try again.")
            caveman = cavemanInstalled
            return
        }
        setupLog += (install ? "Installing" : "Removing") + " Caveman…\n"
        DispatchQueue.global(qos: .userInitiated).async {
            let cmd = "npx -y github:JuliusBrussee/caveman --only claude --only codex" + (install ? "" : " --uninstall")
            _ = Shell.shared.bash(cmd, timeout: 180)
            if install {
                self.ensureCodexCavemanInstructions()
                self.installBundledCavemanForCodexIfPossible()
            }
            DispatchQueue.main.async {
                self.cavemanInstalled = Self.isCavemanInstalled()
                self.caveman = self.cavemanInstalled
                self.updateStatusLine()
                self.setupLog += "Caveman \(self.cavemanInstalled ? "installed" : "removed").\n"
            }
        }
    }

    // ---- skills ops ----
    func addSkills() {
        guard let src = chooseFolder(prompt: "Pick a folder with SKILL.md (or a pack of skills)") else { return }
        let found = findSkillMds(under: src)
        if found.isEmpty { alert("No skills found", "No SKILL.md found in that folder."); return }
        try? FileManager.default.createDirectory(atPath: Paths.skillsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: Paths.codexSkillsDir, withIntermediateDirectories: true)
        var n = 0
        for md in found {
            let parent = (md as NSString).deletingLastPathComponent
            var name = Self.readMeta(md).name
            if name.isEmpty { name = FS.base(parent) }
            var copied = false
            do { try FS.copyDir(parent, Paths.skillsDir + "/" + name); copied = true } catch { }
            do { try FS.copyDir(parent, Paths.codexSkillsDir + "/" + name); copied = true } catch { }
            if copied { n += 1 }
        }
        loadSkills(); updateStatusLine()
        alert("Skills imported", "Imported \(n) skill(s) for Claude and ChatGPT/Codex.")
    }

    func toggleSkill(_ skill: Skill) {
        let destRoot = skill.enabled ? Paths.disabledDir : Paths.skillsDir
        try? FileManager.default.createDirectory(atPath: destRoot, withIntermediateDirectories: true)
        let target = destRoot + "/" + skill.name
        if FS.exists(target) { alert("Name clash", "A skill named '\(skill.name)' already exists on the other side."); return }
        try? FileManager.default.moveItem(atPath: skill.path, toPath: target)
        let codexSource = (skill.enabled ? Paths.codexSkillsDir : Paths.codexDisabledDir) + "/" + skill.name
        let codexDestRoot = skill.enabled ? Paths.codexDisabledDir : Paths.codexSkillsDir
        let codexTarget = codexDestRoot + "/" + skill.name
        try? FileManager.default.createDirectory(atPath: codexDestRoot, withIntermediateDirectories: true)
        if FS.exists(codexSource), !FS.exists(codexTarget) {
            try? FileManager.default.moveItem(atPath: codexSource, toPath: codexTarget)
        }
        loadSkills(); updateStatusLine()
    }

    func removeSkill(_ skill: Skill) {
        let a = NSAlert()
        a.messageText = "Delete skill '\(skill.name)'?"
        a.informativeText = skill.path
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.removeItem(atPath: skill.path)
            try? FileManager.default.removeItem(atPath: Paths.codexSkillsDir + "/" + skill.name)
            try? FileManager.default.removeItem(atPath: Paths.codexDisabledDir + "/" + skill.name)
            loadSkills(); updateStatusLine()
        }
    }

    func openSkillsFolder() {
        try? FileManager.default.createDirectory(atPath: Paths.skillsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.skillsDir))
    }

    private func findSkillMds(under root: String) -> [String] {
        var out: [String] = []
        guard let en = FileManager.default.enumerator(atPath: root) else { return out }
        for case let p as String in en where FS.base(p) == "SKILL.md" {
            out.append(root + "/" + p)
        }
        return out
    }

    // ---- alerts ----
    // Derive "<tag>-hydra" from a local Ollama model with repeat_penalty neutralized
    // (verified live: the 1.1 default eventually forbids the CORRECT token in repetitive
    // CSS/HTML, mangling output). `ollama create` from a local parent only links blobs —
    // fast and idempotent. Falls back to the original tag on any failure.
    func ollamaCodeSafeModel(_ tag: String) -> String {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.caseInsensitiveCompare("Default") != .orderedSame,
              !clean.lowercased().hasSuffix("-hydra"),
              let exe = OllamaService.installedExecutable() else { return tag }
        let modelfile = Paths.ollamaDir + "/Modelfile.hydra"
        FS.write(modelfile, "FROM \(clean)\nPARAMETER repeat_penalty 1.0\n")
        let result = Shell.shared.run(exe, ["create", clean + "-hydra", "-f", modelfile],
                                      env: ["OLLAMA_HOST": "127.0.0.1:\(OllamaPort)"], timeout: 60)
        return result.code == 0 ? clean + "-hydra" : clean
    }

    func alert(_ title: String, _ msg: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = msg
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }
}
