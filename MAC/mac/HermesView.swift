import SwiftUI

// ============================================================================
// Hermes tab — LLM mapping · lifecycle · skills hub · agent state · glossary.
// Mirrors the Windows Hermes tab. Hermes keeps its own skills ecosystem:
// Hydra never mixes the shared Claude/Codex skills into it.
// ============================================================================
struct HermesView: View {
    @EnvironmentObject var app: AppState
    @State private var skillRef = ""
    @State private var inventoryTitle = "Installed Hermes skills"
    @State private var inventory = ""
    @State private var inventoryBusy = false

    private let features: [(String, String)] = [
        ("★ hermes --tui", "Start the modern interactive agent UI; Hydra uses this for normal Hermes sessions."),
        ("★ hermes skills browse", "Explore the skills hub and install reviewed skills by registry identifier."),
        ("★ hermes -p <profile>", "Isolated profiles — separate auth, skills, memory, and configuration."),
        ("★ hermes cron create", "Schedule recurring agent or script tasks with skills and project context."),
        ("★ hermes sessions browse", "Search, resume, rename, export, prune, or delete conversation history."),
        ("★ hermes dashboard", "Open the local GUI for config, auth, sessions, schedules, profiles, skills, tools, analytics, and plugins."),
        ("★ hermes memory status", "Inspect built-in and external memory state."),
        ("hermes model / fallback", "Choose the primary model and the ordered failover provider chain."),
        ("hermes auth", "Add, list, reset, or remove pooled provider credentials."),
        ("hermes status --all", "Show component, provider, gateway, schedule, and tool health."),
        ("hermes doctor --fix", "Diagnose and repair configuration, dependencies, providers, skills, and tooling."),
        ("hermes skills search", "Search official and community skill registries."),
        ("hermes skills inspect", "Preview source, trust, metadata, and files before installing."),
        ("hermes skills config", "Enable or disable installed skills globally or by platform."),
        ("hermes plugins / curator", "Manage runtime plugins and background skill maintenance."),
        ("hermes tools", "Choose toolsets for the CLI, gateway platforms, and scheduled jobs."),
        ("hermes cron list --all", "List, edit, pause, resume, run, or remove schedules."),
        ("hermes kanban", "Manage durable multi-profile tasks, dependencies, comments, and workers."),
        ("hermes webhook subscribe", "React to supported external events such as GitHub issues and pull requests."),
        ("hermes gateway", "Run and manage connected messaging platforms."),
        ("hermes whatsapp / slack", "Set up supported messaging integrations."),
        ("hermes mcp", "Manage MCP servers or expose Hermes as an MCP server."),
        ("hermes computer-use", "Manage the Computer Use backend where supported."),
        ("hermes checkpoints / hooks", "Manage saved checkpoints and approved project hooks."),
        ("hermes backup / import", "Back up and restore the Hermes home through supported commands."),
        ("hermes logs --since 1h", "Filter agent, error, gateway, cron, and component logs."),
        ("hermes insights", "Review usage insights and analytics."),
        ("hermes config", "View or set supported configuration keys."),
        ("hermes proxy", "Run a local OpenAI-compatible OAuth proxy."),
        ("hermes lsp / acp", "Manage language servers or run an ACP server."),
        ("hermes update --backup", "Back up the active home, then update Hermes."),
        ("hermes dump / debug share", "Create a redacted support summary or diagnostic report.")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hermes").font(.system(size: 21, weight: .bold)).foregroundStyle(.white)
                    Text("Nous Research's agent — LLM mapping, install & updates, and its own skills ecosystem. Hydra never mixes the shared Claude/Codex skills into Hermes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }

                mappingCard
                skillsHubCard
                agentStateCard
                glossaryCard
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(22)
        }
        .onAppear { if inventory.isEmpty { loadInventory(["skills", "list"], "Installed Hermes skills") } }
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
                    AnyView(Button("Open full GUI dashboard") { app.openHermesDashboard() }.accentButton()),
                    AnyView(Button("Install / repair") { app.installHermes() }.ghostButton()),
                    AnyView(Button("Check update") { app.checkHermesUpdate() }.ghostButton()),
                    AnyView(Button("Update now") { app.updateHermes() }.ghostButton()),
                    AnyView(Button("Doctor") { runManager(["doctor"], "Hermes diagnostics") }.ghostButton())
                ] }
            }
        }
    }

    private var skillsHubCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(text: "2  Skills hub")
                Text("Hermes' own skills ecosystem (hermes skills). Browse the hub, install by ID or URL, inspect, remove — or open the folder to edit a skill by hand.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                FlowButtons { [
                    AnyView(Button("Browse hub in GUI") { app.openHermesDashboard() }.accentButton()),
                    AnyView(Button("Enable / disable in GUI") { app.openHermesDashboard() }.ghostButton()),
                    AnyView(Button("Update all skills") { runManager(["skills", "update"], "Update Hermes skills") }.ghostButton()),
                    AnyView(Button("Open skills folder") { app.openHermesSkillsFolder() }.ghostButton())
                ] }
                FieldLabel(text: "Skill ID (e.g. official/security/1password) or a direct SKILL.md URL")
                HStack(spacing: 8) {
                    DarkField(placeholder: "official/security/1password", text: $skillRef, mono: true)
                    Button("Install") { runSkill("install", "Install Hermes skill") }.accentButton()
                    Button("Inspect") { runSkill("inspect", "Inspect Hermes skill") }.ghostButton()
                    Button("Uninstall") { runSkill("uninstall", "Uninstall Hermes skill") }.ghostButton()
                }
            }
        }
    }

    private var agentStateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(text: "3  Agent state")
                Text("Live inventories straight from the Hermes CLI for the selected profile.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                FlowButtons { [
                    AnyView(Button("Installed skills") { loadInventory(["skills", "list"], "Installed Hermes skills") }.ghostButton()),
                    AnyView(Button("Memories") { loadInventory(["memory", "status"], "Hermes memory (built-in MEMORY.md / USER.md is always active)") }.ghostButton()),
                    AnyView(Button("Contexts (sessions)") { loadInventory(["sessions", "list"], "Hermes conversation sessions — the contexts you can resume") }.ghostButton()),
                    AnyView(Button("Scheduled tasks") { loadInventory(["cron", "list"], "Scheduled Hermes jobs (hermes cron)") }.ghostButton()),
                    AnyView(Button("Status") { loadInventory(["status", "--all"], "Hermes agent & platform status") }.ghostButton())
                ] }
                FlowButtons { [
                    AnyView(Button("Full manager") { app.openHermesDashboard() }.accentButton()),
                    AnyView(Button("Edit MEMORY.md") { app.openManagedText(Paths.hermesProfileHome(app.hermesProfile) + "/memories/MEMORY.md", initial: "# Long-term memory\n") }.ghostButton()),
                    AnyView(Button("Edit USER.md") { app.openManagedText(Paths.hermesProfileHome(app.hermesProfile) + "/memories/USER.md", initial: "# User preferences\n") }.ghostButton()),
                    AnyView(Button("Task board") { runManager(["kanban", "list"], "Hermes kanban tasks") }.ghostButton())
                ] }
                Text(inventoryTitle).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accentHi)
                ScrollView([.horizontal, .vertical]) {
                    Text(inventoryBusy ? "Loading…" : inventory)
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textDim)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 170, maxHeight: 240)
                .padding(10).background(Color.black.opacity(0.28)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var glossaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(text: "4  Hermes glossary — top features")
                Text("The features that get the most out of Hermes. ★ = recommended starting points.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(features, id: \.0) { feature in
                        HStack(alignment: .top, spacing: 12) {
                            Text(feature.0)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accentHi)
                                .frame(width: 270, alignment: .leading)
                            Text(feature.1)
                                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func loadInventory(_ arguments: [String], _ title: String) {
        inventoryTitle = title
        inventoryBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = app.hermesInventoryText(arguments)
            DispatchQueue.main.async {
                inventory = text
                inventoryBusy = false
            }
        }
    }

    private func runManager(_ arguments: [String], _ title: String) {
        loadInventory(arguments, title)
    }

    private func runSkill(_ verb: String, _ title: String) {
        inventoryTitle = title
        inventoryBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = app.hermesSkillCommandText(verb, ref: skillRef)
            DispatchQueue.main.async {
                inventory = text
                inventoryBusy = false
            }
        }
    }
}
