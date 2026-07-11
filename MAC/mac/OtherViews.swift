import SwiftUI
import AppKit

// ============================================================================
// Skills
// ============================================================================
struct SkillsView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: String?
    @State private var catalog = "Shared"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skills").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    Text("Shared Claude/Codex skills and native Hermes skills, together in one inventory.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if catalog == "Shared" {
                    Button("Import…") { app.addSkills() }.ghostButton()
                    Button("Open shared folder") { app.openSkillsFolder() }.ghostButton()
                } else {
                    Button("Browse / install in GUI") { app.openHermesDashboard() }.accentButton()
                    Button("Open Hermes manager") { app.pendingTab = 6 }.ghostButton()
                    Button("Open Hermes folder") { app.openManagedFolder(Paths.hermesProfileHome(app.hermesProfile) + "/skills") }.ghostButton()
                }
            }

            Picker("Skill catalog", selection: $catalog) {
                Text("Shared · \(app.skillsSummary)").tag("Shared")
                Text("Hermes · \(app.hermesSkillsSummary)").tag("Hermes")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)

            Card {
                if catalog == "Hermes" {
                    if app.hermesSkills.isEmpty {
                        Text("No native Hermes skills are installed for this profile. Use Browse / install to open Hermes' official skills manager.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, minHeight: 120).multilineTextAlignment(.center)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(app.hermesSkills) { skill in
                                    HStack(alignment: .top, spacing: 10) {
                                        Circle().fill(Theme.accent).frame(width: 8, height: 8).padding(.top, 5)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                                            if !skill.desc.isEmpty { Text(skill.desc).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(2) }
                                        }
                                        Spacer()
                                        Text("Hermes native").font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                                    }.padding(.vertical, 9).padding(.horizontal, 4)
                                    if skill.id != app.hermesSkills.last?.id { Divider().overlay(Color.white.opacity(0.05)) }
                                }
                            }
                        }
                    }
                } else if app.skills.isEmpty {
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
        let version = OllamaService.runtimeVersion().map { " v" + $0 } ?? ""
        return "Runtime \(app.ollamaBuiltIn ? "OK" : "—")\(version)   Server \(up ? "UP on 127.0.0.1:\(OllamaPort)" : "off")   Context \(OllamaService.contextLength())"
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
