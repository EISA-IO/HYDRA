import SwiftUI
import AppKit

extension AppState {
    func log(_ line: String) {
        DispatchQueue.main.async { self.setupLog += line + "\n" }
    }

    /// Run a sequence of shell steps on a background queue, streaming to the log.
    private func runSteps(_ title: String, _ steps: [(String, String)], finish: (() -> Void)? = nil) {
        if setupBusy { log("(busy — wait for the current step to finish)"); return }
        setupBusy = true
        log("")
        log("===== \(title) =====")
        DispatchQueue.global(qos: .userInitiated).async {
            for (label, cmd) in steps {
                DispatchQueue.main.async { self.setupLog += "› \(label)\n" }
                let r = Shell.shared.bash(cmd, timeout: 900)
                let combined = (r.out + r.err)
                for l in combined.split(separator: "\n") {
                    DispatchQueue.main.async { self.setupLog += String(l) + "\n" }
                }
            }
            DispatchQueue.main.async {
                self.setupBusy = false
                self.refreshAll()
                self.updateStatusLine()
                finish?()
                self.setupLog += "===== Done. Restart any open Claude sessions to pick up changes. =====\n"
            }
        }
    }

    // ================= shared, robust command / script builders =================
    var hasNode: Bool { Shell.shared.onPath("node") && Shell.shared.onPath("npm") }

    /// Ensure Node.js + npm exist. No-op if present; brew if available; else the official
    /// LTS pkg installed with a native admin prompt. Safe to run repeatedly.
    func nodeEnsureScript() -> String {
        // The macOS Node installer is a single UNIVERSAL .pkg (node-vX.Y.Z.pkg) — no arch suffix.
        return """
        if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
          echo "Node.js already installed ($(node -v))."; exit 0
        fi
        if command -v brew >/dev/null 2>&1; then
          echo "Installing Node.js via Homebrew…"; brew install node
        else
          echo "Homebrew not found — installing the official Node LTS pkg (you'll be asked for your password)…"
          VER=$(curl -fsSL https://nodejs.org/dist/index.json | /usr/bin/python3 -c 'import sys,json;print([r["version"] for r in json.load(sys.stdin) if r["lts"]][0])')
          [ -z "$VER" ] && { echo "Could not determine Node LTS version."; exit 1; }
          echo "Latest LTS: $VER"
          PKG="/tmp/node-$VER.pkg"
          curl -fsSL "https://nodejs.org/dist/$VER/node-$VER.pkg" -o "$PKG" || { echo "Node download failed."; exit 1; }
          osascript -e "do shell script \\"installer -pkg '$PKG' -target /\\" with administrator privileges" || { echo "Node install cancelled or failed."; rm -f "$PKG"; exit 1; }
          rm -f "$PKG"
        fi
        hash -r 2>/dev/null || true
        if command -v node >/dev/null 2>&1; then echo "OK Node.js installed ($(node -v), npm $(npm -v))."; else echo "Node.js still not on PATH — open a new terminal or install from nodejs.org."; fi
        """
    }

    /// Install/update the Claude CLI as robustly as possible on a locked-down machine.
    /// 1) Anthropic's official self-contained installer (no npm). If that succeeds, done.
    /// 2) Otherwise npm into a USER-WRITABLE prefix we own (~/.claude-manager, whose /bin is
    ///    already first on PATH) with a FRESH cache. This dodges BOTH failures seen on shared
    ///    Macs: a root-owned global prefix (/usr/local/lib/node_modules → EACCES on mkdir) and
    ///    a poisoned ~/.npm/_cacache (EEXIST). No sudo, no touching /usr/local.
    func claudeInstallCmd() -> String {
        "curl -fsSL https://claude.ai/install.sh | bash; "
        + "claude --version >/dev/null 2>&1 || "   // must actually RUN, not just exist (native installer can half-fail)
        + "npm install -g @anthropic-ai/claude-code@latest "
        + "--prefix \"$HOME/.claude-manager\" --cache \"$(mktemp -d)\" --no-fund --no-audit --force"
    }

