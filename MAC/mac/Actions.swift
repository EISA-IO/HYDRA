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
        if permission.hasPrefix("Bypass") { return " --dangerously-bypass-approvals-and-sandbox" }
        if permission.hasPrefix("Plan") { return " --sandbox read-only --ask-for-approval on-request" }
        if permission.hasPrefix("Accept") { return " --ask-for-approval never" }
        return " --ask-for-approval on-request"
    }

    var launchButtonLabel: String {
        var tail = ""
        if headroom { tail += " +Headroom" }
        if rtk { tail += " +RTK" }
        if caveman { tail += " +Caveman" }
        let m = model.trimmingCharacters(in: .whitespaces).isEmpty ? "Default" : model
        return "Launch \(agent)  (\(m))\(tail)"
    }

    /// Write a per-session settings.json whose hooks touch event files so the app
    /// can reflect working/idle/waiting status for this Terminal tab.
    private func writeSessionSettings(id: String, rtk: Bool, caveman: Bool) -> String {
        let ev = Paths.eventsDir
        func hook(_ name: String) -> String {
            // touch a uniquely-named event file the app watches. BSD date has no %N, so add
            // $RANDOM to avoid same-second filename collisions swallowing rapid events.
            "touch \"\(ev)/\(id)__\(name)__$(date +%s)_$RANDOM.evt\""
        }
        func entry(_ cmd: String) -> [[String: Any]] {
            [["hooks": [["type": "command", "command": cmd]]]]
        }
        var hooks: [String: Any] = [
            "UserPromptSubmit": entry(hook("work")),
            "Notification":     entry(hook("notify")),
            "Stop":             entry(hook("stop"))
        ]
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
        // Caveman (output compression) is a PLUGIN. `enabledPlugins` is NOT a documented merge
        // key, so when we pass --settings the plugin can fail to load. Declare it per-session
        // (mirroring the user's global settings exactly) so Caveman reliably loads in EVERY
        // embedded terminal that has it enabled.
        if caveman {
            root["extraKnownMarketplaces"] = [
                "caveman": ["source": ["source": "github", "repo": "JuliusBrussee/caveman"]]
            ]
            root["enabledPlugins"] = ["caveman@caveman": true]
        }
        let path = Paths.sessDir + "/" + id + ".settings.json"
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return path
    }

    private var codexCavemanBlock: String {
        """

        <!-- claude-manager-caveman-codex -->
        # Caveman Mode

        Respond terse like smart caveman. Keep all technical substance, code, commands, API names, errors, security warnings, and irreversible-action warnings precise. Drop filler, pleasantries, hedging, and repetition. Use normal technical English for code, commits, diffs, legal/security risk, or when terse fragments could confuse. Resume terse mode after the risky/precise part. Stop only when user says "stop caveman" or "normal mode".
        <!-- /claude-manager-caveman-codex -->
        """
    }

    private func ensureCodexCavemanInstructions() {
        try? FileManager.default.createDirectory(atPath: Paths.codexDir, withIntermediateDirectories: true)
        let start = "<!-- claude-manager-caveman-codex -->"
        let end = "<!-- /claude-manager-caveman-codex -->"
        let existing = FS.read(Paths.codexAgents) ?? ""
        if existing.contains(start), let sr = existing.range(of: start), let er = existing.range(of: end, range: sr.upperBound..<existing.endIndex) {
            let updated = String(existing[..<sr.lowerBound]) + codexCavemanBlock + String(existing[er.upperBound...])
            FS.write(Paths.codexAgents, updated.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        } else {
            FS.write(Paths.codexAgents, (existing.trimmingCharacters(in: .whitespacesAndNewlines) + codexCavemanBlock).trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
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
    func launch(folder rawFolder: String? = nil, startupPrompt: String? = nil, modelOverride: String? = nil) {
        let f = (rawFolder ?? folder).trimmingCharacters(in: .whitespaces)
        guard FS.isDir(f) else {
            alert("Folder not found", f); return
        }
        if headroom && agent == "Claude" && !ensureProxy() { return }

        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())
        let m = (modelOverride ?? model).trimmingCharacters(in: .whitespaces)
        let extra = extraArgs.trimmingCharacters(in: .whitespaces)
        var cli: String
        if agent == "Codex" {
            ensureCodexCompressionForLaunch(useRtk: rtk, useCaveman: caveman)
            cli = "codex -C \(TerminalLauncher.shellQuote(f))"
            if !m.isEmpty && m != "Default" { cli += " --model \(TerminalLauncher.shellQuote(m))" }
            cli += codexPermissionFlags()
            if caveman { cli += " --enable hooks --dangerously-bypass-hook-trust" }
            if !extra.isEmpty { cli += " " + extra }
            if continueLast {
                cli += " resume --last"
            } else if let p = startupPrompt, !p.isEmpty {
                cli += " " + TerminalLauncher.shellQuote(p)
            }
        } else {
            trustFolder(f)
            let settings = writeSessionSettings(id: id, rtk: rtk, caveman: caveman)
            cli = "claude --settings \(TerminalLauncher.shellQuote(settings))"
            if !m.isEmpty && m != "Default" { cli += " --model \(m)" }
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
        if headroom && agent == "Claude" { env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(ProxyPort)" }
        applyCreds(to: &env)   // shared tokens/keys (Settings → Access & API keys)
        let envArr = env.map { "\($0.key)=\($0.value)" }

        terminals.spawn(id: id, folder: f, shellCommand: shellCommand, env: envArr,
                        agent: agent, headroom: agent == "Claude" ? headroom : false, rtk: rtk, caveman: caveman)
        saveRecent(f)
        saveSettings()
        refreshRecents()
        pendingTab = 0   // jump to the Workspace so the new session is visible
    }

    /// Run a plain shell command inside a new embedded Workspace terminal tab (NOT Claude),
    /// then drop into an interactive login shell so output stays visible and any prompts work.
    /// Used by the SaaS lifecycle (installs, logins, deploys) so everything stays in-app.
    func runInWorkspace(_ command: String, cwd: String, note: String? = nil) {
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
                        headroom: false, rtk: false, caveman: false)
        saveRecent(f)
        pendingTab = 0
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
        for _ in 0..<20 {
            if Self.portOpen(ProxyPort) { proxyRunning = true; return true }
            usleep(500_000)
        }
        alert("Headroom proxy", "Started 'headroom proxy' but port \(ProxyPort) did not come up. Give it a moment and try again.")
        return false
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
            let cmd = "npx -y github:JuliusBrussee/caveman --only claude" + (install ? "" : " --uninstall")
            _ = Shell.shared.bash(cmd, timeout: 180)
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
        var n = 0
        for md in found {
            let parent = (md as NSString).deletingLastPathComponent
            var name = Self.readMeta(md).name
            if name.isEmpty { name = FS.base(parent) }
            do { try FS.copyDir(parent, Paths.skillsDir + "/" + name); n += 1 } catch { }
        }
        loadSkills(); updateStatusLine()
        alert("Skills imported", "Imported \(n) skill(s).")
    }

    func toggleSkill(_ skill: Skill) {
        let destRoot = skill.enabled ? Paths.disabledDir : Paths.skillsDir
        try? FileManager.default.createDirectory(atPath: destRoot, withIntermediateDirectories: true)
        let target = destRoot + "/" + skill.name
        if FS.exists(target) { alert("Name clash", "A skill named '\(skill.name)' already exists on the other side."); return }
        try? FileManager.default.moveItem(atPath: skill.path, toPath: target)
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
