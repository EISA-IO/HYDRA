import SwiftUI
import AppKit
import Combine

enum SaaSPhase: String, CaseIterable, Identifiable {
    case vision = "Vision"
    case deploy = "Deploy"
    case subs   = "Subscriptions"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .vision: return "sparkles"
        case .deploy: return "cloud.fill"
        case .subs:   return "creditcard.fill"
        }
    }
    var blurb: String {
        switch self {
        case .vision: return "Scaffold Open SaaS, capture the vision, let Claude build it."
        case .deploy: return "Ship to Vercel, Firebase, or Cloud Run — with a real backend."
        case .subs:   return "Recurring billing + email your subscribers, done right."
        }
    }
}

final class SaaSModel: ObservableObject {
    // ---- shared ----
    @Published var phase: SaaSPhase = .vision
    @Published var name = "my-saas"
    @Published var parent = Paths.home
    @Published var buildModel = "Default"   // which Claude model builds the SaaS
    @Published var log = "From idea to a live, paid product — follow the three steps.\n"

    // ---- vision ----
    @Published var pitch = ""
    @Published var features = ""
    @Published var auth = "Email + Google + GitHub"
    @Published var pay = "Tap Payments (KSA)"   // KSA-first: default to a local processor
    let authOptions = ["Email + password", "Google", "GitHub", "Email + Google + GitHub",
                       "Firebase Auth (email + Google + Apple)", "Supabase Auth (email + social)", "Clerk (drop-in auth UI)"]
    let payOptions = ["Tap Payments (KSA)", "Moyasar (KSA)", "Stripe", "Lemon Squeezy", "Polar.sh", "None (add later)"]

    // ---- AI layer: our own integrated, legitimate multi-provider router shipped with every
    // AI SaaS. Priority ladder (best model → cheapest fallback), all commercial-use-OK. ----
    @Published var aiProvider = "Smart fallback (OpenRouter + Groq + free)"
    let aiProviderOptions = ["Smart fallback (OpenRouter + Groq + free)",
                             "OpenRouter only (best models)",
                             "Groq only (fastest free)",
                             "BYOK (customer brings key)",
                             "None (no AI features)"]

    // ---- deploy ----
    @Published var target = "Vercel"
    @Published var backend = "None (static site)"
    @Published var region = "us-central1"
    @Published var publicDir = "dist"
    @Published var gcpProject = ""
    @Published var serviceName = "api"
    @Published var repoVisibility = "Private"   // GitHub is the core deploy location; private by default
    let repoVisibilityOptions = ["Private", "Public"]
    let targetOptions = ["Vercel", "Firebase Hosting", "Cloud Run"]
    let backendOptions = ["None (static site)", "Firebase Functions + Firestore", "Cloud Run API (container)", "Vercel Serverless (/api)"]
    let regionOptions = ["us-central1", "us-east1", "europe-west1", "me-central2", "asia-south1"]

    // ---- subscriptions ----
    @Published var subProvider = "Tap Payments (KSA)"   // KSA-first default for SaaS recurring
    @Published var tiers = "Free — 0 SAR\nPro — 69 SAR/mo\nTeam — 199 SAR/mo"
    @Published var trialDays = "14"
    @Published var emailProvider = "Resend"
    @Published var fromEmail = "billing@yourdomain.com"
    let subProviderOptions = ["Tap Payments (KSA)", "Moyasar (KSA)", "Stripe"]
    let emailProviderOptions = ["Resend", "Postmark", "SendGrid"]

    // ---- presets: common SaaS types that pre-fill the vision so beginners start fast.
    // Middle-East-first: the region's real, underserved needs lead the list. ----
    @Published var preset = "Custom"
    let presetOptions = ["Custom",
                         // Middle East first — what people here actually need
                         "Property rentals (KSA)", "Restaurant QR menu", "Clinic bookings",
                         "Umrah trip organizer", "Real-estate CRM", "HR & payroll (KSA)",
                         "WhatsApp storefront", "Quran & tutoring academy", "Event ticketing",
                         "Charity & zakat", "Tadawul paper trading (AI)", "AI web scraping service",
                         // Global classics
                         "AI tool", "Marketplace", "Booking & appointments",
                         "Invoicing & finance", "Courses & learning", "Team dashboard"]

    weak var app: AppState?
    private var autosave: AnyCancellable?

    init() {
        loadConfig()
        // Autosave the whole form ~1s after any change so nothing is lost between launches.
        autosave = objectWillChange
            .debounce(for: .seconds(1.0), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.saveConfig() }
    }

    var appDir: String { parent.trimmingCharacters(in: .whitespaces) + "/" + name.trimmingCharacters(in: .whitespaces) }
    func out(_ s: String) { DispatchQueue.main.async { self.log += s + "\n" } }

    // ---- persistence: the form survives app restarts (~/.claude-manager/saas.json) ----
    private var configPath: String { Paths.stateDir + "/saas.json" }