    func installCodex() {
        runSteps("Installing / updating the Codex CLI", [("Node.js", nodeEnsureScript()), ("Codex CLI", codexInstallCmd())]) {
            self.installBundledCavemanForCodexIfPossible()
            if Shell.shared.onPath("rtk") { _ = Shell.shared.run("rtk", ["init", "-g", "--codex"], timeout: 30) }
        }
    }

    func cavemanCmd() -> String {
        "npx -y github:JuliusBrussee/caveman --only claude --only codex"
    }

    /// Download the macOS RTK binary (if missing) AND register its Claude hook.
    func rtkFullScript() -> String {
        """
        set -e
        BIN="$HOME/.local/bin"
        mkdir -p "$BIN"
        if ! command -v rtk >/dev/null 2>&1 && [ ! -x "$BIN/rtk" ]; then
          echo "Fetching latest RTK release for macOS…"
          case "$(uname -m)" in
            arm64) PAT="darwin.*aarch64|aarch64.*darwin|darwin.*arm64|arm64.*darwin|aarch64-apple|apple-darwin.*aarch64";;
            *)     PAT="darwin.*x86_64|x86_64.*darwin|x86_64-apple|apple-darwin.*x86_64";;
          esac
          URL=$(curl -fsSL https://api.github.com/repos/rtk-ai/rtk/releases/latest \\
            | grep -Eo '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \\
            | grep -Ei "$PAT" | grep -Ei '\\.(tar\\.gz|zip)$' | head -1)
          if [ -z "$URL" ]; then
            URL=$(curl -fsSL https://api.github.com/repos/rtk-ai/rtk/releases/latest \\
              | grep -Eo '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \\
              | grep -Ei 'darwin|apple' | head -1)
          fi
          if [ -z "$URL" ]; then echo "Could not find a macOS RTK asset. Install rtk manually to ~/.local/bin."; exit 1; fi
          echo "Downloading $URL"
          TMP=$(mktemp -d)
          F="$TMP/rtk.archive"
          curl -fsSL "$URL" -o "$F"
          case "$URL" in
            *.zip) unzip -o "$F" -d "$TMP" >/dev/null;;
            *)     tar -xzf "$F" -C "$TMP";;
          esac
          RTKBIN=$(find "$TMP" -type f -name rtk | head -1)
          [ -z "$RTKBIN" ] && { echo "rtk binary not found in archive."; exit 1; }
          cp "$RTKBIN" "$BIN/rtk"; chmod +x "$BIN/rtk"
          rm -rf "$TMP"
          echo "OK RTK installed to $BIN/rtk"
        else
          echo "rtk already present — updating hook."
        fi
        RTK=$(command -v rtk || echo "$HOME/.local/bin/rtk")
        echo "Registering RTK hook…"
        "$RTK" init -g --auto-patch
        echo "OK RTK hook registered (default input compression)."
        """
    }

    // ---- individual installers ----
    func installNode() {
        if hasNode { log("Node.js already installed."); refreshAll(); return }
        runSteps("Installing Node.js", [("Node.js", nodeEnsureScript())])
    }

    func installClaude() {
        runSteps("Installing / updating the Claude CLI", [("Claude CLI", claudeInstallCmd())])
    }

    func installRtk() {
        runSteps("Installing RTK (input compression)", [("RTK (download + register)", rtkFullScript())]) {
            self.rtkInstalled = Self.isRtkInstalled(); self.rtk = self.rtkInstalled
        }
    }

    func installCaveman() {
        let cmd = hasNode ? cavemanCmd()
                          : "echo 'Caveman needs Node.js — install Node first (Install everything does this for you).'"
        runSteps("Installing Caveman (output compression)", [("Caveman", cmd)]) {
            self.cavemanInstalled = Self.isCavemanInstalled(); self.caveman = self.cavemanInstalled
        }
    }

