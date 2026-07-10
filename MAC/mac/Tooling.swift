import SwiftUI
import AppKit

// ============================================================================
// Native toolchain — makes Claude/Codex CLI, RTK, Caveman (and Headroom) work WITHOUT
// the user downloading anything. The app ships the binaries it legally can inside
// its bundle (Resources/tools), and on launch provisions them into a managed bin
// dir (~/.claude-manager/bin) that is first on PATH for every embedded terminal.
// Anything we can't redistribute (Anthropic's `claude`) is auto-installed once,
// silently, so the *user* still never runs an install command by hand.
// ============================================================================
extension AppState {

    /// Locate the bundled `tools/` payload — inside the .app, next to it, or in the repo.
    func toolsSource() -> String? {
        let res = Bundle.main.resourcePath ?? ""
        let exeDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let cands = [
            res + "/tools",                                   // shipped inside the .app
            exeDir + "/tools",                                // next to the .app (portable)
            Paths.home + "/Desktop/HYDRA/tools"      // dev checkout
        ]
        for c in cands where FS.isDir(c) && FS.exists(c + "/manifest.json") { return c }
        return nil
    }

    /// The platform folder inside the payload that holds this machine's binaries.
    private func platformSlot() -> String {
        #if arch(arm64)
        return "mac-arm64"
        #else
        return "mac-x64"
        #endif
    }