    func saveConfig() {
        let d: [String: String] = [
            "name": name, "parent": parent, "buildModel": buildModel,
            "pitch": pitch, "features": features, "auth": auth, "pay": pay, "aiProvider": aiProvider,
            "target": target, "backend": backend, "region": region, "publicDir": publicDir,
            "gcpProject": gcpProject, "serviceName": serviceName, "repoVisibility": repoVisibility,
            "subProvider": subProvider, "tiers": tiers, "trialDays": trialDays,
            "emailProvider": emailProvider, "fromEmail": fromEmail, "preset": preset
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    func loadConfig() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        func get(_ k: String, _ cur: String) -> String { (d[k]?.isEmpty == false) ? d[k]! : cur }
        name = get("name", name); parent = get("parent", parent); buildModel = get("buildModel", buildModel)
        pitch = d["pitch"] ?? pitch; features = d["features"] ?? features
        auth = get("auth", auth); pay = get("pay", pay); aiProvider = get("aiProvider", aiProvider)
        target = get("target", target); backend = get("backend", backend); region = get("region", region)
        publicDir = get("publicDir", publicDir); gcpProject = d["gcpProject"] ?? gcpProject
        serviceName = get("serviceName", serviceName); repoVisibility = get("repoVisibility", repoVisibility)
        subProvider = get("subProvider", subProvider); tiers = get("tiers", tiers); trialDays = get("trialDays", trialDays)
        emailProvider = get("emailProvider", emailProvider); fromEmail = get("fromEmail", fromEmail)
        preset = get("preset", preset)
    }

    // ---- presets ----
    func applyPreset(_ p: String) {
        preset = p
        switch p {
        case "Property rentals (KSA)":
            pitch = "Rental property management for Saudi landlords — leases, rent collection, and maintenance in one place"
            features = "Property & unit directory with photos\nLease contracts (Ejar-ready fields, Hijri + Gregorian dates)\nRent collection via payment links (mada / Apple Pay)\nAutomatic late-payment reminders (SMS/WhatsApp)\nMaintenance requests with photo upload + vendor assignment\nOwner dashboard: occupancy, collections, expiring leases\nArabic + English interface (RTL)"
            tiers = "Starter — 99 SAR/mo (10 units)\nPortfolio — 249 SAR/mo (50 units)\nEnterprise — 699 SAR/mo (unlimited + owner portals)"
        case "Restaurant QR menu":
            pitch = "QR menus and table ordering for restaurants and cafés — guests scan, order, and pay from their phone"
            features = "Menu builder with photos, variants, and modifiers (Arabic + English)\nQR code per table; dine-in, pickup, and delivery modes\nGuest ordering page (no app install) with mada / Apple Pay / STC Pay\nLive kitchen order screen with statuses\nDaily sales dashboard + best-sellers\nVAT-ready receipts (ZATCA QR)\nHappy-hour scheduling and item availability toggles"
            tiers = "Solo — 79 SAR/mo (1 branch)\nChain — 199 SAR/mo (5 branches)\nFranchise — 499 SAR/mo (unlimited + API)"
        case "Clinic bookings":
            pitch = "Appointments and patient records for private clinics — booking, reminders, and visit notes without the paperwork"
            features = "Public booking page per doctor with real-time slots\nPatient records: visits, notes, attachments, allergies\nSMS/WhatsApp appointment reminders (cuts no-shows)\nWalk-in queue screen for the waiting room\nInvoices with VAT + insurance claim export\nStaff roles: doctor, reception, admin\nArabic + English, fully RTL"
            tiers = "Solo doctor — 149 SAR/mo\nClinic — 349 SAR/mo (5 practitioners)\nPolyclinic — 899 SAR/mo (unlimited + multi-branch)"
        case "Umrah trip organizer":
            pitch = "Group trip management for Umrah operators — packages, pilgrim records, payments, and live coordination"
            features = "Package builder: hotels, transport, dates, pricing\nPilgrim registration with passport/visa document upload\nInstallment payment plans with payment links\nGroup manifest: rooming lists, bus assignments\nWhatsApp broadcast to the group (gate changes, schedules)\nExpense tracking per trip + profit report\nArabic-first interface"
            tiers = "Starter — 199 SAR/mo (2 active groups)\nOperator — 499 SAR/mo (10 groups)\nAgency — 1,199 SAR/mo (unlimited + sub-agents)"
        case "Real-estate CRM":
            pitch = "A deals CRM for real-estate brokers in the Gulf — listings, leads, viewings, and commissions in one pipeline"
            features = "Listings with photos, map location, and owner details\nLead capture from WhatsApp / web forms with auto-assignment\nPipeline board: new → viewing → offer → closed\nViewing scheduler with reminders\nCommission calculator + closed-deals report\nOwner/landlord portal with offer updates\nArabic + English (RTL)"
            tiers = "Agent — 99 SAR/mo (1 seat)\nOffice — 299 SAR/mo (10 seats)\nBrokerage — 699 SAR/mo (unlimited + team analytics)"
        case "HR & payroll (KSA)":
            pitch = "HR and payroll for Saudi SMEs — contracts, GOSI, leave, and WPS payroll files without spreadsheets"
            features = "Employee records: contracts, iqama/ID expiry alerts\nPayroll runs with GOSI calculation and payslips\nWPS-compatible bank file export (mudad-style)\nLeave requests + balances (annual, sick, Hajj)\nEnd-of-service (EOS) benefit calculator per Saudi labor law\nAttendance import + overtime rules\nSaudization (Nitaqat) headcount dashboard"
            tiers = "Starter — 149 SAR/mo (10 employees)\nBusiness — 399 SAR/mo (50 employees)\nCorporate — 999 SAR/mo (unlimited + multi-entity)"
        case "WhatsApp storefront":
            pitch = "A storefront that sells where Gulf customers already are — catalog, checkout, and order updates over WhatsApp"
            features = "Product catalog page with Arabic + English descriptions\nOne-tap \"Order on WhatsApp\" with pre-filled cart message\nPayment links (mada / STC Pay / Apple Pay) sent in-chat\nOrder tracker: new → confirmed → out for delivery\nCash-on-delivery support with driver reconciliation\nAbandoned-cart WhatsApp nudges\nInstagram-bio-ready store link"
            tiers = "Seller — 49 SAR/mo (100 orders)\nShop — 149 SAR/mo (1,000 orders)\nBrand — 399 SAR/mo (unlimited + API)"
        case "Quran & tutoring academy":
            pitch = "Run a Quran memorization or tutoring academy online — sessions, hifz progress, and parent reports"
            features = "Student profiles with level and goals\nSession scheduling (1:1 and halaqa groups) with Zoom/Meet links\nHifz progress tracker: surah/juz, revision cycles, tajweed notes\nParent portal with weekly progress reports\nTeacher payouts based on delivered sessions\nMonthly subscriptions with family discounts\nArabic-first, Hijri calendar aware"
            tiers = "Teacher — 69 SAR/mo (20 students)\nAcademy — 199 SAR/mo (150 students)\nInstitute — 499 SAR/mo (unlimited + branches)"
        case "Event ticketing":
            pitch = "Ticketing for events in the Gulf — weddings, conferences, and shows with QR check-in and Arabic invites"
            features = "Event pages with Arabic + English details\nTicket tiers, promo codes, and seat/table assignment\nPayment via mada / Apple Pay / STC Pay\nQR ticket delivery over WhatsApp + email\nDoor check-in app with live attendance count\nGuest-list import for private events (weddings)\nPost-event analytics + attendee export"
            tiers = "Organizer — 99 SAR/mo + 2 SAR/ticket\nPro — 299 SAR/mo + 1 SAR/ticket\nVenue — 799 SAR/mo (unlimited events)"
        case "Charity & zakat":
            pitch = "Donation and zakat campaign management for charities — collect, track, and report with full transparency"
            features = "Campaign pages with progress bars (Arabic + English)\nOne-time + recurring donations (mada / Apple Pay / STC Pay)\nZakat calculator that feeds straight into checkout\nAutomatic donation receipts (VAT-exempt format)\nRamadan mode: daily giving + iftar sponsorships\nDonor CRM with giving history + gift-aid style reports\nBoard-ready transparency reports per campaign"
            tiers = "Small charity — 149 SAR/mo\nFoundation — 399 SAR/mo (unlimited campaigns)\nEnterprise — custom (multi-org + audits)"
        case "Tadawul paper trading (AI)":
            pitch = "Risk-free paper trading for the Saudi stock market — practice on live Tadawul prices with an AI coach explaining every move"
            features = "Virtual portfolio with 100k SAR starting balance (delayed Tadawul quotes)\nBuy/sell simulator with real tickers, order types, and TASI index tracking\nAI trade coach: explains each stock, flags risky trades, and reviews your week\nShariah-compliance badge on every stock (halal screening)\nLeaderboards and monthly trading competitions\nLearning path: candlesticks, dividends, sukuk vs stocks (Arabic + English)\nWatchlists with price alerts over WhatsApp/email\nPerformance analytics vs TASI benchmark"
            tiers = "Learner — 0 SAR (1 portfolio, delayed data)\nTrader — 89 SAR/mo (AI coach + competitions)\nPro — 249 SAR/mo (multiple portfolios + advanced analytics + API)"
        case "AI web scraping service":
            pitch = "AI-powered web scraping as a service — customers describe the data they want in plain language and get clean, structured results on a schedule"
            features = "Plain-language scrape builder: paste a URL, describe the data, AI writes the extractor\nSelf-healing scrapers: AI re-maps selectors when a site changes layout\nScheduled runs (hourly/daily/weekly) with diff detection — get only what changed\nClean output: CSV, JSON, Google Sheets sync, and webhook delivery\nProxy rotation + polite rate limiting built in (respects robots.txt)\nPre-built recipes: e-commerce prices, real-estate listings, job posts, competitor monitoring\nUsage-based credits with a live cost estimator\nAPI + Zapier/Make integration for pipelines"
            tiers = "Starter — 0 SAR (2 scrapers, 100 pages/mo)\nGrowth — 149 SAR/mo (20 scrapers, 10k pages)\nScale — 449 SAR/mo (unlimited scrapers, 100k pages + API)"
        case "AI tool":
            pitch = "An AI assistant that <does one job> for <audience> in seconds"
            features = "Landing page with live demo\nPrompt workspace (input → AI result)\nHistory of past generations\nUsage credits per plan\nAccount & billing page"
            tiers = "Free — 0 SAR (20 credits/mo)\nPro — 79 SAR/mo (2,000 credits)\nTeam — 249 SAR/mo (10,000 credits, 5 seats)"
        case "Marketplace":
            pitch = "A marketplace connecting <sellers> with <buyers> in KSA"
            features = "Public listings with search + filters\nSeller onboarding & profile pages\nListing creation with photos\nOrders + status tracking\nAdmin approval dashboard\nReviews & ratings"
            tiers = "Free — 0 SAR (browse & buy)\nSeller — 99 SAR/mo (unlimited listings)\nSeller Pro — 299 SAR/mo (featured placement + analytics)"
        case "Booking & appointments":
            pitch = "Online booking for <service providers> — customers book, pay, and get reminders"
            features = "Public booking page per provider\nCalendar with availability rules\nDeposits / prepayment at booking\nSMS + email reminders\nStaff & services management\nNo-show and cancellation policies"
            tiers = "Solo — 49 SAR/mo (1 calendar)\nStudio — 149 SAR/mo (5 staff)\nChain — 399 SAR/mo (unlimited, multi-branch)"
        case "Invoicing & finance":
            pitch = "ZATCA-friendly invoicing for freelancers and small businesses in KSA"
            features = "Client directory\nInvoice editor with VAT + QR (ZATCA phase 1)\nPayment links (pay invoice online)\nExpense tracking\nMonthly reports & export\nRecurring invoices"
            tiers = "Starter — 0 SAR (3 invoices/mo)\nBusiness — 69 SAR/mo (unlimited + payment links)\nFirm — 199 SAR/mo (multi-user + API)"
        case "Courses & learning":
            pitch = "Sell online courses with lessons, quizzes, and certificates"
            features = "Course catalog + landing pages\nVideo lessons with progress tracking\nQuizzes and completion certificates\nStudent dashboard\nInstructor analytics\nDrip content by week"
            tiers = "Student — free (enrolled courses)\nCreator — 99 SAR/mo (3 courses)\nAcademy — 299 SAR/mo (unlimited + team)"
        case "Team dashboard":
            pitch = "An internal ops dashboard that gives <team> one place to track <workflow>"
            features = "SSO login (Google)\nKPI overview with charts\nRecords table with filters + bulk actions\nRole-based access (admin/member/viewer)\nAudit log\nCSV import/export"
            tiers = "Team — 149 SAR/mo (10 seats)\nBusiness — 399 SAR/mo (50 seats + SSO)\nEnterprise — contact us"
        default:
            break   // Custom: leave the user's text alone
        }
        if p != "Custom" { out("Applied the \"\(p)\" preset — tweak the pitch, features, and tiers to make it yours.") }
    }

    // ---- launch checklist: live ✓/✗ progress derived from the project folder ----
    struct CheckItem: Identifiable { let id: String; let label: String; let done: Bool }

    var checklist: [CheckItem] {
        let dir = appDir
        let scaffolded = FS.exists(dir + "/main.wasp") || FS.exists(dir + "/package.json")
            || FS.dirs(dir).contains(where: { FS.base($0) == "app" && FS.exists($0 + "/main.wasp") })
        let gitCfg = FS.read(dir + "/.git/config") ?? ""
        let wf = dir + "/.github/workflows"
        let hasWorkflow = FS.isDir(wf) && !((try? FileManager.default.contentsOfDirectory(atPath: wf))?.isEmpty ?? true)
        let deployCfg = FS.exists(dir + "/vercel.json") || FS.exists(dir + "/firebase.json") || FS.exists(dir + "/Dockerfile")
        return [
            CheckItem(id: "folder", label: "App folder", done: FS.isDir(dir)),
            CheckItem(id: "vision", label: "Vision saved", done: FS.exists(dir + "/VISION.md")),
            CheckItem(id: "code",   label: "App scaffolded", done: scaffolded),
            CheckItem(id: "github", label: "On GitHub", done: gitCfg.contains("github.com")),
            CheckItem(id: "ci",     label: "CI/CD", done: hasWorkflow),
            CheckItem(id: "deploy", label: "Deploy config", done: deployCfg),
            CheckItem(id: "subs",   label: "Billing spec", done: FS.exists(dir + "/SUBSCRIPTIONS.md")),
            CheckItem(id: "ga",     label: "Analytics", done: FS.exists(dir + "/ANALYTICS.md"))
        ]
    }

    // ---- ⚡ instant mode: one click, Claude orchestrates the whole lifecycle ----

    /// The Open SaaS template repo — the MANDATORY base for every build, whatever the use case.
    static let templateRepo = "https://github.com/wasp-lang/open-saas"

    /// The exact stack the ⚡ instant build will use — shown to the user BEFORE anything runs.
    func stackSummary() -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        var lines: [String] = []
        lines.append("Template   Open SaaS — \(Self.templateRepo) (always, every use case)")
        lines.append("Framework  Wasp · React · Node.js · Prisma · PostgreSQL · Tailwind CSS")
        lines.append("App        \(n.isEmpty ? "my-saas" : n)  →  \(appDir)")
        lines.append("Preset     \(preset)")
        lines.append("Auth       \(auth)")
        lines.append("Payments   \(pay)")
        lines.append("AI layer   \(aiProvider)")
        lines.append("Analytics  Google Analytics 4 — always on, cookie-consent gated (every use case)")
        var deployLine = "Deploy     \(target) · backend: \(backend)"
        if target == "Cloud Run" { deployLine += " · \(region)" }
        lines.append(deployLine)
        lines.append("GitHub     \(repoVisibility.lowercased()) repo + Actions CI/CD")
        lines.append("Billing    \(subProvider) · \(trialDays)-day trial · email via \(emailProvider)")
        lines.append("Model      \(buildModel)")
        return lines.joined(separator: "\n")
    }