    func installClaudeVideo() {
        runSteps("Installing Claude Video /watch", [("Claude Video", "echo Installing bundled /watch skill for Claude and Codex")]) {
            self.installClaudeVideoIfPossible()
            self.videoInstalled = Self.isVideoInstalled()
            self.loadSkills()
            self.updateStatusLine()
        }
    }

    func installAgentSkills() {
        runSteps("Installing Agent Skills", [("Agent Skills", "echo Installing bundled Addy Osmani Agent Skills for Claude and Codex")]) {
            self.installAgentSkillsIfPossible()
            self.agentSkillsInstalled = Self.isAgentSkillsInstalled()
            self.loadSkills()
            self.updateStatusLine()
        }
    }

    // ---- Headroom (optional) ----
    func installHeadroom() {
        if Shell.shared.onPath("headroom") { log("Headroom already installed (optional)."); return }
        let script = """
        if command -v pipx >/dev/null 2>&1; then pipx install "headroom-ai[all]";
        elif command -v uv >/dev/null 2>&1; then uv tool install "headroom-ai[all]";
        elif command -v brew >/dev/null 2>&1; then brew install pipx && pipx install "headroom-ai[all]";
        elif command -v pip3 >/dev/null 2>&1; then pip3 install --user "headroom-ai[all]";
        else echo "Install Python 3.10+ (or pipx/uv) then retry."; fi
        """
        runSteps("Installing Headroom (optional)", [("install headroom-ai", script)])
    }

    // ---- bundled skills next to the app ----
    func findSkillsSource() -> String? {
        let exeDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let res = Bundle.main.resourcePath ?? ""
        let cands = [
            res + "/skills",                 // bundled inside the .app (shipped with the app)
            res + "/SKILLS-BACKUP",
            res + "/ESSENTIAL-SKILLS",
            exeDir + "/SKILLS-BACKUP",        // next to the .app (dev / portable)
            exeDir + "/skills",
            exeDir + "/ESSENTIAL-SKILLS",
            Paths.home + "/Desktop/HYDRA/SKILLS-BACKUP",
            Paths.home + "/Desktop/HYDRA/ESSENTIAL-SKILLS"
        ].filter { !$0.isEmpty }
        for c in cands where FS.isDir(c) && hasAnySkill(c) { return c }
        return nil
    }

    private func hasAnySkill(_ dir: String) -> Bool {
        for d in FS.dirs(dir) where FS.exists(d + "/SKILL.md") { return true }
        return false
    }

    /// Copy every SKILL.md pack under `src` into Claude and Codex user skill folders.
    private func doInstallSkills(from src: String) {
        var out: [String] = []
        if let en = FileManager.default.enumerator(atPath: src) {
            for case let p as String in en where FS.base(p) == "SKILL.md" { out.append(src + "/" + p) }
        }
        if out.isEmpty { log("No SKILL.md found under \(src)"); return }
        try? FileManager.default.createDirectory(atPath: Paths.skillsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: Paths.codexSkillsDir, withIntermediateDirectories: true)
        var n = 0
        for md in out {
            let parent = (md as NSString).deletingLastPathComponent
            var name = Self.readMeta(md).name
            if name.isEmpty { name = FS.base(parent) }
            var copied = false
            do { try FS.copyDir(parent, Paths.skillsDir + "/" + name); copied = true } catch { log("  x Claude " + name) }
            do { try FS.copyDir(parent, Paths.codexSkillsDir + "/" + name); copied = true } catch { log("  x Codex " + name) }
            if copied { n += 1; log("  + " + name) }
        }
        log("OK Installed/updated \(n) skill(s) into \(Paths.skillsDir) and \(Paths.codexSkillsDir)")
        DispatchQueue.main.async { self.loadSkills(); self.updateStatusLine() }
    }

