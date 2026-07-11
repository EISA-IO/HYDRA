import Foundation
import SwiftUI

// ============================================================================
// Ollama model manager — the classic OLLAMA MANAGER flows (recommended list,
// pull, chat, delete, context length) on top of the runtime built into Hydra.
// Mirrors the Windows manager so the two stay in sync.
// ============================================================================
extension AppState {

    /// Recommended pull-able tags, from a user-editable recommended_models.txt
    /// (GROUP|tag per line, LOW/HIGH VRAM groups); seeded with the ornith defaults.
    static func recommendedOllamaModels() -> [(group: String, tag: String)] {
        var list: [(String, String)] = []
        if !FS.exists(Paths.ollamaRecFile) {
            try? FileManager.default.createDirectory(atPath: Paths.ollamaDir, withIntermediateDirectories: true)
            FS.write(Paths.ollamaRecFile, "LOW|ornith:9b\nHIGH|ornith:35b\n")
        }
        for raw in (FS.read(Paths.ollamaRecFile) ?? "").split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let bar = line.firstIndex(of: "|"), bar != line.startIndex {
                list.append((String(line[..<bar]).trimmingCharacters(in: .whitespaces).uppercased(),
                             String(line[line.index(after: bar)...]).trimmingCharacters(in: .whitespaces)))
            } else {
                list.append(("", line))
            }
        }
        if list.isEmpty { list = [("LOW", "ornith:9b"), ("HIGH", "ornith:35b")] }
        return list
    }

    /// Locally downloaded models: scan manifests on disk (works with the server off).
    /// Covers Hydra's built-in store plus any legacy ~/.ollama store.
    static func installedOllamaModels() -> [String] {
        var names: [String] = []
        let roots = [Paths.ollamaModelsDir + "/manifests", Paths.home + "/.ollama/models/manifests"]
        for manifests in roots where FS.isDir(manifests) {
            for registry in FS.dirs(manifests) {                    // registry.ollama.ai
                for ns in FS.dirs(registry) {                       // library / rafw007 / …
                    // Community models keep their namespace ("rafw007/model:tag") —
                    // dropping it produces names Ollama 404s on. Only "library" is implicit.
                    let nsName = FS.base(ns)
                    let prefix = nsName == "library" ? "" : nsName + "/"
                    for model in FS.dirs(ns) {                      // llama3.2
                        let files = (try? FileManager.default.contentsOfDirectory(atPath: model)) ?? []
                        for tag in files {
                            let name = prefix + FS.base(model) + ":" + tag
                            if !names.contains(name) { names.append(name) }
                        }
                    }
                }
            }
        }
        return names
    }

    /// Disk footprint of the model stores, in GB.
    static func ollamaModelsGb() -> Double {
        var total: Int64 = 0
        for root in [Paths.ollamaModelsDir + "/blobs", Paths.home + "/.ollama/models/blobs"] where FS.isDir(root) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for f in files {
                let attrs = try? FileManager.default.attributesOfItem(atPath: root + "/" + f)
                total += (attrs?[.size] as? Int64) ?? 0
            }
        }
        return (Double(total) / 1_073_741_824.0 * 100).rounded() / 100
    }

    /// Menu text → clean tag ("✓ name" and "name   (LOW VRAM)" both → "name").
    static func cleanOllamaTag(_ text: String) -> String {
        var tag = text.trimmingCharacters(in: .whitespaces)
        if tag.hasPrefix("✓") { tag = String(tag.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let space = tag.firstIndex(of: " ") { tag = String(tag[..<space]) }
        return tag
    }

    /// Rebuild the picker: downloaded models first (✓-marked), then the recommended list.
    func refreshOllamaModels() {
        DispatchQueue.global(qos: .utility).async {
            let installed = Self.installedOllamaModels()
            let recommended = Self.recommendedOllamaModels()
            let gb = Self.ollamaModelsGb()
            var tags = installed.map { "✓ " + $0 }
            for rec in recommended {
                let have = installed.contains { $0 == rec.tag || $0 == rec.tag + ":latest"
                    || (!rec.tag.contains(":") && $0.hasPrefix(rec.tag + ":")) }
                if !have { tags.append(rec.group.isEmpty ? rec.tag : "\(rec.tag)   (\(rec.group) VRAM)") }
            }
            DispatchQueue.main.async {
                self.ollamaMenuTags = tags
                if installed.isEmpty {
                    self.ollamaModelsStatus = self.ollamaBuiltIn
                        ? "No models downloaded yet — pick a tag and click Download."
                        : "Ollama isn't built in yet — the Download button builds it into Hydra first."
                } else {
                    self.ollamaModelsStatus = "✓ \(installed.count) model\(installed.count == 1 ? "" : "s") downloaded · \(gb) GB on disk"
                }
            }
        }
    }

    /// Shell snippet: make sure the built-in server is up before a model action.
    /// Uses the tuned environment; models stay inside Hydra's dir.
    private func ollamaEnsureServerScript(exe: String) -> String {
        let env = OllamaService.serverEnvironment(executable: exe)
            .map { "export \($0.key)=\(TerminalLauncher.shellQuote($0.value))" }
            .joined(separator: "\n")
        return """
        \(env)
        if ! curl -s -m 2 "http://127.0.0.1:\(OllamaPort)/api/version" >/dev/null 2>&1; then
          echo "Starting the built-in Ollama server…"
          nohup \(TerminalLauncher.shellQuote(exe)) serve >/dev/null 2>&1 &
          for i in $(seq 1 40); do
            curl -s -m 1 "http://127.0.0.1:\(OllamaPort)/api/version" >/dev/null 2>&1 && break
            sleep 0.5
          done
        fi
        """
    }

    /// `ollama pull` — builds the runtime into Hydra first when it's missing.
    func pullOllamaModel() {
        let tag = Self.cleanOllamaTag(ollamaTag)
        if tag.isEmpty { log("Pick or type an Ollama model tag first (e.g. ornith:9b)."); return }
        let install = FileManager.default.isExecutableFile(atPath: Paths.ollamaExe)
            ? "true" : ollamaInstallScript()
        let exe = Paths.ollamaExe
        let script = """
        \(install)
        [ -x \(TerminalLauncher.shellQuote(exe)) ] || { echo "Ollama runtime unavailable."; exit 1; }
        \(ollamaEnsureServerScript(exe: exe))
        \(TerminalLauncher.shellQuote(exe)) pull \(TerminalLauncher.shellQuote(tag))
        """
        runOllamaSteps("Ollama: download model \(tag)", [("ollama pull \(tag)", script)])
    }

    /// `ollama rm` — the classic manager's delete flow.
    func deleteOllamaModel() {
        let tag = Self.cleanOllamaTag(ollamaTag)
        if tag.isEmpty { log("Pick a downloaded model to delete."); return }
        guard let exe = OllamaService.installedExecutable() else {
            log("Ollama isn't built in yet — nothing to delete."); return
        }
        let script = """
        \(ollamaEnsureServerScript(exe: exe))
        \(TerminalLauncher.shellQuote(exe)) rm \(TerminalLauncher.shellQuote(tag))
        """
        runOllamaSteps("Ollama: delete model \(tag)", [("ollama rm \(tag)", script)])
    }

    /// Open an embedded chat terminal running the model (the classic "Launch a Model").
    func chatOllamaModel() {
        let tag = Self.cleanOllamaTag(ollamaTag)
        if tag.isEmpty { log("Pick a downloaded model to chat with."); return }
        chatOllama(tag: tag)
    }

    /// Sidebar "Ollama Chat": chat with the picked model (Settings combo), or the first
    /// downloaded one. Boots the built-in server first so the chat just works.
    func openOllamaChat() {
        var tag = Self.cleanOllamaTag(ollamaTag)
        if tag.isEmpty { tag = Self.installedOllamaModels().first ?? "" }
        if tag.isEmpty {
            alert("Ollama Chat", "No local models yet. Download one first in Settings → Ollama models (e.g. ornith:9b).")
            return
        }
        chatOllama(tag: tag)
    }

    private func chatOllama(tag: String) {
        guard let exe = OllamaService.installedExecutable() else {
            alert("Ollama", "Ollama isn't built into Hydra yet. Use Settings → \"Install everything\" (or its Ollama button) first.")
            return
        }
        // Boot the built-in server first (Hydra-owned); the terminal waits for the
        // port before starting the model so the chat just works.
        if !Self.portOpen(OllamaPort), ollama.state != .runningOwned, ollama.state != .starting {
            ollama.start()
        }
        let flags = tag.lowercased().contains("qwen3.5") ? " --think=false" : ""
        let wait = "i=0; until curl -s -m 1 \"http://127.0.0.1:\(OllamaPort)/api/version\" >/dev/null 2>&1; do sleep 0.5; i=$((i+1)); [ $i -gt 60 ] && break; done"
        let command = "echo 'Loading \(tag)…'; \(wait); \(OllamaService.shellEnvPrefix(executable: exe)) \(TerminalLauncher.shellQuote(exe)) run \(TerminalLauncher.shellQuote(tag))\(flags)"
        runInWorkspace(command, cwd: Paths.home,
                       note: "Chatting with \(tag) — type /bye to leave the chat.",
                       agentLabel: "Ollama", modelLabel: tag,
                       taskLabel: "Chat with \(tag)")
    }

    /// Persist a new context window; restart the owned server so it takes effect.
    func applyOllamaCtx() {
        guard let v = Int(ollamaCtxText.trimmingCharacters(in: .whitespaces)), v > 0 else {
            log("Context length must be a positive whole number (e.g. 8192)."); return
        }
        OllamaService.saveContextLength(v)
        log("Ollama context length set to \(v).")
        if ollama.state == .runningOwned {
            log("Restarting the built-in Ollama server with the new context…")
            ollama.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.ollama.start() }
        } else if Self.portOpen(OllamaPort) {
            log("Note: the running server is managed outside Hydra — restart it yourself to apply the new context.")
        }
    }

    /// Like runSteps but refreshes the model list when done (kept private to installers).
    private func runOllamaSteps(_ title: String, _ steps: [(String, String)]) {
        if setupBusy { log("(busy — wait for the current step to finish)"); return }
        setupBusy = true
        log("")
        log("===== \(title) =====")
        DispatchQueue.global(qos: .userInitiated).async {
            for (label, cmd) in steps {
                DispatchQueue.main.async { self.setupLog += "› \(label)\n" }
                let r = Shell.shared.bash(cmd, timeout: 3600)
                for l in (r.out + r.err).split(separator: "\n") {
                    DispatchQueue.main.async { self.setupLog += String(l) + "\n" }
                }
            }
            DispatchQueue.main.async {
                self.setupBusy = false
                self.refreshOllamaModels()
                self.ollama.refresh()
                self.updateStatusLine()
                self.setupLog += "===== Done. =====\n"
            }
        }
    }
}