    func buildEverything() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = parent.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, FS.isDir(p) else { app?.alert("Missing info", "Set a valid parent folder and app name first."); return }
        guard !pitch.trimmingCharacters(in: .whitespaces).isEmpty else {
            app?.alert("Add a pitch", "Write the one-line pitch (or pick a preset) so Claude knows what to build."); return
        }
        // Show the exact stack and get an explicit OK before anything is written or launched.
        let confirm = NSAlert()
        confirm.messageText = "⚡ Instant build — confirm your stack"
        confirm.informativeText = stackSummary()
            + "\n\nClaude will scaffold Open SaaS, build every feature, wire billing + email, create the GitHub repo, and deploy — in one run."
        confirm.addButton(withTitle: "Build")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else {
            out("Instant build cancelled — adjust the stack above and press ⚡ again when ready.")
            return
        }
        try? FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        // Write EVERY spec up front so one Claude session has the full picture.
        FS.write(appDir + "/PLAYBOOK.md", playbookDoc())
        FS.write(appDir + "/VISION.md", visionDoc())
        let pk = paymentKey()
        if pk != "none" { FS.write(appDir + "/PAYMENTS.md", paymentSpec(pk)) }
        FS.write(appDir + "/DEPLOY.md", deploySpec())
        FS.write(appDir + "/SUBSCRIPTIONS.md", subscriptionSpec())
        FS.write(appDir + "/EMAIL.md", emailSpec())
        FS.write(appDir + "/ANALYTICS.md", analyticsSpec())
        FS.write(appDir + "/.env.analytics.example", analyticsEnvExample())
        FS.write(appDir + "/.env.subscriptions.example", subEnvExample())
        if aiEnabled() {
            FS.write(appDir + "/AI.md", aiSpec())
            FS.write(appDir + "/.env.ai.example", aiEnvExample())
        }
        out("Wrote PLAYBOOK.md, VISION.md, DEPLOY.md, SUBSCRIPTIONS.md, EMAIL.md, ANALYTICS.md" + (aiEnabled() ? ", AI.md" : "") + (pk != "none" ? ", PAYMENTS.md" : "") + " into \(appDir)")
        let prompt = "You are building a complete SaaS end-to-end in this folder. FIRST read PLAYBOOK.md — it is the battle-tested production sequence (accounts first, deploy the skeleton early, known pitfalls with exact fixes, Namecheap domain linking); follow its phase order and its rules throughout. Then read VISION.md, PAYMENTS.md (if present), AI.md (if present), SUBSCRIPTIONS.md, EMAIL.md, ANALYTICS.md and DEPLOY.md, then do ALL of it in order: "
            + "(1) If the app is not scaffolded yet (no main.wasp/package.json), scaffold the Open SaaS template (\(Self.templateRepo)) here with `wasp new \(n) -t saas` — the wasp CLI is available as `wasp` (if the folder having these .md files blocks `wasp new`, scaffold in a temp dir and move the result in, keeping the .md files). Open SaaS is the MANDATORY base for EVERY use case — never substitute Next.js, plain Vite, CRA, or any other starter. "
            + "(2) Build the product in VISION.md: auth, every feature/page, premium non-templated UI. If AI.md is present, add its multi-provider router (src/server/ai/router.ts) with the best→cheapest priority ladder and route EVERY AI feature through it. Wire Google Analytics 4 per ANALYTICS.md — it is mandatory for every use case: consent-gated gtag via Open SaaS's cookie-consent banner, the required events, and the admin-dashboard stats job (env ids stubbed, never real). "
            + "(3) Implement the subscription billing + subscriber email described in SUBSCRIPTIONS.md and EMAIL.md, with env keys stubbed in .env.server (never real secrets). "
            + "(4) Initialize git, create a \(repoVisibility.lowercased()) GitHub repo with `gh`, and add the GitHub Actions workflow per DEPLOY.md. "
            + "(5) Deploy to \(target) per DEPLOY.md and report the live URL. "
            + "Work through this as one continuous mission; verify each stage works before the next; ask me only when a decision is truly mine (accounts, payments, spend)."
            + skillsHint
        app?.launch(folder: appDir, startupPrompt: prompt, modelOverride: buildModel)
        out("⚡ Instant build started — Claude is orchestrating scaffold → build → billing → GitHub → deploy in the Workspace.")
    }

    /// Nudge Claude to actually USE the bundled skills that fit the task. Appended to every
    /// build prompt so the SaaS gets premium UI, correct deploy, and correct billing.
    var skillsHint: String {
        " Before you start, check which Claude skills are installed and USE every one that fits: "
        + "design-taste-frontend / high-end-visual-design / industrial-brutalist-ui for premium, non-templated UI; "
        + "imagegen-frontend-web / imagegen-frontend-mobile / brandkit for visuals and brand; "
        + "image-to-code for turning designs into code; full-output-enforcement so nothing is left as a stub; "
        + "cloud-deployment when deploying; subscription-billing for payments and subscriber email; "
        + "ai-integration for the multi-provider AI router (OpenRouter + Groq + free providers, best→cheapest fallback); "
        + "karpathy-guidelines / gpt-taste for clean code. Pick the relevant skills for each step and apply them."
    }

    // ============================================================ VISION
    func paymentKey() -> String {
        if pay.hasPrefix("Tap") { return "tap" }
        if pay.hasPrefix("Moyasar") { return "moyasar" }
        if pay.hasPrefix("Stripe") { return "stripe" }
        if pay.hasPrefix("Lemon") { return "lemonsqueezy" }
        if pay.hasPrefix("Polar") { return "polar" }
        return "none"
    }

    func checkWasp() {
        if Shell.shared.onPath("wasp") { out("Wasp CLI found on PATH. You can create the app."); return }
        out("Wasp CLI not found.")
        let a = NSAlert()
        a.messageText = "Install the Wasp CLI now?"
        a.informativeText = "Runs: curl -sSL https://get.wasp.sh/installer.sh | sh"
        a.addButton(withTitle: "Install"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        app?.runInWorkspace("curl -sSL https://get.wasp.sh/installer.sh | sh", cwd: Paths.home, note: "Installing the Wasp CLI…")
        out("Launched the Wasp installer in a Workspace tab. When it finishes, create the app.")
    }

    func createApp() {
        let p = parent.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, FS.isDir(p) else { app?.alert("Missing info", "Set a valid parent folder and app name first."); return }
        if FS.isDir(appDir) { app?.alert("Already exists", "That app folder already exists:\n\(appDir)"); return }
        guard Shell.shared.onPath("wasp") else { checkWasp(); return }
        let a = NSAlert()
        a.messageText = "Create a new Open SaaS app?"
        a.informativeText = "\(appDir)\n\nRuns 'wasp new \(n) -t saas' — scaffolds the Open SaaS template (\(Self.templateRepo))."
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        app?.runInWorkspace("wasp new \(n) -t saas", cwd: p, note: "Scaffolding Open SaaS — follow any prompts…")
        out("Scaffolding started in a Workspace tab. When it's done, run 'Save vision + build'.")
    }

    func build() {
        guard FS.isDir(appDir) else { app?.alert("Not scaffolded", "App folder not found. Create the app first:\n\(appDir)"); return }
        guard !pitch.trimmingCharacters(in: .whitespaces).isEmpty else { app?.alert("Add a pitch", "Add a one-line pitch first so Claude understands the vision."); return }
        FS.write(appDir + "/PLAYBOOK.md", playbookDoc())
        FS.write(appDir + "/VISION.md", visionDoc())
        out("Wrote PLAYBOOK.md + VISION.md into \(appDir)")
        let pk = paymentKey()
        if pk != "none" {
            FS.write(appDir + "/PAYMENTS.md", paymentSpec(pk))
            out("Wrote PAYMENTS.md (verified \(pay) integration spec).")
        }
        if aiEnabled() {
            FS.write(appDir + "/AI.md", aiSpec())
            FS.write(appDir + "/.env.ai.example", aiEnvExample())
            out("Wrote AI.md + .env.ai.example (integrated multi-provider AI router).")
        }
        FS.write(appDir + "/ANALYTICS.md", analyticsSpec())
        FS.write(appDir + "/.env.analytics.example", analyticsEnvExample())
        out("Wrote ANALYTICS.md + .env.analytics.example (Google Analytics 4 — mandatory).")
        let prompt = "FIRST read PLAYBOOK.md in this folder — the battle-tested production sequence and pitfall list; follow its phase order throughout. Then read VISION.md (and PAYMENTS.md / AI.md if present) in this folder and build the SaaS it describes on top of the Open SaaS template (\(Self.templateRepo)). If the folder is not an Open SaaS app yet (no main.wasp), scaffold it FIRST with `wasp new -t saas` — Open SaaS is the mandatory base for every use case; never substitute another starter. If AI.md is present, add its multi-provider router (src/server/ai/router.ts) and route every AI feature through it. Wire Google Analytics 4 per ANALYTICS.md — mandatory for every use case (consent-gated gtag, required events, admin stats job; env ids stubbed). Start by summarizing the plan and asking me to confirm before major changes." + skillsHint
        app?.launch(folder: appDir, startupPrompt: prompt, modelOverride: buildModel)
        out("Opened a Claude session in the Workspace to build it.")
    }

    func run() {
        guard FS.isDir(appDir) else { app?.alert("Not scaffolded", "App folder not found. Create the app first."); return }
        // Two tabs, like a real dev setup: the dev database first, then migrate + start.
        app?.runInWorkspace("wasp start db", cwd: appDir, note: "Starting the dev database (leave this running)…")
        app?.runInWorkspace("sleep 4; wasp db migrate-dev && wasp start", cwd: appDir, note: "Migrating + starting the app — it opens on http://localhost:3000…")
        out("Started the dev DB + the app in two Workspace tabs.")
    }

    func showPaymentGuide() {
        let key = paymentKey()
        out(paymentSpec(key))
        NSWorkspace.shared.open(URL(string: paymentDocsUrl(key))!)
    }

    // ============================================================ DEPLOY
    private func targetTool() -> (exe: String, install: String, login: String) {
        switch target {
        case "Firebase Hosting":
            return ("firebase", "npm install -g firebase-tools", "firebase login")
        case "Cloud Run":
            let install = Shell.shared.onPath("brew")
                ? "brew install --cask google-cloud-sdk"
                : "echo 'Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install  (then run: gcloud init)'"
            return ("gcloud", install, "gcloud auth login")
        default:
            return ("vercel", "npm install -g vercel", "vercel login")
        }
    }

    func checkDeployTools() {
        let sh = Shell.shared
        func mark(_ e: String) -> String { sh.onPath(e) ? "OK" : "—" }
        out("Tools:  git \(mark("git"))   gh \(mark("gh"))   node \(mark("node"))   npm \(mark("npm"))   firebase \(mark("firebase"))   vercel \(mark("vercel"))   gcloud \(mark("gcloud"))   docker \(mark("docker"))")
        let t = targetTool()
        out(sh.onPath(t.exe) ? "\(t.exe) is ready for \(target)." : "\(t.exe) missing — click 'Install CLI'.")
    }

    func installDeployCLI() {
        let t = targetTool()
        if Shell.shared.onPath(t.exe) { out("\(t.exe) already installed."); return }
        app?.runInWorkspace(t.install, cwd: Paths.home, note: "Installing the \(target) CLI…")
        out("Installing \(t.exe) in a Workspace tab.")
    }

    /// One beginner-friendly action: install the host's CLI if missing, then sign in
    /// (and select the project for Cloud Run) — all in a single Workspace terminal.
    func connectHost() {
        guard deployDirValid() else { return }
        let t = targetTool()
        let installStep = Shell.shared.onPath(t.exe) ? "echo '\(t.exe) already installed.'" : t.install
        var cmd = "\(installStep) && \(t.login)"
        if target == "Cloud Run", !gcpProject.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " && gcloud config set project \(gcpProject.trimmingCharacters(in: .whitespaces))"
        }
        app?.runInWorkspace(cmd, cwd: deployDir(), note: "Connecting to \(target) — installing the CLI (if needed) and signing in. A browser may open.")
        out("Connecting to \(target). Finish any sign-in in the Workspace tab, then come back for step 2.")
    }

    func deployLogin() {
        guard deployDirValid() else { return }
        let t = targetTool()
        var cmd = t.login
        if target == "Cloud Run", !gcpProject.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " && gcloud config set project \(gcpProject.trimmingCharacters(in: .whitespaces))"
        }
        app?.runInWorkspace(cmd, cwd: deployDir(), note: "Sign in to \(target)… a browser may open.")
        out("Launched \(target) login in a Workspace tab.")
    }

    /// Write the target's config files if they're not already present (so 'Go live' just works).
    private func ensureDeployConfig() {
        let dir = deployDir()
        switch target {
        case "Firebase Hosting":
            if !FS.exists(dir + "/firebase.json") { FS.write(dir + "/firebase.json", firebaseJson()); out("Wrote firebase.json") }
            if !gcpProject.trimmingCharacters(in: .whitespaces).isEmpty, !FS.exists(dir + "/.firebaserc") {
                FS.write(dir + "/.firebaserc", firebaseRc()); out("Wrote .firebaserc")
            }
        case "Cloud Run":
            if !FS.exists(dir + "/Dockerfile") { FS.write(dir + "/Dockerfile", dockerfile()); out("Wrote Dockerfile") }
            if !FS.exists(dir + "/.dockerignore") { FS.write(dir + "/.dockerignore", "node_modules\nnpm-debug.log\n.git\n.env*\n") }
        default:
            if !FS.exists(dir + "/vercel.json") { FS.write(dir + "/vercel.json", vercelJson()); out("Wrote vercel.json") }
        }
    }

    /// The folder deploy/billing actions operate on. NEVER falls back to the home folder —
    /// pushing ~ to GitHub or writing a Dockerfile into it would be catastrophic. The parent
    /// is only used when it clearly IS a project itself (user pointed us at existing code).
    private func deployDir() -> String {
        if FS.isDir(appDir) { return appDir }
        let p = (parent.trimmingCharacters(in: .whitespaces) as NSString).standardizingPath
        let home = (Paths.home as NSString).standardizingPath
        let looksLikeProject = FS.exists(p + "/package.json") || FS.exists(p + "/main.wasp")
            || FS.exists(p + "/index.html") || FS.isDir(p + "/.git")
        if p != home && FS.isDir(p) && looksLikeProject { return p }
        return ""
    }
    private func deployDirValid() -> Bool {
        guard !deployDir().isEmpty else {
            app?.alert("No project yet", "Create your app first (Stage 1), or point 'Parent folder' at an existing project (a folder with package.json / .git). To protect you, these actions never run on your home folder.")
            return false
        }
        return true
    }

    func scaffoldDeploy() {
        guard deployDirValid() else { return }
        let dir = deployDir()
        var wrote: [String] = []
        switch target {
        case "Firebase Hosting":
            FS.write(dir + "/firebase.json", firebaseJson()); wrote.append("firebase.json")
            if !gcpProject.trimmingCharacters(in: .whitespaces).isEmpty {
                FS.write(dir + "/.firebaserc", firebaseRc()); wrote.append(".firebaserc")
            }
        case "Cloud Run":
            FS.write(dir + "/Dockerfile", dockerfile()); wrote.append("Dockerfile")
            FS.write(dir + "/.dockerignore", "node_modules\nnpm-debug.log\n.git\n.env*\n"); wrote.append(".dockerignore")
        default:
            FS.write(dir + "/vercel.json", vercelJson()); wrote.append("vercel.json")
        }
        FS.write(dir + "/DEPLOY.md", deploySpec()); wrote.append("DEPLOY.md")
        out("Wrote \(wrote.joined(separator: ", ")) into \(dir)")
        out("Review the config, then 'Deploy now'. Or 'Build with Claude' to wire the backend + config end-to-end.")
    }

    func deployNow() {
        guard deployDirValid() else { return }
        let t = targetTool()
        guard Shell.shared.onPath(t.exe) else { app?.alert("Not connected", "Run step 1 (Connect your host) first — it installs the \(t.exe) CLI and signs you in."); return }
        ensureDeployConfig()   // write config files if missing so 'Go live' just works
        let dir = deployDir()
        let cmd: String
        switch target {
        case "Firebase Hosting":
            cmd = "firebase deploy"
        case "Cloud Run":
            let proj = gcpProject.trimmingCharacters(in: .whitespaces)
            let svc = serviceName.trimmingCharacters(in: .whitespaces).isEmpty ? "api" : serviceName.trimmingCharacters(in: .whitespaces)
            cmd = "gcloud run deploy \(svc) --source . --region \(region) --allow-unauthenticated"
                + (proj.isEmpty ? "" : " --project \(proj)")
        default:
            cmd = "vercel --prod"
        }
        app?.runInWorkspace(cmd, cwd: dir, note: "Deploying to \(target)…")
        out("Deploying to \(target) in a Workspace tab. Watch for the live URL.")
    }

    func buildDeployWithClaude() {
        guard deployDirValid() else { return }
        let dir = deployDir()
        FS.write(dir + "/DEPLOY.md", deploySpec())
        let prompt = "Read DEPLOY.md in this folder and get this project deployed to \(target) with the specified backend. This is an Open SaaS (Wasp) app (\(Self.templateRepo)) — use `wasp build` outputs (static client + server Dockerfile) rather than assuming a plain SPA. Set up the config, wire the backend/database, handle env vars/secrets safely, then run the deploy and report the live URL. Confirm the plan before any paid or destructive step." + skillsHint
        app?.launch(folder: dir, startupPrompt: prompt, modelOverride: buildModel)
        out("Wrote DEPLOY.md and opened Claude in the Workspace to deploy it.")
    }

    func openDeployGuide() {
        let path = writeGuide("CLOUD-DEPLOYMENT.md", cloudGuide())
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // ---- GitHub: private repo + Actions CI/CD (the core deploy location) ----
    private func ensureGitignore() {
        let p = deployDir() + "/.gitignore"
        guard !FS.exists(p) else { return }
        FS.write(p, "node_modules\n.env\n.env.*\n!.env.example\n!.env.subscriptions.example\n!.env.analytics.example\n!.env.ai.example\ndist\nbuild\n.next\n.DS_Store\n.firebase\n.vercel\n")
        out("Wrote .gitignore (keeps secrets + build output out of git).")
    }

    func pushToGitHub() {
        guard deployDirValid() else { return }
        let dir = deployDir()
        let n = name.trimmingCharacters(in: .whitespaces)
        guard Shell.shared.onPath("gh") else {
            let install = Shell.shared.onPath("brew")
                ? "brew install gh && gh auth login"
                : "echo 'Install the GitHub CLI: https://cli.github.com  — then run: gh auth login'"
            app?.runInWorkspace(install, cwd: dir, note: "Installing the GitHub CLI (gh)…")
            out("gh not found — installing it. After 'gh auth login', click 'Create repo + push' again.")
            return
        }
        ensureGitignore()
        let vis = repoVisibility == "Public" ? "--public" : "--private"
        // init → commit → create the repo (or reuse) → push. Safe to re-run.
        let cmd = "git rev-parse --git-dir >/dev/null 2>&1 || git init -b main; "
            + "git add -A; git commit -m 'Initial commit' 2>/dev/null || echo '(nothing new to commit)'; "
            + "gh repo view >/dev/null 2>&1 && git push -u origin HEAD || gh repo create \(TerminalLauncher.shellQuote(n)) \(vis) --source . --remote origin --push"
        app?.runInWorkspace(cmd, cwd: dir, note: "Creating a \(repoVisibility.lowercased()) GitHub repo and pushing the project…")
        out("Pushing to a \(repoVisibility.lowercased()) GitHub repo. If it asks you to authenticate, run 'gh auth login' and retry.")
    }

    func addGitHubActions() {
        guard deployDirValid() else { return }
        let dir = deployDir()
        let wf = ghWorkflow()
        let wfDir = dir + "/.github/workflows"
        try? FileManager.default.createDirectory(atPath: wfDir, withIntermediateDirectories: true)
        FS.write(wfDir + "/" + wf.file, wf.content)
        FS.write(dir + "/GITHUB-ACTIONS.md", wf.doc)
        out("Wrote .github/workflows/\(wf.file) + GITHUB-ACTIONS.md")
        out("Add these repo secrets (GitHub → Settings → Secrets → Actions, or `gh secret set`):")
        out("  " + wf.secrets.joined(separator: ", "))
        out("Then every push to main auto-deploys to \(target).")
    }

    /// A correct GitHub Actions workflow for the selected target.
    func ghWorkflow() -> (file: String, content: String, secrets: [String], doc: String) {
        switch target {
        case "Firebase Hosting":
            let proj = gcpProject.trimmingCharacters(in: .whitespaces).isEmpty ? "your-project-id" : gcpProject.trimmingCharacters(in: .whitespaces)
            let content = """
            name: Deploy to Firebase Hosting
            on:
              push:
                branches: [main]
            jobs:
              build_and_deploy:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: actions/setup-node@v4
                    with:
                      node-version: 20
                  - run: npm ci
                  - run: npm run build --if-present
                  - uses: FirebaseExtended/action-hosting-deploy@v0
                    with:
                      repoToken: ${{ secrets.GITHUB_TOKEN }}
                      firebaseServiceAccount: ${{ secrets.FIREBASE_SERVICE_ACCOUNT }}
                      channelId: live
                      projectId: \(proj)
            """
            let doc = """
            # GitHub Actions → Firebase Hosting

            Every push to `main` builds and deploys to Firebase Hosting.

            ## Required secret
            - `FIREBASE_SERVICE_ACCOUNT` — a service-account JSON with the Firebase Hosting Admin role.

            Fastest way to generate it (auto-adds the secret to your repo):
            ```bash
            firebase init hosting:github
            ```
            Or manually: Google Cloud console → IAM → Service Accounts → create key (JSON) → paste the whole JSON as the secret value.

            `GITHUB_TOKEN` is provided automatically by Actions — you don't set it.

            ## No-service-account alternative (proven simpler)
            If the user already has a CI token (`firebase login:ci`, ideally stored in
            Claude Manager → Settings → Access & API keys), skip the service account:
            set a `FIREBASE_TOKEN` repo secret and replace the deploy step with
            `npx firebase-tools deploy --only hosting --non-interactive --token "$FIREBASE_TOKEN"`
            (project id comes from .firebaserc).

            ## Wasp projects (Open SaaS) — pitfalls that WILL fail the first run
            - Pin the CLI: `npm install -g @wasp.sh/wasp-cli@<same version as local>` — unpinned installs drift.
            - Wasp 0.24+ requires Node 24: `setup-node` with `node-version: 24`.
            - Build order: `wasp install && wasp build` in `app/`, then `npx vite build` in `app/`
              (client output lands in `app/.wasp/out/web-app/build`; copy it to the Hosting public dir).
            - The client build hard-fails without `REACT_APP_API_URL` in env — set it as a repo secret.
            """
            return ("deploy-firebase.yml", content, ["FIREBASE_SERVICE_ACCOUNT"], doc)

        case "Cloud Run":
            let proj = gcpProject.trimmingCharacters(in: .whitespaces).isEmpty ? "your-project-id" : gcpProject.trimmingCharacters(in: .whitespaces)
            let svc = serviceName.trimmingCharacters(in: .whitespaces).isEmpty ? "api" : serviceName.trimmingCharacters(in: .whitespaces)
            let content = """
            name: Deploy to Cloud Run
            on:
              push:
                branches: [main]
            jobs:
              deploy:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - id: auth
                    uses: google-github-actions/auth@v2
                    with:
                      credentials_json: ${{ secrets.GCP_SA_KEY }}
                  - uses: google-github-actions/setup-gcloud@v2
                  - name: Deploy
                    run: |
                      gcloud run deploy \(svc) \\
                        --source . \\
                        --region \(region) \\
                        --project \(proj) \\
                        --allow-unauthenticated
            """
            let doc = """
            # GitHub Actions → Cloud Run

            Every push to `main` builds from source and deploys to Cloud Run.

            ## Required secret
            - `GCP_SA_KEY` — service-account JSON with roles: Cloud Run Admin, Cloud Build Editor, Service Account User, Storage Admin.

            ```bash
            gcloud iam service-accounts keys create key.json --iam-account=deployer@\(proj).iam.gserviceaccount.com
            gh secret set GCP_SA_KEY < key.json   # then delete key.json
            ```
            Ensure the app listens on `$PORT` (8080) on 0.0.0.0.
            """
            return ("deploy-cloudrun.yml", content, ["GCP_SA_KEY"], doc)

        default: // Vercel
            let content = """
            name: Deploy to Vercel
            on:
              push:
                branches: [main]
            env:
              VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}
              VERCEL_PROJECT_ID: ${{ secrets.VERCEL_PROJECT_ID }}
            jobs:
              deploy:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: actions/setup-node@v4
                    with:
                      node-version: 20
                  - name: Install Vercel CLI
                    run: npm install -g vercel
                  - name: Pull Vercel environment
                    run: vercel pull --yes --environment=production --token=${{ secrets.VERCEL_TOKEN }}
                  - name: Build
                    run: vercel build --prod --token=${{ secrets.VERCEL_TOKEN }}
                  - name: Deploy
                    run: vercel deploy --prebuilt --prod --token=${{ secrets.VERCEL_TOKEN }}
            """
            let doc = """
            # GitHub Actions → Vercel

            Every push to `main` builds and promotes to Vercel production.

            ## Required secrets
            - `VERCEL_TOKEN` — create at https://vercel.com/account/tokens
            - `VERCEL_ORG_ID` and `VERCEL_PROJECT_ID` — run `vercel link` locally, then read them from `.vercel/project.json`.

            ```bash
            vercel link
            gh secret set VERCEL_TOKEN
            gh secret set VERCEL_ORG_ID --body "$(jq -r .orgId .vercel/project.json)"
            gh secret set VERCEL_PROJECT_ID --body "$(jq -r .projectId .vercel/project.json)"
            ```
            (Alternatively, connect the repo in the Vercel dashboard for zero-config deploys — but this workflow keeps GitHub as the source of truth.)
            """
            return ("deploy-vercel.yml", content, ["VERCEL_TOKEN", "VERCEL_ORG_ID", "VERCEL_PROJECT_ID"], doc)
        }
    }

    // ============================================================ SUBSCRIPTIONS
    func subKey() -> String {
        if subProvider.hasPrefix("Tap") { return "tap" }
        if subProvider.hasPrefix("Moyasar") { return "moyasar" }
        return "stripe"
    }

    func scaffoldSubscriptions() {
        guard deployDirValid() else { return }
        let dir = deployDir()
        FS.write(dir + "/SUBSCRIPTIONS.md", subscriptionSpec())
        FS.write(dir + "/EMAIL.md", emailSpec())
        FS.write(dir + "/.env.subscriptions.example", subEnvExample())
        out("Wrote SUBSCRIPTIONS.md, EMAIL.md and .env.subscriptions.example into \(dir)")
        out("Fill the keys, then 'Build with Claude' to implement the full billing + email flow.")
    }

    func buildSubsWithClaude() {
        guard deployDirValid() else { return }
        let dir = deployDir()
        FS.write(dir + "/SUBSCRIPTIONS.md", subscriptionSpec())
        FS.write(dir + "/EMAIL.md", emailSpec())
        let prompt = "Read SUBSCRIPTIONS.md and EMAIL.md in this folder and implement the full subscription infrastructure they describe (checkout, signed webhooks, entitlement checks, customer portal) plus the subscriber email flows (transactional + broadcast with unsubscribe). This is an Open SaaS (Wasp) app (\(Self.templateRepo)) — follow its conventions (main.wasp operations, Prisma entities, src/server) and its payments plumbing where it fits. Use the database as the source of truth. Summarize the plan, then build it incrementally and keep it runnable." + skillsHint
        app?.launch(folder: dir, startupPrompt: prompt, modelOverride: buildModel)
        out("Wrote the specs and opened Claude in the Workspace to build the subscription + email system.")
    }

    func openBillingDocs() {
        let url: String
        switch subKey() {
        case "tap": url = "https://developers.tap.company/"
        case "moyasar": url = "https://docs.moyasar.com/"
        default: url = "https://docs.stripe.com/billing/subscriptions/overview"
        }
        NSWorkspace.shared.open(URL(string: url)!)
    }

    // ============================================================ generators

    /// The production playbook — every lesson from real end-to-end builds
    /// (Page Byte, 2026-07), ordered for the FASTEST path to a production
    /// site. Written into every new project as PLAYBOOK.md.
    func playbookDoc() -> String {
        return """
        # Production Playbook — fastest correct sequence to a live SaaS

        Battle-tested order. Each phase unblocks the next; account/authorization
        steps come FIRST because they are the only steps that ever block for hours.
        Keys can trickle in later — the codebase must no-op gracefully when a key
        is missing (a feature without its key logs to console instead of failing).

        ## Phase 0 — Accounts & authorizations (do these before writing code)
        These block everything downstream and need the human. Fire them all at once:
        1. GitHub CLI: `gh auth login`, then IMMEDIATELY `gh auth refresh -h github.com -s workflow`
           (without the workflow scope, the FIRST push containing .github/workflows/ is rejected —
           this bit us in production; the default token never has it).
        2. Firebase: `firebase login:ci` in a REAL terminal (never works in non-TTY shells) →
           store the token. It can headlessly: create projects, create web apps, fetch sdkconfig,
           deploy hosting. It canNOT enable Auth (see Phase 4).
        3. Fly.io (if server hosting): `fly auth login` + card. Then set `send_metrics: false`
           in ~/.fly/config.yml or its stdout warnings corrupt wasp's JSON parsing.
        4. AI: at minimum a free Groq key (console.groq.com/keys) — free tier serves real traffic.
        5. Payments: create the Lemon Squeezy store NOW (self-serve, no approval gate) if
           international; Moyasar if KSA-local-only. Seller verification runs in the background
           while you build.
        6. Store every token/key in Claude Manager → Settings → Access & API keys — they inject
           into every terminal and every future project reuses them.

        ## Phase 1 — Scaffold (goal: `wasp start` green in 15 minutes)
        - `wasp new <name> -t saas` (Open SaaS is the mandatory base). If the target folder
          already has spec .md files, scaffold in a temp dir and move contents in.
        - Machine quirks that WILL appear: root-owned npm cache → `npm config set cache <writable>`;
          root-owned global prefix → install CLIs with `--prefix ~/.npm-global`; Wasp 0.24+ needs
          Node 24; no Docker → `brew install postgresql@17 && brew services start postgresql@17`
          and put DATABASE_URL in .env.server.
        - `wasp install && wasp db migrate-dev && wasp compile` must all pass before feature work.
        - If prisma migrate-dev hits "non-interactive not supported": hand-write the migration SQL
          under migrations/<timestamp>_name/migration.sql and apply with
          `DATABASE_URL=... npx prisma migrate deploy --schema .wasp/out/db/schema.prisma`.

        ## Phase 2 — Build the product (architecture rules that held up)
        - Firebase Auth means SKIPPING Wasp auth entirely: client Firebase Web SDK + an
          AuthContext; server = wasp `api()` REST endpoints with a `requireUser(req)` helper that
          verifies the Bearer ID token via firebase-admin and upserts the user by firebaseUid.
          This REST surface doubles as the public API (X-Api-Key auth) for Zapier/Make.
        - Dev fallback: accept `dev:<email>` bearer tokens when NODE_ENV=development — and keep
          accepting them even after Firebase gets configured, or local testing dies later.
        - firebase-admin verifies ID tokens with ONLY a project id (initializeApp({projectId})) —
          the service-account JSON is needed only for extras (Google Sheets etc.).
        - Wasp api() handler gotchas: signature must accept a 3rd context arg
          `(req, res, _context?: unknown)`; cast `String(req.params.id)` (its string|string[] type
          poisons Prisma query inference with baffling errors); webhooks that verify HMAC over the
          raw body need `middlewareConfigFn` replacing 'express.json' with
          `express.json({ verify: (req,_res,buf) => { req.rawBody = buf } })`.
        - Postgres JSONB does NOT preserve key order — any content-hash/diff over stored JSON must
          hash SORTED entries or every reread looks changed.
        - Entitlement lives in the DB, flipped ONLY by verified webhooks. Never trust the
          checkout redirect. Idempotency table for webhook event ids.
        - Background jobs (pg-boss) need an always-on process — see Phase 3 hosting choice.

        ## Phase 3 — Deploy the skeleton EARLY (before the product is finished)
        A live URL on day one surfaces CI/hosting problems while they are cheap.
        - Client → Firebase Hosting: `firebase projects:create <id>`, `firebase apps:create WEB`,
          `firebase apps:sdkconfig WEB <appId>` (all headless with the CI token). Build with
          `wasp build` then `npx vite build` in app/ — output lands in
          `app/.wasp/out/web-app/build`; copy to the hosting public dir ("dist").
          The client build hard-fails without REACT_APP_API_URL in env.
        - CI (GitHub Actions): Node 24, PIN the wasp CLI (`npm i -g @wasp.sh/wasp-cli@<local
          version>`), deploy with `npx firebase-tools deploy --only hosting --non-interactive
          --token "$FIREBASE_TOKEN"` (no service account needed).
        - Server → Fly.io (default: always-on for cron jobs, cheapest at ~$5-10/mo, native
          `wasp deploy fly launch <name> <region>`; fra is closest to KSA). Known failure modes:
          the launch dies on a "Press any key" prompt after postgres attach in non-TTY shells —
          resume with `yes "" | wasp deploy fly deploy`; later server-only redeploys are
          `wasp build && fly deploy .wasp/out --config "$PWD/fly-server.toml" -a <name>-server
          --remote-only`. Verify fly-server.toml has `min_machines_running = 1` (pg-boss cron
          dies on scale-to-zero — this is also why Cloud Run is the WRONG host for this stack).
        - Server secrets BEFORE first boot: WASP_WEB_CLIENT_URL (CORS — the Firebase Hosting URL),
          WASP_SERVER_URL, APP_URL, FIREBASE_PROJECT_ID. Set with `fly secrets set --stage`.
        - Wire them together: set repo secret REACT_APP_API_URL=https://<name>-server.fly.dev,
          push, verify the live bundle references the server and an OPTIONS preflight from the
          client origin returns 200. If wasp also deployed a redundant fly client app, destroy it.

        ## Phase 4 — Firebase Auth enablement (the 2-click wall)
        Free-tier Auth CANNOT be enabled headlessly: config PATCH 404s until Auth exists, and
        identityPlatform:initializeAuth demands GCP billing. Ask the user for exactly 2 clicks:
        console → Authentication → "Get started", then Google provider → Enable + support email.
        After that, flip Email/Password via API: exchange the CI token for an access token
        (oauth2.googleapis.com/token with firebase-tools' public client id/secret), then
        `PATCH .../admin/v2/projects/<id>/config?updateMask=signIn.email`. Verify by creating and
        deleting a real user via accounts:signUp with the web API key. Apple sign-in needs a paid
        Apple Developer account — ship without it.

        ## Phase 5 — Payments (decision tree, learned the hard way)
        - International customers matter → **Lemon Squeezy** (merchant of record): self-serve
          store, live in days, handles global sales tax, cards + PayPal + Apple/Google Pay.
          Integration: hosted checkout via POST /v1/checkouts (pass custom user_id), webhook with
          X-Signature HMAC over the RAW body syncing subscription_* events into the DB, customer
          portal URL from the subscription for card updates, cancel/resume via the LS API.
          EXCLUDE MoR-managed users from any local renewal cron — the MoR owns their recurrence.
        - KSA-local only (mada/STC Pay) → **Moyasar** (fastest onboarding, amounts in HALALAS ×100)
          or Tap (amounts in MAJOR units — the two are opposite; read the spec, not your memory).
          Tap approval takes weeks — never put it on the critical path.
        - Stripe is NOT available to KSA-domiciled businesses (only via a foreign entity).
        - Hybrid pattern: MoR primary + local gateway later; keep both behind one /api/checkout.

        ## Phase 6 — Custom domain: Namecheap → Firebase Hosting
        1. Buy: namecheap.com → search the name → prefer .com (~$10/yr) → enable the free
           Domain Privacy (WhoisGuard) → checkout. Domain is usable in minutes.
        2. Firebase console → Hosting → your site → "Add custom domain" → enter `yourdomain.com`
           (tick "redirect www" or add www separately). Firebase shows a TXT record.
        3. Namecheap → Domain List → Manage → Advanced DNS:
           - Add the TXT record (Host `@`, value from Firebase) → back in Firebase click Verify.
           - Firebase then shows the A records (two IPs). In Namecheap add BOTH:
             `A  @  <ip1>` and `A  @  <ip2>`; for www either `CNAME  www  yourdomain.com` or the
             same two A records on `www`. DELETE Namecheap's default parking CNAME/URL-redirect
             records first or they shadow yours.
        4. Wait: DNS minutes-to-hours; Firebase auto-provisions the SSL cert after propagation
           (status flips Pending → Connected; up to 24h, usually well under 1h).
        5. THE STEP EVERYONE FORGETS — update every reference to the old .web.app URL:
           - Firebase console → Authentication → Settings → Authorized domains → ADD the new
             domain (sign-in silently fails on it otherwise).
           - Fly server secrets: WASP_WEB_CLIENT_URL + APP_URL → https://yourdomain.com (CORS
             breaks otherwise); redeploy or restart machines.
           - Repo secret REACT_APP_API_URL stays the server URL; if the server gets its own
             subdomain: `fly certs add api.yourdomain.com -a <name>-server` + Namecheap
             `CNAME api → <name>-server.fly.dev`, then update REACT_APP_API_URL and push.
           - Payment provider store/redirect URLs, GA4 property, sitemap/OG urls.

        ## Phase 7 — Email deliverability (before the first real send)
        Resend → add sending domain → it lists SPF + DKIM (+ DMARC) records → add them in
        Namecheap Advanced DNS → wait for Verified. Transactional and broadcast stay separate
        streams; every broadcast carries List-Unsubscribe + a one-click unsubscribe endpoint.
        Until RESEND_API_KEY exists, email code logs to console — never blocks the build.

        ## Phase 8 — Production acceptance (nothing ships without this)
        - Real end-to-end on PRODUCTION: create a real user (Firebase accounts:signUp with the
          web API key), exercise the core product action via the live API, confirm the DB row,
          then delete the test user via accounts:delete.
        - Webhooks: unsigned POST → 401; signed replay of the same event → duplicate:true.
        - CI: push to main → green run → live site actually updated (grep the deployed bundle).
        - Record the project state (URLs, accounts, stubbed keys, quirks) in memory/docs so the
          next session resumes instead of rediscovering.

        ## Sequencing summary (the fast path)
        Phase 0 all-at-once → 1 scaffold → 3 skeleton deploy (yes, before the product) →
        2 product build → 4 auth clicks (user, 2 min) → 5 payments → 6 domain → 7 email → 8 accept.
        Human-blocking steps (0, 4, parts of 5/6) get requested EARLY and in BATCHES —
        never serialize a build behind a waiting human.
        """
    }

    func visionDoc() -> String {
        var s = "# Product Vision — \(name.trimmingCharacters(in: .whitespaces))\n\n"
        s += "## One-liner\n\(pitch.trimmingCharacters(in: .whitespaces))\n\n"
        s += "## Core features / pages\n"
        for l in features.replacingOccurrences(of: "\r", with: "").split(separator: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            s += "- \(l.trimmingCharacters(in: .whitespaces))\n"
        }
        s += "\n## Stack decisions\n- Auth: \(auth)\n"
        if auth.hasPrefix("Firebase") {
            s += "  (Integrated provider: **Firebase Authentication** — email/password + Google + Apple via the Firebase Web SDK. On first sign-in, mirror the user into the app's own User table keyed by the Firebase UID; protect every server route by verifying the Firebase ID token with firebase-admin. Put the Firebase web config in client env vars and the service-account JSON in FIREBASE_SERVICE_ACCOUNT, never committed.)\n"
            s += """
              (Enablement playbook — learned the hard way, follow it instead of rediscovering:
               - What WORKS headless with a `firebase login:ci` token: `firebase projects:create`, `firebase apps:create WEB`, `firebase apps:sdkconfig WEB <appId>` (gives apiKey/authDomain/projectId/appId for the client env), and `firebase deploy --only hosting --token "$FIREBASE_TOKEN"`.
               - What does NOT work headless on a free project: the initial Auth enablement. `PATCH admin/v2/.../config` returns 404 CONFIGURATION_NOT_FOUND until Auth exists, and `identityPlatform:initializeAuth` returns 400 BILLING_NOT_ENABLED (that API is the paid Identity Platform). The free classic Auth config is created ONLY by the console's "Get started" button. The Google provider also needs the console (it auto-creates the OAuth client; the raw API demands one by hand).
               - So ask the user for exactly 2 clicks: console → Authentication → "Get started", then Google provider → Enable + support email → Save. AFTER that, Email/Password CAN be flipped via API: exchange the CI token for an access token (oauth2.googleapis.com/token, firebase-tools' public client id/secret, grant_type=refresh_token), then `PATCH https://identitytoolkit.googleapis.com/admin/v2/projects/<id>/config?updateMask=signIn.email` with {"signIn":{"email":{"enabled":true,"passwordRequired":true}}}. Verify pagebyte-style authorized domains include the Hosting domain.
               - Dev fallback so the app works before any of this: accept `dev:<email>` bearer tokens in development only; firebase-admin verifies real ID tokens with just FIREBASE_PROJECT_ID (no service account needed) — the service-account JSON is only required for extras like Google Sheets access.
               - Apple sign-in requires a paid Apple Developer account — ship without it, add later.)\n
            """
        } else if auth.hasPrefix("Supabase") {
            s += "  (Integrated provider: **Supabase Auth** — email/password + social via supabase-js. Mirror users into the app's User table keyed by the Supabase user id; verify the Supabase JWT server-side with SUPABASE_JWT_SECRET. Keys: SUPABASE_URL + SUPABASE_ANON_KEY client-side, SUPABASE_SERVICE_ROLE_KEY server-only.)\n"
        } else if auth.hasPrefix("Clerk") {
            s += "  (Integrated provider: **Clerk** — use its drop-in <SignIn/>/<UserButton/> components for the whole auth UI. Mirror users into the app's User table via the Clerk webhook (user.created); protect API routes with Clerk's server middleware. Keys: NEXT_PUBLIC/VITE Clerk publishable key client-side, CLERK_SECRET_KEY server-only.)\n"
        }
        s += "- Payments: \(pay)\n"
        if paymentKey() != "none" { s += "  (see PAYMENTS.md for the verified integration spec + .env.server keys)\n" }
        s += "- AI layer: \(aiProvider)\n"
        if aiEnabled() { s += "  (see AI.md — our integrated multi-provider router with a best→cheapest priority ladder over OpenRouter + Groq + free commercial providers; wire ALL AI features through it)\n" }
        s += "- Analytics: Google Analytics 4 — MANDATORY for every use case\n"
        s += "  (see ANALYTICS.md — consent-gated gtag via the Open SaaS cookie-consent banner, required events, and the admin-dashboard stats job)\n"
        s += "- Base template: Open SaaS (Wasp + React + Node + Prisma) — \(Self.templateRepo)\n"
        s += "  (MANDATORY for every use case: if this folder is not an Open SaaS app yet, scaffold it with `wasp new -t saas` before anything else; never substitute another starter)\n\n"
        s += """
        ## Build instructions for Claude
        You are working inside a freshly scaffolded Open SaaS app. Implement the vision above:
        1. Read the Open SaaS structure (main.wasp / *.wasp, src/, schema.prisma).
        2. Configure auth to match the choice above; remove unused providers.
        3. Wire the chosen payment processor. If PAYMENTS.md exists, follow it EXACTLY (esp. the amount-unit rule) and stub the listed .env.server keys with clear TODOs.
        4. Build each feature/page listed, updating the Wasp config, routes, entities, and UI.
        5. Wire Google Analytics 4 exactly as ANALYTICS.md describes (consent-gated gtag, required events, admin stats job; env ids stubbed).
        6. Keep it runnable at every step (wasp start). Explain each change briefly.
        7. Do NOT commit real secrets. Ask before any destructive or paid action.
        """
        return s
    }

    // ---- AI layer -------------------------------------------------------------
    /// Does the chosen SaaS actually need an AI backend? (Skips AI.md for "None".)
    func aiEnabled() -> Bool { !aiProvider.hasPrefix("None") }

    /// Short key for the chosen strategy: "smart" | "openrouter" | "groq" | "byok".
    func aiKey() -> String {
        if aiProvider.hasPrefix("OpenRouter") { return "openrouter" }
        if aiProvider.hasPrefix("Groq") { return "groq" }
        if aiProvider.hasPrefix("BYOK") { return "byok" }
        return "smart"
    }

    /// The full AI integration spec written into the project as AI.md. Contains the
    /// performance-ranked model ladder, provider signup links, env keys, and a drop-in
    /// OpenAI-compatible router with automatic best→cheapest fallback. Every provider
    /// listed permits commercial use within its published rate limits.
    func aiSpec() -> String {
        let strat = aiKey()
        var s = "# AI layer — \(name.trimmingCharacters(in: .whitespaces))\n\n"
        s += "Strategy: **\(aiProvider)**. This app talks to ONE internal router (`src/server/ai/router.ts`) "
        s += "that exposes an OpenAI-compatible `chat()` call and automatically falls back down a "
        s += "performance-ranked ladder when a model is rate-limited or fails. Every provider below "
        s += "permits commercial use within its published free rate limits — no ToS games, no personal "
        s += "subscription accounts. Use the bundled `ai-integration` skill for the reference implementation.\n\n"

        s += "## Priority ladder — best model first, cheapest fallback last\n"
        s += "The router tries these in order and drops to the next on 429 / 5xx / timeout:\n\n"
        s += "| # | Model | Provider | Cost | Notes |\n|---|-------|----------|------|-------|\n"
        s += "| 1 | `openai/gpt-4o` / `anthropic/claude-3.5-sonnet` | OpenRouter (paid) | ~$2.5–3/M | Frontier quality — use for the hardest tasks / paid tiers |\n"
        s += "| 2 | `google/gemini-2.5-pro` | OpenRouter or Gemini API | cheap paid | Big context, strong reasoning |\n"
        s += "| 3 | `deepseek/deepseek-r1` | OpenRouter | ~$0.5/M | Best cheap reasoning model |\n"
        s += "| 4 | `llama-3.3-70b-versatile` | **Groq** | **free** | Fast + free, commercial OK — great default |\n"
        s += "| 5 | `deepseek/deepseek-chat:free` | **OpenRouter `:free`** | **free** | Strong general model, free tier |\n"
        s += "| 6 | `qwen/qwen-2.5-72b-instruct:free` | **OpenRouter `:free`** | **free** | Strong multilingual (good Arabic) |\n"
        s += "| 7 | `gemini-2.0-flash` | **Google AI Studio** | **free** | Fast, generous free tier, commercial OK |\n"
        s += "| 8 | `llama-3.1-8b-instant` | **Groq** | **free** | Lowest latency — cheap/simple calls |\n"
        s += "| 9 | `llama-3.3-70b` | **Cerebras** | **free** | Fastest inference, free tier |\n"
        s += "| 10 | `@cf/meta/llama-3.1-8b-instruct` | **Cloudflare Workers AI** | **free** | Last-resort always-on fallback |\n\n"

        switch strat {
        case "openrouter":
            s += "### Active order for this build (OpenRouter only)\n"
            s += "Route everything through OpenRouter with a single `OPENROUTER_API_KEY`. Order: paid frontier "
            s += "for premium tiers, then `:free` models (`deepseek/deepseek-chat:free`, `meta-llama/llama-3.3-70b-instruct:free`, "
            s += "`qwen/qwen-2.5-72b-instruct:free`) for the free tier. One key, 300+ models, built-in fallback via the `models` array.\n\n"
        case "groq":
            s += "### Active order for this build (Groq only)\n"
            s += "Route through Groq with `GROQ_API_KEY`: `llama-3.3-70b-versatile` (default), `qwen-2.5-32b`, "
            s += "`llama-3.1-8b-instant` (fast path), `deepseek-r1-distill-llama-70b` (reasoning). Free tier, commercial OK, fastest tokens/sec available.\n\n"
        case "byok":
            s += "### Active order for this build (BYOK — customer brings the key)\n"
            s += "Do NOT ship any provider key. In account settings let each customer paste their own OpenRouter/OpenAI/Groq/Anthropic key "
            s += "(store encrypted at rest, AES-256-GCM). All AI cost is theirs — this is $0 AI for you and fully within every provider's ToS. "
            s += "Fall back to the free ladder ONLY if you (the operator) provide a shared key for a limited free tier.\n\n"
        default:
            s += "### Active order for this build (Smart fallback — recommended)\n"
            s += "Free tier serves users on the free ladder (rows 4–10, $0). Paid tiers unlock the frontier rows (1–3), "
            s += "billed per token so revenue covers cost. The router picks the highest-priority model whose key is present "
            s += "and whose budget the caller's plan allows, then falls back automatically.\n\n"
        }

        s += "## Provider signup (all commercial-use-OK free tiers)\n"
        s += "- **OpenRouter** — https://openrouter.ai/keys · one key → 300+ models incl. many `:free`\n"
        s += "- **Groq** — https://console.groq.com/keys · fastest free inference\n"
        s += "- **Google AI Studio (Gemini)** — https://aistudio.google.com/apikey · generous free tier\n"
        s += "- **Cerebras** — https://cloud.cerebras.ai · fast free tier\n"
        s += "- **Cloudflare Workers AI** — https://dash.cloudflare.com · free neurons/day, always-on fallback\n\n"
        s += "Set only the keys for the providers you use (see `.env.ai.example`). Missing keys are skipped, not fatal.\n\n"

        s += "## Drop-in router (src/server/ai/router.ts)\n"
        s += "Because Groq, OpenRouter, Cerebras and Gemini (OpenAI-compat endpoint) all speak the OpenAI API, one client covers them all:\n\n"
        s += "```ts\n"
        s += aiRouterCode()
        s += "\n```\n\n"
        s += "Usage: `const answer = await aiChat([{ role: 'user', content: prompt }])`. "
        s += "It returns the first successful completion and logs which provider/model served it. "
        s += "Never expose keys client-side — all AI calls go through your server.\n\n"
        s += "## Rules\n"
        s += "- Keys live in `.env.server` only; never commit them, never send them to the browser.\n"
        s += "- Respect each provider's rate limits; the fallback handles 429s gracefully.\n"
        s += "- Meter usage per user/plan so a free user can't drain your paid tiers (tie into SUBSCRIPTIONS.md credits).\n"
        s += "- Keep the ladder in ONE config array so you can re-rank models as new ones ship.\n"
        return s
    }

    /// The reference router emitted into AI.md. One OpenAI-compatible client, priority list,
    /// automatic fallback on rate-limit/error. Kept compact but production-shaped.
    func aiRouterCode() -> String {
        return """
        import OpenAI from "openai";

        // Priority ladder: best model first, free/cheap fallbacks last. Re-rank freely.
        // Each entry names the provider base URL + the env var holding its key.
        type Rung = { provider: string; model: string; baseURL: string; keyEnv: string };
        const LADDER: Rung[] = [
          // ── frontier (paid — premium tiers) ──
          { provider: "openrouter", model: "openai/gpt-4o",                    baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
          { provider: "openrouter", model: "google/gemini-2.5-pro",           baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
          { provider: "openrouter", model: "deepseek/deepseek-r1",            baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
          // ── free, commercial-use OK ──
          { provider: "groq",       model: "llama-3.3-70b-versatile",         baseURL: "https://api.groq.com/openai/v1", keyEnv: "GROQ_API_KEY" },
          { provider: "openrouter", model: "deepseek/deepseek-chat:free",     baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
          { provider: "openrouter", model: "qwen/qwen-2.5-72b-instruct:free", baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
          { provider: "gemini",     model: "gemini-2.0-flash",                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", keyEnv: "GEMINI_API_KEY" },
          { provider: "groq",       model: "llama-3.1-8b-instant",            baseURL: "https://api.groq.com/openai/v1", keyEnv: "GROQ_API_KEY" },
          { provider: "cerebras",   model: "llama-3.3-70b",                   baseURL: "https://api.cerebras.ai/v1", keyEnv: "CEREBRAS_API_KEY" },
        ];

        export type ChatMsg = { role: "system" | "user" | "assistant"; content: string };

        // Try each configured rung in order; fall through on rate-limit / 5xx / network error.
        export async function aiChat(messages: ChatMsg[], opts: { maxRung?: number } = {}) {
          const rungs = LADDER.slice(0, opts.maxRung ?? LADDER.length).filter(r => process.env[r.keyEnv]);
          if (!rungs.length) throw new Error("No AI provider keys configured — set at least one in .env.server");
          let lastErr: unknown;
          for (const r of rungs) {
            try {
              const client = new OpenAI({ apiKey: process.env[r.keyEnv]!, baseURL: r.baseURL });
              const res = await client.chat.completions.create({ model: r.model, messages });
              console.log(`[ai] served by ${r.provider}:${r.model}`);
              return { text: res.choices[0]?.message?.content ?? "", provider: r.provider, model: r.model };
            } catch (e: any) {
              const status = e?.status ?? e?.response?.status;
              lastErr = e;
              if (status && ![429, 500, 502, 503, 504].includes(status)) throw e; // real error → stop
              console.warn(`[ai] ${r.provider}:${r.model} failed (${status ?? "network"}) → next`);
            }
          }
          throw lastErr ?? new Error("All AI providers exhausted");
        }
        """
    }

    func aiEnvExample() -> String {
        return """
        # AI provider keys — set only the ones you use; the router skips any that are missing.
        # All of these have commercial-use-OK free tiers. Keys are SERVER-ONLY — never expose to the browser.
        OPENROUTER_API_KEY=   # https://openrouter.ai/keys  (one key → 300+ models incl. :free)
        GROQ_API_KEY=         # https://console.groq.com/keys  (fastest free inference)
        GEMINI_API_KEY=       # https://aistudio.google.com/apikey  (generous free tier)
        CEREBRAS_API_KEY=     # https://cloud.cerebras.ai  (fast free tier)
        # CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN for Workers AI last-resort fallback
        """
    }

    func deploySpec() -> String {
        var s = "# Deployment spec — \(name.trimmingCharacters(in: .whitespaces))\n\n"
        s += "- Base app: **Open SaaS (Wasp)** — \(Self.templateRepo) (mandatory template for every use case)\n"
        s += "- Target: **\(target)**\n- Backend: **\(backend)**\n"
        if target == "Cloud Run" {
            s += "- Region: \(region)\n- Service: \(serviceName)\n"
            if !gcpProject.isEmpty { s += "- GCP project: \(gcpProject)\n" }
        }
        if target == "Firebase Hosting" { s += "- Public dir: \(publicDir)\n" }
        s += "\n> Open SaaS note: `wasp build` outputs the client at `.wasp/build/web-app` (run `npm install && npm run build` there → static files for the hosting target) and a server with a Dockerfile at `.wasp/build` (deploy to a container host — Cloud Run works). The server needs a PostgreSQL `DATABASE_URL` plus `WASP_WEB_CLIENT_URL` / `WASP_SERVER_URL` env vars.\n"
        s += "\n## What to do\n"
        switch target {
        case "Firebase Hosting":
            s += """
            1. `firebase login`; ensure the project in .firebaserc exists (`firebase projects:list`).
            2. Build the frontend (`npm run build`) so `\(publicDir)/` is produced.
            3. If backend is Functions: `firebase init functions`, implement the API in `functions/`, and keep the `/api/**` rewrite ABOVE the SPA catch-all in firebase.json.
            4. If Firestore: `firebase init firestore`, write default-deny rules, deploy rules.
            5. `firebase deploy` and report the Hosting URL. Smoke-test it.
            """
        case "Cloud Run":
            s += """
            1. Ensure the server listens on `process.env.PORT` on `0.0.0.0` (default 8080) — the #1 startup failure.
            2. `gcloud auth login` and `gcloud config set project <id>`; enable APIs: `gcloud services enable run.googleapis.com cloudbuild.googleapis.com`.
            3. Secrets via Secret Manager; env via `--set-env-vars`. Database via Cloud SQL (`--add-cloudsql-instances`) or a serverless Postgres `DATABASE_URL`.
            4. Deploy: `gcloud run deploy \(serviceName) --source . --region \(region) --allow-unauthenticated`. Report the service URL and smoke-test it.
            """
        default:
            s += """
            1. `vercel login`; from the project root run `vercel` (preview) then `vercel --prod`.
            2. Framework is auto-detected; only add vercel.json for overrides (e.g. SPA rewrite).
            3. Backend: put serverless endpoints in `/api`. Env: `vercel env add <NAME> production`, client vars need the `NEXT_PUBLIC_`/`VITE_` prefix.
            4. Connect a managed DB (Neon/Supabase/Upstash) via `DATABASE_URL`. Report the production URL and smoke-test it.
            """
        }
        s += "\n\n## GitHub is the core deploy location\n"
        s += "- Host the project as a **\(repoVisibility.lowercased())** GitHub repository (the app can create + push it for you).\n"
        s += "- CI/CD: a GitHub Actions workflow in `.github/workflows/` deploys every push to `main` to \(target). See GITHUB-ACTIONS.md for the exact secrets to set.\n"
        s += "\nSee CLOUD-DEPLOYMENT.md (and the bundled `cloud-deployment` skill) for full details. Never commit secrets; add `.env*` to .gitignore."
        return s
    }

    func firebaseJson() -> String {
        let functions = backend.hasPrefix("Firebase")
        var rewrites = ""
        if functions { rewrites += "      { \"source\": \"/api/**\", \"function\": \"api\" },\n" }
        rewrites += "      { \"source\": \"**\", \"destination\": \"/index.html\" }"
        var s = "{\n  \"hosting\": {\n    \"public\": \"\(publicDir)\",\n    \"ignore\": [\"firebase.json\", \"**/.*\", \"**/node_modules/**\"],\n    \"rewrites\": [\n\(rewrites)\n    ]\n  }"
        if functions { s += ",\n  \"functions\": { \"source\": \"functions\" }" }
        s += "\n}\n"
        return s
    }
    func firebaseRc() -> String { "{ \"projects\": { \"default\": \"\(gcpProject.trimmingCharacters(in: .whitespaces))\" } }\n" }

    func vercelJson() -> String {
        "{\n  \"$schema\": \"https://openapi.vercel.sh/vercel.json\",\n  \"rewrites\": [{ \"source\": \"/(.*)\", \"destination\": \"/\" }]\n}\n"
    }

    func dockerfile() -> String {
        """
        # Cloud Run container — MUST listen on $PORT (default 8080) on 0.0.0.0.
        FROM node:20-slim
        WORKDIR /app
        COPY package*.json ./
        RUN npm ci --omit=dev
        COPY . .
        ENV NODE_ENV=production
        EXPOSE 8080
        # Ensure your server uses: const port = process.env.PORT || 8080; app.listen(port, "0.0.0.0")
        CMD ["node", "server.js"]
        """
    }

    func subscriptionSpec() -> String {
        let key = subKey()
        var s = "# Subscription infrastructure — \(name.trimmingCharacters(in: .whitespaces))\n\n"
        s += "- Provider: **\(subProvider)**\n- Free trial: **\(trialDays) days**\n- Plans / tiers:\n"
        for l in tiers.replacingOccurrences(of: "\r", with: "").split(separator: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            s += "  - \(l.trimmingCharacters(in: .whitespaces))\n"
        }
        s += "\n## Architecture (build all four pillars)\n"
        s += "1. **Checkout** to start a subscription.\n2. **Signed webhooks** → update the DB (source of truth for entitlement).\n3. **Entitlement check** in the app (read the DB, never the client).\n4. **Customer Portal / self-service** for upgrade/cancel/card update.\n\n"
        if key == "stripe" {
            s += """
            ## Stripe
            - Create products + prices; store `price_...` ids in env by plan.
            - Checkout: `stripe.checkout.sessions.create({ mode: "subscription", customer, line_items:[{price,quantity:1}], subscription_data:{ trial_period_days: \(trialDays) }, success_url, cancel_url, client_reference_id: userId })`.
            - Webhook `/api/webhooks/stripe`: verify with the RAW body + `STRIPE_WEBHOOK_SECRET`; handle `checkout.session.completed`, `customer.subscription.updated/deleted`, `invoice.payment_failed`. Idempotent on `event.id`.
            - Portal: `stripe.billingPortal.sessions.create({ customer, return_url })`.
            - Entitlement: `["active","trialing"].includes(status) && currentPeriodEnd > now`.
            - Test locally: `stripe listen --forward-to localhost:3000/api/webhooks/stripe`.
            """
        } else if key == "tap" {
            s += """
            ## Tap Payments (KSA) — recurring
            - Amount in MAJOR units (10.00 SAR = 10.00). Auth: `Authorization: Bearer sk_...` (server only).
            - Save a card token via the Card SDK, then charge the saved token on your own schedule (a cron each period). Your DB holds subscription state.
            - Webhook: verify the `hashstring` HMAC before trusting `status == "CAPTURED"`. Methods: mada, Apple Pay, STC Pay, cards.
            """
        } else {
            s += """
            ## Moyasar (KSA) — recurring
            - Amount in HALALAS (10.00 SAR = 1000, ×100). Auth: HTTP Basic, secret key as username, empty password.
            - Save a `token` source, then `POST /payments` with `source.type = "token"` on your billing cadence (cron). Your DB holds subscription state.
            - Webhook: verify `secret_token` before marking a payment paid. Methods: creditcard (Visa/Mastercard/mada), Apple Pay, STC Pay.
            """
        }
        s += "\n\nData model: `User { stripeCustomerId, plan, subscriptionStatus, currentPeriodEnd, cancelAtPeriodEnd, emailOptIn }`, `WebhookEvent { id, processedAt }`.\nSee the bundled `subscription-billing` skill for full code. Keep secrets server-side."
        return s
    }

    func emailSpec() -> String {
        var s = "# Subscriber email — \(name.trimmingCharacters(in: .whitespaces))\n\n"
        s += "- Provider: **\(emailProvider)**\n- From: **\(fromEmail)**\n\n"
        s += "## Two jobs — keep them separate\n"
        s += "1. **Transactional** (one recipient, event-driven): welcome, receipt, payment-failed, trial-ending. Wire to billing webhook events.\n"
        s += "2. **Broadcast** (many recipients): newsletters / product updates to opted-in paid users. Must include one-click unsubscribe.\n\n"
        switch emailProvider {
        case "Postmark":
            s += "## Postmark\n- `npm i postmark`. Use separate **message streams** for transactional vs broadcast.\n- `new ServerClient(POSTMARK_TOKEN).sendEmail({ From, To, Subject, HtmlBody, MessageStream })`.\n"
        case "SendGrid":
            s += "## SendGrid\n- `npm i @sendgrid/mail`. Transactional via `sgMail.send(...)`; broadcasts via Marketing Campaigns.\n"
        default:
            s += "## Resend\n- `npm i resend`. `resend.emails.send({ from, to, subject, html })` for transactional; `resend.batch.send([...])` / Broadcasts for campaigns.\n"
        }
        s += "\n## Deliverability (non-negotiable)\n"
        s += "- Verify the sending domain: add **SPF + DKIM + DMARC** DNS records.\n- Every broadcast needs **one-click unsubscribe** (List-Unsubscribe header + footer). Store opt-outs; never re-send.\n- Separate transactional and marketing streams/subdomains. Track bounces/complaints and suppress bad addresses.\n\n"
        s += "Audience query: paid + opted-in — `where subscriptionStatus in (active,trialing) and emailOptIn = true`. See the bundled `subscription-billing` skill for code."
        return s
    }

    func subEnvExample() -> String {
        var lines: [String] = []
        switch subKey() {
        case "tap": lines += ["TAP_SECRET_KEY=sk_test_xxx", "TAP_PUBLISHABLE_KEY=pk_test_xxx"]
        case "moyasar": lines += ["MOYASAR_SECRET_KEY=sk_test_xxx", "MOYASAR_PUBLISHABLE_KEY=pk_test_xxx"]
        default: lines += ["STRIPE_SECRET_KEY=sk_test_xxx", "STRIPE_WEBHOOK_SECRET=whsec_xxx",
                           "STRIPE_PRICE_PRO_MONTHLY=price_xxx", "STRIPE_PRICE_PRO_YEARLY=price_xxx",
                           "NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_xxx"]
        }
        switch emailProvider {
        case "Postmark": lines.append("POSTMARK_SERVER_TOKEN=xxx")
        case "SendGrid": lines.append("SENDGRID_API_KEY=SG.xxx")
        default: lines.append("RESEND_API_KEY=re_xxx")
        }
        lines.append("APP_URL=https://your.app")
        lines.append("EMAIL_FROM=\(fromEmail)")
        return "# Never commit real values — add .env* to .gitignore\n" + lines.joined(separator: "\n") + "\n"
    }

    // ---- analytics: Google Analytics 4, mandatory for every use case ----
    func analyticsSpec() -> String {
        var s = "# Analytics — \(name.trimmingCharacters(in: .whitespaces))\n\n"
        s += "**Google Analytics 4 is REQUIRED for this app — every use case ships with it.** "
        s += "Open SaaS has first-class GA4 support (cookie-consent banner + admin-dashboard stats job); use it, do not hand-roll.\n\n"
        s += """
        ## 1. Create the GA4 property
        - analytics.google.com → Admin → Create property → add a **Web** data stream → copy the **Measurement ID** (`G-XXXXXXXXXX`).

        ## 2. Client tracking (built into Open SaaS)
        - Open SaaS ships a cookie-consent banner (vanilla-cookieconsent) that injects the gtag script ONLY after the visitor accepts — GDPR-safe by default. Keep that flow; never load gtag before consent.
        - Put the Measurement ID in the client env (`.env.client`): `REACT_APP_GOOGLE_ANALYTICS_ID=G-XXXXXXXXXX`.
        - Make sure the cookie-consent config (src/client/components/cookie-consent/Config.ts or equivalent) reads that same id.

        ## 3. Admin dashboard stats (server side)
        Open SaaS's daily stats job pulls GA metrics (page views, sources) into the admin dashboard via the **Google Analytics Data API**:
        - Google Cloud console: enable "Google Analytics Data API", create a service account, download its JSON key.
        - GA Admin → Property access management: add the service-account email as **Viewer**.
        - `.env.server` keys (stub with TODOs, never commit real values):
          - `GOOGLE_ANALYTICS_CLIENT_EMAIL=service-account@project.iam.gserviceaccount.com`
          - `GOOGLE_ANALYTICS_PRIVATE_KEY=` (the key, base64-encoded, per the Open SaaS docs)
          - `GOOGLE_ANALYTICS_PROPERTY_ID=` (the NUMERIC property id, not the G-… id)
        - Keep the daily stats job enabled in main.wasp so the admin dashboard fills in.

        ## 4. Events that MUST be tracked (the full SaaS funnel)
        Add a tiny `trackEvent(name, params)` helper that no-ops until consent, then wire EVERY stage:
        - **Acquisition**: `page_view` (automatic), `cta_click` (which CTA, which section).
        - **Activation**: `sign_up` (with method: email/google/apple), `login`,
          plus the product's FIRST "aha" action from VISION.md (e.g. first record created) as
          `activation` — this is the metric that predicts retention.
        - **Revenue**: `begin_checkout` (plan), `trial_started` (plan), `purchase` (plan, value,
          currency — fire SERVER-SIDE from the payment webhook via the GA4 Measurement Protocol so
          ad blockers can't hide revenue), `subscription_renewed`, `subscription_cancelled` (plan,
          days_subscribed), `payment_failed`.
        - **Engagement**: one event per core feature action in VISION.md, plus `limit_reached`
          (which limit — the strongest upgrade signal there is) and `api_key_created`.
        - Mark `sign_up`, `trial_started`, and `purchase` as CONVERSIONS in GA4 Admin → Events.

        ## 5. Beyond GA4 — the full monitoring stack (all free tiers, all mandatory)
        A SaaS you can't observe is a SaaS you can't run. Wire ALL of these:
        - **Error monitoring — Sentry** (free tier): `@sentry/react` on the client (wrap the app,
          upload sourcemaps in CI) + `@sentry/node` on the server (capture in the API error
          handler and job failures). Env: `SENTRY_DSN` / `REACT_APP_SENTRY_DSN`, stubbed. Tag
          events with plan + release so paid-user bugs surface first.
        - **Uptime — Better Stack or UptimeRobot** (free): monitor `https://<domain>/` AND the
          server health endpoint every 60s with email/phone alerts. Add a `GET /api/health`
          endpoint returning `{status:"ok", db:true}` (touch the DB so it actually proves health).
        - **Host-level checks**: Fly.io `[[http_service.checks]]` hitting /api/health so dead
          machines restart themselves; `fly logs` is the raw stream, keep structured
          `console.log` JSON lines for greppability.
        - **Business KPI snapshot**: extend the daily stats job to also compute and store MRR,
          active subscriber count, trials in flight, trial→paid conversion %, churn (cancels /
          active), and signups per day — the admin dashboard should answer "how is the business"
          in one glance without opening GA.
        - **Search Console**: verify the domain (DNS TXT), submit the sitemap — free SEO
          diagnostics and the only place Google tells you about indexing problems.
        - **Alerting rule of thumb**: uptime + payment-webhook failures page you (email/push);
          everything else is a dashboard you check weekly.

        ## Rules
        - Never block rendering on gtag; load async after consent.
        - No PII in event params (no emails, names, phone numbers).
        - Server-side revenue events use the GA4 Measurement Protocol (api_secret from the data
          stream settings — `GA4_API_SECRET` in .env.server, stubbed).
        - Verify with GA DebugView before launch; docs: https://docs.opensaas.sh/guides/analytics/
        """
        return s
    }

    func analyticsEnvExample() -> String {
        return """
        # Google Analytics 4 — mandatory for every build. Never commit real values.
        # Client (.env.client) — the web stream Measurement ID:
        REACT_APP_GOOGLE_ANALYTICS_ID=G-XXXXXXXXXX
        # Server (.env.server) — Google Analytics Data API service account (admin dashboard stats):
        GOOGLE_ANALYTICS_CLIENT_EMAIL=service-account@project.iam.gserviceaccount.com
        GOOGLE_ANALYTICS_PRIVATE_KEY=   # base64-encoded private key
        GOOGLE_ANALYTICS_PROPERTY_ID=   # numeric property id (not the G-… id)
        # Server-side revenue events (GA4 Measurement Protocol, from the payment webhook):
        GA4_API_SECRET=                 # GA4 Admin → data stream → Measurement Protocol API secrets
        # Error monitoring (Sentry, free tier — client + server):
        REACT_APP_SENTRY_DSN=
        SENTRY_DSN=
        """
    }

    // ---- payment specs (verified KSA integration details) ----
    func paymentDocsUrl(_ key: String) -> String {
        switch key {
        case "tap": return "https://developers.tap.company/"
        case "moyasar": return "https://docs.moyasar.com/"
        case "polar": return "https://docs.polar.sh/"
        default: return "https://docs.opensaas.sh/guides/payments-integration/"
        }
    }

    func paymentEnvVars(_ key: String) -> [String] {
        switch key {
        case "tap": return ["TAP_SECRET_KEY=sk_test_xxx", "TAP_PUBLISHABLE_KEY=pk_test_xxx"]
        case "moyasar": return ["MOYASAR_SECRET_KEY=sk_test_xxx", "MOYASAR_PUBLISHABLE_KEY=pk_test_xxx"]
        case "stripe": return ["STRIPE_API_KEY=sk_test_xxx", "STRIPE_WEBHOOK_SECRET=whsec_xxx"]
        case "lemonsqueezy": return ["LEMONSQUEEZY_API_KEY=xxx", "LEMONSQUEEZY_WEBHOOK_SECRET=xxx"]
        case "polar": return ["POLAR_ACCESS_TOKEN=xxx", "POLAR_WEBHOOK_SECRET=xxx"]
        default: return []
        }
    }

    func paymentSpec(_ key: String) -> String {
        var s = ""
        if key == "tap" {
            s += """
            # Payment integration — Tap Payments (KSA)

            - API base: `https://api.tap.company/v2/`
            - Auth: HTTP header `Authorization: Bearer <secret_key>` (server-side only). Secret keys are `sk_test_…` / `sk_live_…`; publishable `pk_test_…` is for the web card SDK.
            - Create a charge: `POST /charges`. Required fields:
              - `amount` — **DECIMAL in the currency unit, NOT minor units.** 10.00 SAR is sent as `10.00`. Do NOT multiply by 100.
              - `currency` — `"SAR"`
              - `customer` — object with `first_name` and `email` (optional `phone: { country_code: 966, number: ... }`)
              - `source` — object with `id`; `"src_all"` shows all methods, or `src_card`/`src_mada`/`src_apple_pay`, or a tokenized card id from the SDK
              - `redirect` — object with `url` (customer returns here after 3-D Secure)
              - `post` — object with `url` (server webhook that receives the charge object)
              - `threeDSecure` — boolean (default true)
            - Saudi methods: mada, Apple Pay, Visa/Mastercard, Benefit, KNET, STC Pay.
            - Frontend: Tap **Web Card SDK v2** (`tap-card-sdk`) or hosted **goSell** checkout — tokenizes the card in-browser and returns a `source` id you pass to `POST /charges`.
            - Webhook: Tap POSTs the charge to your `post.url`; verify the `hashstring` HMAC header before trusting `status == "CAPTURED"`.
            - Dashboard / keys: https://dashboard.tap.company  •  Docs: https://developers.tap.company/
            """
        } else if key == "moyasar" {
            s += """
            # Payment integration — Moyasar (KSA)

            - API base: `https://api.moyasar.com/v1/`
            - Auth: **HTTP Basic** — the secret key is the username and the password is left EMPTY. Secret keys are `sk_test_…` / `sk_live_…`; publishable `pk_test_…` / `pk_live_…` is safe in client code.
            - Create a payment: `POST /payments`. Required fields:
              - `amount` — **INTEGER in the smallest unit (halalas), i.e. ×100.** 10.00 SAR is sent as `1000`. This is the OPPOSITE of Tap.
              - `currency` — `"SAR"`
              - `source` — object whose `type` is `creditcard` | `token` | `applepay` | `stcpay`
              - `callback_url` — required for `creditcard`/`token`; the payer is returned here after the card flow
              - `description` — optional label
            - Saudi methods: creditcard (Visa, Mastercard, mada, UnionPay), Apple Pay, STC Pay.
            - Frontend: **moyasar.js** hosted form. Init example:
              ```js
              Moyasar.init({
                element: '.mysr-form',
                amount: 1000,               // 10.00 SAR in halalas
                currency: 'SAR',
                description: 'Order #1',
                publishable_api_key: 'pk_test_xxx',
                callback_url: 'https://your.app/thanks',
                methods: ['creditcard', 'applepay', 'stcpay'],
                supported_networks: ['visa', 'mastercard', 'mada']
              });
              ```
              (Load moyasar.js + its CSS from the Moyasar CDN.)
            - Webhook: configure in the dashboard; verify the `secret_token` in the payload before marking a payment `paid`.
            - Dashboard / keys: https://dashboard.moyasar.com  •  Docs: https://docs.moyasar.com/
            """
        } else {
            s += "# Payment integration — \(pay)\n\nOpen SaaS ships first-class support for Stripe and Lemon Squeezy.\nSee https://docs.opensaas.sh/guides/payments-integration/ and wire keys in `.env.server`.\n"
        }
        if key != "none" {
            s += "\n\n## .env.server keys (stub — never commit real secrets)\n"
            for v in paymentEnvVars(key) { s += v + "\n" }
        }
        return s
    }

    // ---- full in-depth deployment guide (written into the project on demand) ----
    private func writeGuide(_ fileName: String, _ content: String) -> String {
        let dir = FS.isDir(deployDir()) ? deployDir() : Paths.stateDir
        let path = dir + "/" + fileName
        FS.write(path, content)
        out("Wrote \(fileName) to \(dir)")
        return path
    }

    func cloudGuide() -> String {
        // A compact, correct field guide. The bundled `cloud-deployment` skill has the full version.
        return """
        # Cloud Deployment — quick field guide

        ## Pick a target
        - Static site / SPA → Firebase Hosting or Vercel
        - Next.js / SSR → Vercel (zero-config)
        - Container / any language / long-running → Cloud Run
        - Firestore + Auth tightly integrated → Firebase

        ## Vercel (fastest for frontends)
        - `npm i -g vercel` → `vercel login` → `vercel` (preview) → `vercel --prod`
        - Backend: files in `/api` become serverless endpoints. Env: `vercel env add NAME production`.
        - DB: connect Neon/Supabase/Upstash via `DATABASE_URL`.

        ## Firebase Hosting (+ Functions + Firestore)
        - `npm i -g firebase-tools` → `firebase login` → `firebase init hosting` (public=\(publicDir), SPA=yes)
        - `npm run build` → `firebase deploy --only hosting`
        - Backend: `firebase init functions`; route `/api/**` to the function ABOVE the SPA catch-all.
        - DB: `firebase init firestore`; default-deny rules; deploy with `firebase deploy --only firestore:rules`.

        ## Cloud Run (containers, any language)
        - App MUST listen on `process.env.PORT` (8080) on 0.0.0.0.
        - `gcloud auth login` → `gcloud config set project ID`
        - `gcloud run deploy \(serviceName) --source . --region \(region) --allow-unauthenticated`
        - Secrets: Secret Manager + `--update-secrets`. DB: Cloud SQL `--add-cloudsql-instances` or serverless `DATABASE_URL`.

        ## Frontend + separate backend
        - Frontend on Vercel/Firebase, API on Cloud Run. Set `VITE_API_URL`/`NEXT_PUBLIC_API_URL` to the Cloud Run URL.
        - Restrict CORS to the real frontend origin, or same-origin via a rewrite/proxy.

        ## Pre-launch
        - Secrets in the platform store, `.env*` gitignored.
        - Firestore/Storage rules default-deny.
        - Backend binds $PORT (Cloud Run).
        - Custom domain + HTTPS (auto on all three).
        - Cap instances to control cost; smoke-test the live URL.

        For the full version, the app bundles a `cloud-deployment` Claude skill with copy-paste code.
        """
    }
}