    func installBundledSkills() {
        let src = findSkillsSource() ?? chooseFolder(prompt: "Pick a folder containing skills (any SKILL.md inside)")
        guard let src = src else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.doInstallSkills(from: src) }
    }

    /// Ship the bundled skills as a native default: seed them once (guarded by a marker so
    /// we never re-install after the user curates or deletes their own skills).
    func autoInstallBundledSkillsIfEmpty() {
        let marker = Paths.stateDir + "/.skills-seeded"
        let codexCount = FS.dirs(Paths.codexSkillsDir).filter { FS.exists($0 + "/SKILL.md") }.count
        if FS.exists(marker), codexCount > 0 { return }
        guard (countSkills() == 0 || codexCount == 0), let src = findSkillsSource() else {
            if countSkills() > 0 && codexCount > 0 { FS.write(marker, "") }   // already has skills — don't keep checking
            return
        }
        FS.write(marker, "")
        DispatchQueue.global(qos: .utility).async { self.doInstallSkills(from: src) }
    }

    // ---- one-shot: install everything ----
    func installEverything() {
        let steps: [(String, String)] = [
            ("Node.js", nodeEnsureScript()),
            ("Claude CLI", claudeInstallCmd()),
            ("Codex CLI", codexInstallCmd()),
            ("RTK", rtkFullScript()),
            ("Caveman", cavemanCmd() + " || echo '(Caveman needs Node.js — install Node then retry)'")
        ]
        runSteps("Installing everything (Node · Claude CLI · RTK · Caveman · Claude Video · Agent Skills · skills)", steps) {
            // bundled skills, quietly (no folder prompt inside the batch flow)
            if let src = self.findSkillsSource() {
                DispatchQueue.global(qos: .userInitiated).async { self.doInstallSkills(from: src) }
            } else {
                self.log("No bundled skills found next to the app — use the Skills button to add a folder.")
            }
            self.rtkInstalled = Self.isRtkInstalled(); self.rtk = self.rtkInstalled
            if Shell.shared.onPath("rtk") { _ = Shell.shared.run("rtk", ["init", "-g", "--codex"], timeout: 30) }
            self.installBundledCavemanForCodexIfPossible()
            self.installClaudeVideoIfPossible()
            self.videoInstalled = Self.isVideoInstalled()
            self.installAgentSkillsIfPossible()
            self.agentSkillsInstalled = Self.isAgentSkillsInstalled()
            self.cavemanInstalled = Self.isCavemanInstalled(); self.caveman = self.cavemanInstalled
        }
    }

    // ---- update the core packages in place to their latest versions ----
    func updateCore() {
        let steps: [(String, String)] = [
            ("npm", Shell.shared.onPath("npm") ? "npm install -g npm@latest" : "echo '(skip npm — Node not installed)'"),
            ("Claude CLI", claudeInstallCmd()),
            ("Codex CLI", Shell.shared.onPath("npm") ? codexInstallCmd() : "echo '(skip Codex CLI — Node not installed)'"),
            ("RTK", rtkFullScript()),
            ("Caveman", hasNode ? cavemanCmd() : "echo '(skip Caveman — needs Node.js)'")
        ]
        runSteps("Updating core packages to latest", steps) {
            self.rtkInstalled = Self.isRtkInstalled(); self.rtk = self.rtkInstalled
            if Shell.shared.onPath("rtk") { _ = Shell.shared.run("rtk", ["init", "-g", "--codex"], timeout: 30) }
            self.installBundledCavemanForCodexIfPossible()
            self.installClaudeVideoIfPossible()
            self.videoInstalled = Self.isVideoInstalled()
            self.installAgentSkillsIfPossible()
            self.agentSkillsInstalled = Self.isAgentSkillsInstalled()
            self.cavemanInstalled = Self.isCavemanInstalled(); self.caveman = self.cavemanInstalled
        }
    }

    func isARM() -> Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.contains("arm")
    }
}
