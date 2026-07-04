import SwiftUI
import AppKit

// ============================================================================
// Native toolchain — makes Claude CLI, RTK, Caveman (and Headroom) work WITHOUT
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
            Paths.home + "/Desktop/CLAUDE-MANAGER/tools"      // dev checkout
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
                        _ = sh.run(sh.which("node") ?? "node", [installer, "--only", "claude"], timeout: 120)
                    }
                }
            }

            // 3) Claude CLI — not redistributable, so we can't bundle Anthropic's binary. If it's
            //    genuinely missing, install it once, silently, so the user still does nothing.
            if !sh.onPath("claude") {
                DispatchQueue.main.async { self.setupLog += "Claude CLI not found — installing it once…\n" }
                _ = sh.bash(self.claudeInstallCmd(), timeout: 300)
            }

            DispatchQueue.main.async { self.refreshAll() }
        }
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
