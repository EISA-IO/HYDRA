import SwiftUI
import AppKit

// ============================================================================
// Skills
// ============================================================================
struct SkillsView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skills").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    Text(app.skillsSummary.isEmpty ? "Manage skills for Claude and ChatGPT/Codex." : app.skillsSummary)
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button("Import…") { app.addSkills() }.ghostButton()
                Button("Open folder") { app.openSkillsFolder() }.ghostButton()
            }

            Card {
                if app.skills.isEmpty {
                    Text("No skills installed yet.\nUse Import… to add a folder containing SKILL.md files, or install the bundled pack from the Setup tab. Imports are mirrored to Claude and ChatGPT/Codex.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .multilineTextAlignment(.center)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(app.skills) { skill in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(skill.enabled ? Theme.green : Theme.textFaint)
                                        .frame(width: 8, height: 8).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(skill.name).font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(skill.enabled ? .white : Theme.textDim)
                                        if !skill.desc.isEmpty {
                                            Text(skill.desc).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Button(skill.enabled ? "Disable" : "Enable") { app.toggleSkill(skill) }.ghostButton()
                                    Button {
                                        app.removeSkill(skill)
                                    } label: { Image(systemName: "trash").font(.system(size: 11)) }.ghostButton()
                                }
                                .padding(.vertical, 9)
                                .padding(.horizontal, 4)
                                if skill.id != app.skills.last?.id {
                                    Divider().overlay(Color.white.opacity(0.05))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { app.loadSkills() }
    }
}

// ============================================================================
// Glossary
// ============================================================================
struct GlossaryView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""

    var filtered: [(String, [GlossaryEntry])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var groups: [String] = []
        var map: [String: [GlossaryEntry]] = [:]
        for e in app.glossary {
            if !q.isEmpty && !(e.term + " " + e.desc).lowercased().contains(q) { continue }
            if map[e.category] == nil { groups.append(e.category); map[e.category] = [] }
            map[e.category]?.append(e)
        }
        return groups.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Glossary & reference").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                Text("Slash commands, CLI flags, keyboard tips, and the compression toolchain.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
                DarkField(placeholder: "Search commands, flags, tips…", text: $query)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(filtered, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionCap(text: group.0)
                            Card {
                                VStack(spacing: 0) {
                                    ForEach(group.1) { e in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(e.term)
                                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Theme.accentHi)
                                                .frame(width: 190, alignment: .leading)
                                                .textSelection(.enabled)
                                            Text(e.desc).font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 6)
                                        if e.id != group.1.last?.id { Divider().overlay(Color.white.opacity(0.04)) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// ============================================================================
// Settings — launch defaults + token compression + install/setup (mirrors the
// Windows "Settings" tab, which folds the old Setup tab in).
// ============================================================================
struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    Text("Defaults for every new terminal, the token-compression toolchain, and one-click install.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }

                // Launch defaults
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCap(text: "Launch defaults")
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(text: "Agent")
                            Picker("", selection: Binding(
                                get: { app.agent },
                                set: { app.setAgent($0) }
                            )) {
                                ForEach(app.agentOptions, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                FieldLabel(text: app.agent == "Codex" ? "ChatGPT model" : "Claude model")
                                DarkPicker(options: app.launchModelOptions(for: app.agent), selection: Binding(
                                    get: { app.model },
                                    set: { app.setLaunchModel($0) }
                                ))
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                FieldLabel(text: app.agent == "Codex" ? "Permissions (Codex: YOLO)" : "Permissions")
                                DarkPicker(options: app.permissionOptions, selection: $app.permission)
                            }
                        }
                        .onChange(of: app.permission) { app.saveSettings() }
                        Toggle(isOn: $app.continueLast) {
                            Text(app.agent == "Codex" ? "Resume last Codex conversation" : "Continue last conversation (--continue)")
                                .font(.system(size: 12.5)).foregroundStyle(.white)
                        }
                        .toggleStyle(.checkbox).tint(Theme.accent)
                        .onChange(of: app.continueLast) { app.saveSettings() }
                    }
                }

                // Token compression
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCap(text: "Token compression")
                        Text("Each toggle is independent — mix & match freely:")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        ToggleRow(title: "RTK — filter shell/test/build output (Claude hook + Codex instructions)",
                                  status: app.rtkInstalled ? "● installed — shell output filtered before it hits context"
                                                           : "○ not installed — toggle to add (needs rtk on PATH)",
                                  statusColor: app.rtkInstalled ? Theme.green : Theme.yellow,
                                  isOn: $app.rtk) { on in if on != app.rtkInstalled { app.setRtk(on) } }
                        Divider().overlay(Color.white.opacity(0.05))
                        ToggleRow(title: "Caveman — compress agent replies (Claude plugin + Codex instructions)",
                                  status: app.cavemanInstalled ? "● installed — Claude/Codex replies terse every session"
                                                               : "○ not installed — toggle to add (needs Node 18+)",
                                  statusColor: app.cavemanInstalled ? Theme.green : Theme.yellow,
                                  isOn: $app.caveman) { on in if on != app.cavemanInstalled { app.setCaveman(on) } }
                        Divider().overlay(Color.white.opacity(0.05))
                        ToggleRow(title: "Headroom — proxy compresses all tool output (per launch)",
                                  status: app.proxyRunning ? "● Headroom proxy: RUNNING on 127.0.0.1:\(ProxyPort)"
                                                           : "○ Headroom proxy: not running (auto-starts on launch)",
                                  statusColor: app.proxyRunning ? Theme.green : Theme.yellow,
                                  isOn: $app.headroom) { _ in app.saveSettings() }
                        Text(app.compressionAdvisory.0)
                            .font(.system(size: 11)).foregroundStyle(app.compressionAdvisory.1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Shared access tokens & API keys — reusable by every project.
                CredentialsSection()

                // Extra flags
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionCap(text: "Extra flags")
                        Text("Appended verbatim to every launch (optional)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        DarkField(placeholder: "--effort high   or   \"a starting prompt\"", text: $app.extraArgs, mono: true)
                            .onChange(of: app.extraArgs) { app.saveSettings() }
                    }
                }

                // Backup & sync
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionCap(text: "Backup & sync")
                        Text("Settings travel as plain JSON — credentials and API keys are never included, so exports and git pushes stay clean.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Fetch latest from GitHub") { app.fetchLatestFromGit() }.blueButton().disabled(app.setupBusy)
                            Button("Export settings (JSON)") { app.exportSettingsJson() }.ghostButton()
                            Button("Import settings (JSON)") { app.importSettingsJson() }.ghostButton()
                        }
                    }
                }

                // Install & setup
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCap(text: "Install & setup")
                        Text(app.statusLine.isEmpty ? "Detecting…" : app.statusLine)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            // Once everything's installed, "Install everything" is just noise —
                            // the tab focuses on the Update button (now the primary action).
                            if app.allCoreInstalled {
                                Button("Update core packages") { app.updateCore() }
                                    .accentButton()
                                    .disabled(app.setupBusy)
                                    .help("Update npm · Claude CLI · RTK · Caveman · Claude Video · Agent Skills to the latest versions")
                                Text("Everything's installed ✓")
                                    .font(.system(size: 11)).foregroundStyle(Theme.green)
                            } else {
                                Button {
                                    app.installEverything()
                                } label: { Text("Install everything  (Node · CLI · RTK · Caveman · Video · Agent Skills · skills · Ollama)") }
                                .accentButton()
                                .disabled(app.setupBusy)
                                .help("Re-checks every package and installs only what's missing — safe to run any time")
                                Button("Update core packages") { app.updateCore() }
                                    .blueButton()
                                    .disabled(app.setupBusy)
                                    .help("Update npm · Claude CLI · RTK · Caveman · Claude Video · Agent Skills to the latest versions")
                            }
                            if app.setupBusy {
                                ProgressView().controlSize(.small)
                                Text("working…").font(.system(size: 11)).foregroundStyle(Theme.yellow)
                            }
                        }
                        Text(app.allCoreInstalled
                             ? "Your toolchain is complete. “Update core packages” bumps npm · Claude CLI · RTK · Caveman · Claude Video · Agent Skills to the latest versions. Individual buttons below are there if you ever need them."
                             : "Fresh machine? “Install everything” installs Node.js first (via Homebrew, or the official pkg with an admin prompt), then the latest CLI + tools. “Update core packages” bumps everything already installed.")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                        FlowButtons {
                            [
                                AnyView(Button("Node.js") { app.installNode() }.ghostButton()),
                                AnyView(Button("Claude CLI") { app.installClaude() }.ghostButton()),
                                AnyView(Button("Codex CLI") { app.installCodex() }.ghostButton()),
                                AnyView(Button("RTK") { app.installRtk() }.ghostButton()),
                                AnyView(Button("Caveman") { app.installCaveman() }.ghostButton()),
                                AnyView(Button("Claude Video") { app.installClaudeVideo() }.ghostButton()),
                                AnyView(Button("Agent Skills") { app.installAgentSkills() }.ghostButton()),
                                AnyView(Button("Ollama") { app.installOllama() }.ghostButton()),
                                AnyView(Button("Headroom") { app.installHeadroom() }.ghostButton()),
                                AnyView(Button("Skills") { app.installBundledSkills() }.ghostButton()),
                                AnyView(Button("Open .claude") {
                                    let d = Paths.home + "/.claude"
                                    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(URL(fileURLWithPath: d))
                                }.ghostButton()),
                                AnyView(Button("Re-check") { app.refreshAll() }.ghostButton())
                            ]
                        }
                        LogPane(text: app.setupLog).frame(minHeight: 180)
                    }
                }

                // Ollama has its own tab now — leave a pointer where the section used to be.
                Card {
                    HStack(spacing: 10) {
                        SectionCap(text: "Ollama")
                        Text("Local LLM runtime, models and tuning moved to the Ollama tab.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        Button("Open Ollama tab") { app.pendingTab = 5 }.ghostButton()
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { app.refreshAll() }
    }
}

// ============================================================================
// Ollama tab — the local-LLM home (runtime · models · tuning · activity).
// Mirrors the Windows manager so the two stay in sync.
// ============================================================================
struct OllamaTabView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ollama").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Text("Local LLM built into Hydra — runtime, models, and tuning. Nothing is installed system-wide.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }

                // Runtime
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionCap(text: "Runtime")
                        Text(runtimeLine)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textDim)
                        HStack(spacing: 8) {
                            Button(app.ollamaBuiltIn ? "✓ Runtime built-in — re-check" : "Build runtime into Hydra") {
                                app.installOllama()
                            }.accentButton().disabled(app.setupBusy)
                            Button("Open folder") {
                                try? FileManager.default.createDirectory(atPath: Paths.ollamaDir, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(URL(fileURLWithPath: Paths.ollamaDir))
                            }.ghostButton()
                            Button("Edit recommended list") {
                                _ = AppState.recommendedOllamaModels()   // seeds the file when missing
                                NSWorkspace.shared.open(URL(fileURLWithPath: Paths.ollamaRecFile))
                            }.ghostButton()
                        }
                        Text("Everything lives in ~/.claude-manager/ollama — delete that folder, every trace is gone. Local apps connect via 127.0.0.1:\(OllamaPort).")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Models
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionCap(text: "Models")
                        Text("Pick a model tag (or type any tag from ollama.com/library), then Download runs `ollama pull`. ✓ = already downloaded.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Menu {
                                ForEach(app.ollamaMenuTags, id: \.self) { t in
                                    Button(t) { app.ollamaTag = AppState.cleanOllamaTag(t) }
                                }
                            } label: {
                                Text(app.ollamaMenuTags.isEmpty ? "no tags yet" : "choose ▾")
                                    .font(.system(size: 11))
                            }
                            .frame(width: 110)
                            DarkField(placeholder: "ornith:9b", text: $app.ollamaTag, mono: true)
                                .frame(maxWidth: 220)
                            Button("Download") { app.pullOllamaModel() }.accentButton().disabled(app.setupBusy)
                            Button("Chat") { app.chatOllamaModel() }.ghostButton()
                            Button("Delete") { app.deleteOllamaModel() }.ghostButton().disabled(app.setupBusy)
                            Button("Refresh") { app.refreshOllamaModels() }.ghostButton()
                        }
                        Text(app.ollamaModelsStatus.isEmpty ? " " : app.ollamaModelsStatus)
                            .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    }
                }

                // Tuning
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionCap(text: "Tuning")
                        HStack(spacing: 8) {
                            Text("Context length").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                            DarkField(placeholder: "8192", text: $app.ollamaCtxText, mono: true)
                                .frame(width: 90)
                            Button("Apply") { app.applyOllamaCtx() }.ghostButton()
                            Text("always on: keep-alive 30m · flash attention · q8_0 KV cache · any-origin local API")
                                .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }

                // Activity (shared install/pull log)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionCap(text: "Activity")
                        LogPane(text: app.setupLog).frame(minHeight: 180)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { app.refreshOllamaModels() }
    }

    private var runtimeLine: String {
        let up = AppState.portOpen(OllamaPort)
        return "Runtime \(app.ollamaBuiltIn ? "OK" : "—")   Server \(up ? "UP on 127.0.0.1:\(OllamaPort)" : "off")   Context \(OllamaService.contextLength())"
    }
}

// A simple wrapping button row.
struct FlowButtons: View {
    let items: () -> [AnyView]
    init(_ items: @escaping () -> [AnyView]) { self.items = items }
    var body: some View {
        let arr = items()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(arr.enumerated()), id: \.offset) { _, v in v }
        }
    }
}
