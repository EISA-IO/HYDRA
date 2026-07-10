import SwiftUI

// A small "?" that expands a detailed explanation bubble for an option.
struct HelpButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textFaint)
        }
        .buttonStyle(.plain)
        .help("Click for details")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineSpacing(2)
                .frame(width: 330, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .background(Theme.card)
        }
    }
}

// A field caption with an inline "?" help bubble.
struct HelpLabel: View {
    let text: String
    let help: String
    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            HelpButton(text: help)
            Spacer(minLength: 0)
        }
    }
}

// One organized step: numbered badge, title + subtitle, and its action button on the right.
struct StepRow: View {
    let n: Int
    let title: String
    let subtitle: String
    let button: () -> AnyView
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(Theme.field).frame(width: 26, height: 26)
                Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 12)
            button()
        }
        .padding(.vertical, 3)
    }
}

// A big numbered stage marker for the unified top-to-bottom SaaS journey.
struct StageHeader: View {
    let n: Int
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent).frame(width: 34, height: 34)
                Text("\(n)").font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

struct SaaSView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var m = SaaSModel()
    @State private var checklistTick = 0   // bumped by a timer so the checklist stays live

    private var stepDivider: some View {
        Divider().overlay(Color.white.opacity(0.05))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    projectBar
                    instantBar
                    StageHeader(n: 1, title: "Vision", subtitle: "Describe your idea, then scaffold the app")
                    visionPhase
                    stageGap
                    StageHeader(n: 2, title: "Deploy", subtitle: "Put it online via GitHub + your cloud of choice")
                    deployPhase
                    stageGap
                    StageHeader(n: 3, title: "Subscriptions", subtitle: "Charge users and email your subscribers")
                    subsPhase
                    LogPane(text: m.log).frame(minHeight: 140).padding(.top, 4)
                }
                .padding(.bottom, 12)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            m.app = app
            sanitizeBuildModel()
        }
    }

    // ---- chrome ----
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Build a SaaS").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
            Text("From idea to a live, paid product — just follow the three steps below.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
        }
    }

    private var stageGap: some View { Color.clear.frame(height: 2) }

    private var projectBar: some View {
        Card {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "App name (folder-safe)")
                    DarkField(placeholder: "my-saas", text: $m.name)
                }.frame(width: 170)
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Parent folder")
                    HStack(spacing: 6) {
                        DarkField(placeholder: Paths.home, text: $m.parent)
                        Button("…") { if let f = chooseFolder(prompt: "Parent folder", start: m.parent) { m.parent = f } }.ghostButton()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Builder")
                    Picker("", selection: $m.buildAgent) {
                        Text("Claude").tag("Claude")
                        Text("ChatGPT").tag("ChatGPT")
                    }
                    .pickerStyle(.segmented)
                }.frame(width: 130)
                VStack(alignment: .leading, spacing: 6) {
                    HelpLabel(text: "Build with model", help: "Choose Claude or ChatGPT as the SaaS builder. ChatGPT launches through Codex and uses the Codex model list, including gpt-5.6-sol, gpt-5.6-terra, and gpt-5.6-luna.")
                    DarkPicker(options: app.launchModelOptions(for: m.buildAgent), selection: $m.buildModel)
                        .onChange(of: m.buildAgent) {
                            sanitizeBuildModel()
                        }
                }.frame(width: 190)
            }
        }
    }

    private func sanitizeBuildModel() {
        if m.buildAgent == "ChatGPT" {
            let normalized = app.cliModelName(m.buildModel)
            if app.launchModelOptions(for: m.buildAgent).contains(normalized) { m.buildModel = normalized }
        }
        if !app.launchModelOptions(for: m.buildAgent).contains(m.buildModel) { m.buildModel = "Default" }
    }

    // ---- ⚡ instant mode + live launch checklist ----
    private var instantBar: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(Theme.yellow)
                            Text("Instant SaaS").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            HelpButton(text: "The one-click path: writes ALL the specs (vision, payments, deploy, subscriptions, email, analytics) into your app folder and starts a single Claude or ChatGPT session that scaffolds the app, builds every feature, wires billing + subscriber email + Google Analytics, creates your GitHub repo with CI/CD, and deploys — reporting the live URL at the end. You only step in for sign-ins and real payment keys.")
                        }
                        Text("Fill the pitch (or pick a preset), then let your builder take it from idea to a live URL in one run.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Button("⚡ Build it all") { m.buildEverything() }.accentButton()
                }
                Divider().overlay(Color.white.opacity(0.05))
                // Live stack preview — exactly what pressing ⚡ will build, before you press it.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("YOUR STACK").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Theme.textFaint)
                        HelpButton(text: "This is the exact stack the ⚡ instant build uses — it updates live as you change the options below. Every build starts from the Open SaaS template (github.com/wasp-lang/open-saas): Wasp + React + Node.js + Prisma + PostgreSQL, whatever the use case. You'll also confirm this summary in a dialog before anything runs.")
                        Spacer()
                    }
                    Text(m.stackSummary())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Divider().overlay(Color.white.opacity(0.05))
                HStack(spacing: 6) {
                    Text("PROGRESS").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Theme.textFaint)
                    Spacer()
                    ForEach(m.checklist) { item in
                        HStack(spacing: 4) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(item.done ? Theme.green : Theme.textFaint)
                            Text(item.label).font(.system(size: 10.5))
                                .foregroundStyle(item.done ? .white : Theme.textFaint)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 7)
                        .background(Theme.field.opacity(item.done ? 1 : 0.45))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            checklistTick += 1   // re-evaluate the checklist as Claude works
        }
    }

    // ---- VISION ----
    private var visionPhase: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Start from a template", help: "Pre-fills the pitch, features, and pricing tiers for a common SaaS type — a proven starting point you then tweak. Pick \"Custom\" to write everything yourself. Choosing a template overwrites the pitch/features/tiers fields.")
                            DarkPicker(options: m.presetOptions, selection: Binding(
                                get: { m.preset },
                                set: { m.applyPreset($0) }
                            ))
                        }.frame(width: 260)
                        Spacer()
                    }
                    HelpLabel(text: "In one line: what does your SaaS do, and for whom?",
                              help: "Your one-line elevator pitch. Claude uses this to understand the product's purpose and target user — it shapes every screen, feature, and copy choice. Be specific about WHO it's for (e.g. \"Invoicing for freelance designers in KSA\").")
                    DarkField(placeholder: "e.g. Invoicing for freelance designers in KSA", text: $m.pitch)
                    HelpLabel(text: "Core features / pages (one per line)",
                              help: "List the main pages and capabilities, one per line (e.g. Dashboard, Invoice editor, Client list). Claude turns each line into real routes, UI, and database models. More detail here = a more complete first build.")
                    DarkEditor(text: $m.features).frame(height: 96)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Auth", help: "How users sign in. \"Email + password\" is the simplest; adding Google/GitHub gives one-click login (built into Open SaaS). The integrated platforms go further: Firebase Auth = Google's hosted sign-in (email + Google + Apple, free tier); Supabase Auth = the same idea on Postgres; Clerk = beautiful drop-in sign-in components with almost no code. Claude wires whichever you pick, including syncing users into your database.")
                            DarkPicker(options: m.authOptions, selection: $m.auth)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Payments (KSA-first)", help: "Which processor charges your customers. KSA-first: Tap & Moyasar support mada, Apple Pay and STC Pay for Saudi customers. Stripe / Lemon Squeezy / Polar are global. Claude gets a verified integration spec (incl. the tricky amount-unit rules) for whichever you choose.")
                            DarkPicker(options: m.payOptions, selection: $m.pay)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: " ")
                            Button("Payments guide") { m.showPaymentGuide() }.ghostButton()
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "AI layer", help: "The brain behind your AI features — our own integrated router, not a third-party gateway. It calls providers in a best→cheapest priority order and falls back automatically when one is rate-limited. \"Smart fallback\" serves free users on commercial-free models (Groq, OpenRouter :free, Gemini) at $0 and unlocks frontier models (GPT-4o, Gemini 2.5 Pro, DeepSeek R1) for paid tiers. \"OpenRouter only\" = one key, 300+ models. \"Groq only\" = fastest free tokens. \"BYOK\" = each customer brings their own key, so AI costs you nothing. Every provider here allows commercial use within its free limits — no ToS games. Your builder drops a ready router (src/server/ai/router.ts) into the app.")
                            DarkPicker(options: m.aiProviderOptions, selection: $m.aiProvider)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    SectionCap(text: "Scaffold & build")
                    Text("Three steps from idea to a running app.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint).padding(.bottom, 6)
                    StepRow(n: 1, title: "Prerequisites", subtitle: "Install the Wasp CLI (one-time)") {
                        AnyView(Button("Check / install") { m.checkWasp() }.ghostButton())
                    }
                    stepDivider
                    StepRow(n: 2, title: "Scaffold", subtitle: "Create the Open SaaS app folder") {
                        AnyView(Button("Create app") { m.createApp() }.ghostButton())
                    }
                    stepDivider
                    StepRow(n: 3, title: "Build with \(m.buildAgent)", subtitle: "Save your vision, then \(m.buildAgent) builds it") {
                        AnyView(Button("Save + build") { m.build() }.accentButton())
                    }
                    stepDivider
                    HStack(spacing: 8) {
                        Text("When it's built").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Run app locally") { m.run() }.ghostButton()
                        Button("Open docs") { NSWorkspace.shared.open(URL(string: "https://docs.opensaas.sh")!) }.ghostButton()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // ---- DEPLOY ----
    private var deployPhase: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Deploy target", help: "Where your site goes live. Vercel = fastest for React/Next.js frontends (zero config). Firebase Hosting = great when you also want Firestore + Auth. Cloud Run = a container for any language or a long-running backend. Pick Vercel if unsure.")
                            DarkPicker(options: m.targetOptions, selection: $m.target)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Backend", help: "What powers your server logic. \"None\" = a static site (no server). Firebase Functions + Firestore = serverless API + database. Cloud Run API = your own container. Vercel Serverless = functions in an /api folder. Choose based on whether your app needs a server + database.")
                            DarkPicker(options: m.backendOptions, selection: $m.backend)
                        }
                    }
                    if m.target == "Cloud Run" {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HelpLabel(text: "Region", help: "The datacenter that runs your service. Pick one near your users for lower latency — e.g. me-central2 for the Middle East.")
                                DarkPicker(options: m.regionOptions, selection: $m.region)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HelpLabel(text: "Service name", help: "The name of your Cloud Run service — it appears in the service URL. Lowercase, e.g. \"api\".")
                                DarkField(placeholder: "api", text: $m.serviceName)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HelpLabel(text: "GCP project id", help: "Your Google Cloud project identifier (from console.cloud.google.com). Deploys and CI/CD target this project.")
                                DarkField(placeholder: "my-project-123", text: $m.gcpProject)
                            }
                        }
                    } else if m.target == "Firebase Hosting" {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HelpLabel(text: "Public dir", help: "The folder your build produces and Firebase serves. Vite → \"dist\", Create React App → \"build\".")
                                DarkField(placeholder: "dist", text: $m.publicDir)
                            }.frame(width: 220)
                            VStack(alignment: .leading, spacing: 6) {
                                HelpLabel(text: "Firebase project id", help: "Your Firebase project identifier (from the Firebase console). Used by deploy + CI/CD.")
                                DarkField(placeholder: "my-project", text: $m.gcpProject)
                            }
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.06)).padding(.vertical, 2)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "GitHub repository", help: "Your code lives in a GitHub repo — the single source of truth. \"Private\" keeps it hidden. Once pushed, GitHub Actions can auto-deploy every change to your host. The steps below can create + push this repo for you.")
                            DarkPicker(options: m.repoVisibilityOptions, selection: $m.repoVisibility)
                        }.frame(width: 160)
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel(text: " ")
                            Text("GitHub is the core home for your code — push a \(m.repoVisibility.lowercased()) repo, then auto-deploy every change to \(m.target).")
                                .font(.system(size: 11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            // Clear, guided 3-step deploy — replaces the old wall of buttons.
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    SectionCap(text: "Go live — 3 steps")
                    Text("New to deploying? Do these in order.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint).padding(.bottom, 6)
                    StepRow(n: 1, title: "Connect your host", subtitle: "Install the \(m.target) CLI and sign in") {
                        AnyView(Button("Connect") { m.connectHost() }.ghostButton())
                    }
                    stepDivider
                    StepRow(n: 2, title: "Push to GitHub", subtitle: "Create your \(m.repoVisibility.lowercased()) repo — code home & deploy source") {
                        AnyView(Button("Create repo + push") { m.pushToGitHub() }.ghostButton())
                    }
                    stepDivider
                    StepRow(n: 3, title: "Go live", subtitle: "Publish and get your live URL (config is written for you)") {
                        AnyView(Button("Deploy now") { m.deployNow() }.accentButton())
                    }
                    stepDivider
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Rather not do it yourself?").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            Text("Claude sets up config, backend, CI/CD and deploys — end to end.").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        Button("Let \(m.buildAgent) deploy it") { m.buildDeployWithClaude() }.blueButton()
                    }
                    .padding(.vertical, 2)
                    stepDivider
                    // Optional / advanced — small, out of the way.
                    HStack(spacing: 8) {
                        Text("Optional").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Auto-deploy on push") { m.addGitHubActions() }.ghostButton()
                        Button("Config files") { m.scaffoldDeploy() }.ghostButton()
                        Button("Guide") { m.openDeployGuide() }.ghostButton()
                        Button("Check tools") { m.checkDeployTools() }.ghostButton()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // ---- SUBSCRIPTIONS ----
    private var subsPhase: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Billing provider (KSA-first)", help: "Who charges subscribers on a recurring basis. Tap & Moyasar handle Saudi recurring payments (you charge a saved card each period via a scheduled job). Stripe has built-in subscription billing + a hosted customer portal for upgrades/cancels.")
                            DarkPicker(options: m.subProviderOptions, selection: $m.subProvider)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Free trial (days)", help: "How many days new users get free before their first charge. Set 0 for no trial. During the trial they still count as active/subscribed.")
                            DarkField(placeholder: "14", text: $m.trialDays)
                        }.frame(width: 150)
                    }
                    HelpLabel(text: "Plans / tiers (one per line)", help: "Your pricing tiers, one per line as \"Name — price\" (e.g. Pro — 69 SAR/mo). Your builder creates the plan picker, checkout, and feature-gating (entitlements) from these. Include a Free tier if you want one.")
                    DarkEditor(text: $m.tiers).frame(height: 84)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Email provider", help: "Who sends your emails. Resend = modern & easy (React email templates). Postmark = best deliverability for receipts. SendGrid = mature, with marketing campaigns. Used for receipts, payment-failed (dunning) notices, and newsletters/broadcasts.")
                            DarkPicker(options: m.emailProviderOptions, selection: $m.emailProvider)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HelpLabel(text: "Send from", help: "The \"from\" address subscribers see. Use a domain you control — you'll add SPF, DKIM and DMARC DNS records so your email lands in the inbox, not spam.")
                            DarkField(placeholder: "billing@yourdomain.com", text: $m.fromEmail)
                        }
                    }
                    Text("Subscribers get transactional email (receipts, dunning) + broadcasts, with SPF/DKIM/DMARC and one-click unsubscribe.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    SectionCap(text: "Subscription + email infrastructure")
                    Text("\(m.buildAgent) implements checkout, webhooks, the customer portal, and subscriber emails.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint).padding(.bottom, 6)
                    StepRow(n: 1, title: "Write the spec", subtitle: "Save SUBSCRIPTIONS.md + EMAIL.md into your project") {
                        AnyView(Button("Scaffold specs") { m.scaffoldSubscriptions() }.ghostButton())
                    }
                    stepDivider
                    StepRow(n: 2, title: "Build it with \(m.buildAgent)", subtitle: "Full billing + email system, wired to your DB") {
                        AnyView(Button("Build with \(m.buildAgent)") { m.buildSubsWithClaude() }.accentButton())
                    }
                    stepDivider
                    HStack(spacing: 8) {
                        Text("Reference").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Billing docs") { m.openBillingDocs() }.ghostButton()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}