    /// Provision the native toolchain. Idempotent, cheap, safe to call every launch.
    /// Runs its slow parts off the main thread. Never blocks startup.
    func provisionNativeToolchain() {
        try? FileManager.default.createDirectory(atPath: Paths.managedBin, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async {
            let sh = Shell.shared
            let src = self.toolsSource()

            // 1) RTK — copy the bundled binary into the managed bin (no download). If we don't
            //    ship one for this arch and rtk isn't already anywhere, fall back to the installer.
            let rtkDst = Paths.managedBin + "/rtk"
            if let src = src {
                let bundledRtk = src + "/" + self.platformSlot() + "/rtk"
                if FS.exists(bundledRtk) && self.shouldReplace(bundledRtk, rtkDst) {
                    try? FileManager.default.removeItem(atPath: rtkDst)
                    try? FileManager.default.copyItem(atPath: bundledRtk, toPath: rtkDst)
                    self.makeExecutable(rtkDst)
                    DispatchQueue.main.async { self.setupLog += "Native RTK ready (bundled, no download).\n" }
                }
            }
            if !FS.exists(rtkDst) && !sh.onPath("rtk") {
                // no bundled binary for this platform and none installed — self-provision quietly
                _ = sh.bash(self.rtkFullScript(), timeout: 180)
            }
            // Register the RTK hook (input compression) using whichever rtk is now on PATH.
            if !Self.isRtkInstalled(), let rtkBin = sh.which("rtk") ?? (FS.exists(rtkDst) ? rtkDst : nil) {
                _ = sh.run(rtkBin, ["init", "-g", "--auto-patch"], timeout: 30)
            }

            // 2) Caveman — seed the marketplace locally so the plugin installs OFFLINE from the
            //    bundled copy (no `npx github:…` fetch). Mirrors how it lives on a working machine.
            if let src = src {
                let bundledCaveman = src + "/caveman"
                let mkDst = Paths.home + "/.claude/plugins/marketplaces/caveman"
                if FS.isDir(bundledCaveman) && !FS.isDir(mkDst) {
                    try? FileManager.default.createDirectory(
                        atPath: (mkDst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try? FS.copyDir(bundledCaveman, mkDst)
                    DispatchQueue.main.async { self.setupLog += "Native Caveman marketplace seeded (offline).\n" }
                }
                // If Caveman isn't registered yet, install it from the LOCAL copy (needs node; if
                // node is missing the app's installer flow handles that separately).
                if !Self.isCavemanInstalled(), sh.onPath("node") {
                    let installer = (FS.exists(mkDst + "/bin/install.js") ? mkDst : bundledCaveman) + "/bin/install.js"
                    if FS.exists(installer) {
                        _ = sh.run(sh.which("node") ?? "node", [installer, "--only", "claude", "--only", "codex"], timeout: 120)
                    }
                }
            }

            // 3) Claude CLI — not redistributable, so we can't bundle Anthropic's binary. If it's
            //    genuinely missing, install it once, silently, so the user still does nothing.
            if !sh.onPath("claude") {
                DispatchQueue.main.async { self.setupLog += "Claude CLI not found — installing it once…\n" }
                _ = sh.bash(self.claudeInstallCmd(), timeout: 300)
            }

            // 4) Codex CLI — install from npm if missing, then wire the same RTK/Caveman defaults
            //    that launch() enforces synchronously for each Codex terminal.
            if !sh.onPath("codex"), sh.onPath("npm") {
                DispatchQueue.main.async { self.setupLog += "Codex CLI not found — installing it once…\n" }
                _ = sh.bash(self.codexInstallCmd(), timeout: 300)
            }
            if sh.onPath("codex") {
                _ = sh.run("rtk", ["init", "-g", "--codex"], timeout: 30)
                self.ensureCodexCavemanInstructionsForProvisioning()
                self.installBundledCavemanForCodexIfPossible()
            }

            // 5) Claude Video — ship /watch as a local skill for both Claude and Codex, and
            //    register the vendored plugin where each CLI supports plugin marketplaces.
            self.installClaudeVideoIfPossible()

            // 6) Addy's Agent Skills — lifecycle engineering skills for Claude and ChatGPT/Codex.
            self.installAgentSkillsIfPossible()

            DispatchQueue.main.async { self.refreshAll() }
        }
    }

    func codexInstallCmd() -> String {
        "npm install -g @openai/codex@latest --prefix \"$HOME/.claude-manager\" --cache \"$(mktemp -d)\" --no-fund --no-audit --force"
    }

    func installBundledCavemanForCodexIfPossible() {
        guard let src = toolsSource(), Shell.shared.onPath("codex") else { return }
        let marketplaceRoot = src + "/caveman"
        guard FS.exists(marketplaceRoot + "/.agents/plugins/marketplace.json") else { return }
        if !codexMarketplaceConfigured(name: "caveman", root: marketplaceRoot) {
            _ = Shell.shared.run("codex", ["plugin", "marketplace", "remove", "caveman"], env: ["CODEX_HOME": Paths.codexDir], timeout: 30)
            _ = Shell.shared.run("codex", ["plugin", "marketplace", "add", marketplaceRoot], env: ["CODEX_HOME": Paths.codexDir], timeout: 60)
        }
        let listed = Shell.shared.run("codex", ["plugin", "list"], env: ["CODEX_HOME": Paths.codexDir], timeout: 30)
        let cavemanInstalled = (listed.out + listed.err).split(separator: "\n").contains { line in
            line.contains("caveman@caveman") && line.contains("installed") && !line.contains("not installed")
        }
        if !cavemanInstalled {
            _ = Shell.shared.run("codex", ["plugin", "add", "caveman@caveman"], env: ["CODEX_HOME": Paths.codexDir], timeout: 120)
        }
    }

    private func codexMarketplaceConfigured(name: String, root: String) -> Bool {
        guard let cfg = FS.read(Paths.codexDir + "/config.toml") else { return false }
        return cfg.contains("[marketplaces.\(name)]") && cfg.contains("source = \"\(root)\"")
    }

    func installClaudeVideoIfPossible() {
        guard let src = toolsSource() else { return }
        let root = src + "/claude-video"
        let skill = root + "/skills/watch"
        guard FS.exists(skill + "/SKILL.md") else { return }

        do {
            try FileManager.default.createDirectory(atPath: Paths.skillsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: Paths.codexSkillsDir, withIntermediateDirectories: true)
            try FS.copyDir(skill, Paths.skillsDir + "/watch")
            try FS.copyDir(skill, Paths.codexSkillsDir + "/watch")
            DispatchQueue.main.async { self.setupLog += "Claude Video /watch skill installed for Claude and Codex.\n" }
        } catch {
            DispatchQueue.main.async { self.setupLog += "Claude Video skill install warning: \(error.localizedDescription)\n" }
        }

        let claudeMarketplace = Paths.home + "/.claude/plugins/marketplaces/claude-video"
        if FS.exists(root + "/.claude-plugin/plugin.json") && !FS.isDir(claudeMarketplace) {
            do {
                try FileManager.default.createDirectory(
                    atPath: (claudeMarketplace as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try FS.copyDir(root, claudeMarketplace)
            } catch { }
        }

        if Shell.shared.onPath("codex"), FS.exists(root + "/.agents/plugins/marketplace.json") {
            if !codexMarketplaceConfigured(name: "claude-video", root: root) {
                _ = Shell.shared.run("codex", ["plugin", "marketplace", "remove", "claude-video"], env: ["CODEX_HOME": Paths.codexDir], timeout: 30)
                _ = Shell.shared.run("codex", ["plugin", "marketplace", "add", root], env: ["CODEX_HOME": Paths.codexDir], timeout: 60)
            }
            _ = Shell.shared.run("codex", ["plugin", "add", "watch@claude-video"], env: ["CODEX_HOME": Paths.codexDir], timeout: 120)
        }
    }

    func installAgentSkillsIfPossible() {
        guard let src = toolsSource() else { return }
        let root = src + "/agent-skills"
        let skillsRoot = root + "/skills"
        guard FS.isDir(skillsRoot), FS.exists(root + "/.codex-plugin/plugin.json") else { return }

        var copied = 0
        do {
            try FileManager.default.createDirectory(atPath: Paths.skillsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: Paths.codexSkillsDir, withIntermediateDirectories: true)
            for dir in FS.dirs(skillsRoot) where FS.exists(dir + "/SKILL.md") {
                let name = FS.base(dir)
                try FS.copyDir(dir, Paths.skillsDir + "/" + name)
                try FS.copyDir(dir, Paths.codexSkillsDir + "/" + name)
                copied += 1
            }
            DispatchQueue.main.async { self.setupLog += "Agent Skills installed for Claude and Codex (\(copied) skills).\n" }
        } catch {
            DispatchQueue.main.async { self.setupLog += "Agent Skills install warning: \(error.localizedDescription)\n" }
        }

        let claudeMarketplace = Paths.home + "/.claude/plugins/marketplaces/agent-skills"
        if FS.exists(root + "/.claude-plugin/plugin.json") && !FS.isDir(claudeMarketplace) {
            do {
                try FileManager.default.createDirectory(
                    atPath: (claudeMarketplace as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try FS.copyDir(root, claudeMarketplace)
            } catch { }
        }

        if Shell.shared.onPath("codex"), FS.exists(root + "/.agents/plugins/marketplace.json") {
            if !codexMarketplaceConfigured(name: "agent-skills", root: root) {
                _ = Shell.shared.run("codex", ["plugin", "marketplace", "remove", "agent-skills"], env: ["CODEX_HOME": Paths.codexDir], timeout: 30)
                _ = Shell.shared.run("codex", ["plugin", "marketplace", "add", root], env: ["CODEX_HOME": Paths.codexDir], timeout: 60)
            }
            _ = Shell.shared.run("codex", ["plugin", "add", "agent-skills@agent-skills"], env: ["CODEX_HOME": Paths.codexDir], timeout: 120)
        }
    }

    private func ensureCodexCavemanInstructionsForProvisioning() {
        let start = "<!-- claude-manager-caveman-codex -->"
        if FS.read(Paths.codexAgents)?.contains(start) == true { return }
        let block = """

        <!-- claude-manager-caveman-codex -->
        # Caveman Mode

        Respond terse like smart caveman. Keep all technical substance, code, commands, API names, errors, security warnings, and irreversible-action warnings precise. Drop filler, pleasantries, hedging, and repetition. Use normal technical English for code, commits, diffs, legal/security risk, or when terse fragments could confuse. Resume terse mode after the risky/precise part. Stop only when user says "stop caveman" or "normal mode".
        <!-- /claude-manager-caveman-codex -->
        """
        let existing = FS.read(Paths.codexAgents) ?? ""
        FS.write(Paths.codexAgents, (existing.trimmingCharacters(in: .whitespacesAndNewlines) + block).trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
    }

    // ---- helpers ----
    private func shouldReplace(_ src: String, _ dst: String) -> Bool {
        guard FS.exists(dst) else { return true }
        let fm = FileManager.default
        let s = (try? fm.attributesOfItem(atPath: src)[.size] as? Int) ?? nil
        let d = (try? fm.attributesOfItem(atPath: dst)[.size] as? Int) ?? nil
        return s != d   // different size ⇒ a new bundled build; refresh it
    }

    private func makeExecutable(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
