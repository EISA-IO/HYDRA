import SwiftUI
import AppKit

// ============================================================================
// Hermes tab — one big dashboard entry, LLM mapping, and the skills hub.
// Sessions, memories, schedules, tasks and analytics live in Hermes' own GUI
// dashboard (localhost:9119); the full command reference is in the Glossary
// tab. Hermes keeps its own skills ecosystem: Hydra never mixes the shared
// Claude/Codex skills into it.
// ============================================================================
struct HermesView: View {
    @EnvironmentObject var app: AppState
    @State private var skillRef = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hermes").font(.system(size: 21, weight: .bold)).foregroundStyle(.white)
                    Text("Nous Research's agent — LLM mapping, install & updates, and its own skills ecosystem. Hydra never mixes the shared Claude/Codex skills into Hermes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }

                // The dashboard is Hermes' own full manager (models, accounts, sessions,
                // schedules, profiles, skills, tools, analytics, plugins) — one big obvious way in.
                Button { app.openHermesDashboard() } label: {
                    Text("🌐   Open Hermes Dashboard  —  localhost:9119")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.plain)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                mappingCard
                skillsHubCard

                Text("Sessions, memories, schedules, tasks and analytics live in the dashboard above. The full command reference is in the Glossary tab.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(22)
        }
    }

    private var mappingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(text: "1  Map Hermes to an LLM")
                Text("Choose where Hermes authenticates, then choose or type the model that provider should run.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: "Provider / account")
                        DarkPicker(options: app.hermesProviderOptions, selection: Binding(
                            get: { HermesIntegration.providerLabel(forID: app.hermesProvider) },
                            set: { app.setHermesProviderLabel($0) }))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: "Hermes model ID")
                        HStack(spacing: 6) {
                            DarkField(placeholder: "Default", text: Binding(
                                get: { app.defaultModel(for: "Hermes") },
                                set: { app.setDefaultModel($0, for: "Hermes") }), mono: true)
                            Menu("Suggestions") {
                                ForEach(HermesIntegration.modelSuggestions(forProviderID: app.hermesProvider), id: \.self) { model in
                                    Button(model) { app.setDefaultModel(model, for: "Hermes") }
                                }
                            }.menuStyle(.borderlessButton)
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: "Profile (optional)")
                        DarkField(placeholder: "default", text: $app.hermesProfile, mono: true)
                            .onChange(of: app.hermesProfile) { app.saveSettings(); app.loadSkills() }
                    }
                }
                Text("Hermes will use  \(HermesIntegration.providerLabel(forID: app.hermesProvider))  →  \(app.defaultModel(for: "Hermes") == "Default" ? "provider default model" : app.defaultModel(for: "Hermes"))")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accentHi)
                FlowButtons { [
                    AnyView(Button("Configure accounts") { app.configureHermes() }.accentButton()),
                    AnyView(Button("Install / repair") { app.installHermes() }.ghostButton()),
                    AnyView(Button("Check update") { app.checkHermesUpdate() }.ghostButton()),
                    AnyView(Button("Update now") { app.updateHermes() }.ghostButton()),
                    AnyView(Button("Doctor") { app.runHermesInWorkspace("doctor", task: "Hermes diagnostics") }.ghostButton())
                ] }
            }
        }
    }

    private var skillsHubCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(text: "2  Skills hub")
                Text("Visit the hub to find a skill, paste its ID (or SKILL.md URL) here, then install or remove it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                FieldLabel(text: "Skill ID (e.g. official/security/1password) or a direct SKILL.md URL")
                HStack(spacing: 8) {
                    DarkField(placeholder: "official/security/1password", text: $skillRef, mono: true)
                    Button("Visit skill hub") {
                        NSWorkspace.shared.open(URL(string: "https://hermes-agent.nousresearch.com/docs/skills/")!)
                    }.ghostButton()
                    Button("Install skill") { runSkill("install", "Install Hermes skill") }.accentButton()
                    Button("Remove skill") { runSkill("uninstall", "Remove Hermes skill") }.ghostButton()
                }
            }
        }
    }

    // Skill actions run in a visible Workspace terminal so progress stays on screen.
    private func runSkill(_ verb: String, _ title: String) {
        let clean = skillRef.trimmingCharacters(in: .whitespaces)
        guard HermesIntegration.validSkillRef(clean) else {
            app.alert("Hermes skills", "Enter a skill ID (e.g. official/security/1password) or a direct SKILL.md URL first — letters, numbers and . _ : / @ + - only.")
            return
        }
        var args = "skills " + verb + " " + TerminalLauncher.shellQuote(clean)
        if verb == "install" { args += " --yes" }
        app.runHermesInWorkspace(args, task: title)
    }
}
