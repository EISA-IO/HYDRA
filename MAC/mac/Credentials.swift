import SwiftUI

// ============================================================================
// Credentials — a general-purpose store for access tokens and API keys, shared
// across ALL projects (not tied to any single build). Values live in
// ~/.claude-manager/credentials.env (0600, key=value) and are injected as
// environment variables into every terminal the app launches, so `gh`,
// `firebase --token`, AI SDKs, payment/email CLIs etc. work in any project
// without re-authenticating.
// ============================================================================

struct CredentialSpec: Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let hint: String
}

enum CredCatalog {
    static let all: [CredentialSpec] = [
        .init(key: "GITHUB_TOKEN",
              label: "GitHub token",
              hint: "gh auth token / PAT — scopes: repo, workflow. Used by gh + git pushes."),
        .init(key: "FIREBASE_TOKEN",
              label: "Firebase CI token",
              hint: "From `firebase login:ci`. Deploys: firebase deploy --token \"$FIREBASE_TOKEN\"."),
        .init(key: "FIREBASE_SERVICE_ACCOUNT",
              label: "Firebase service account",
              hint: "Base64 (or raw JSON) service-account key — firebase-admin, CI hosting deploys."),
        .init(key: "TAP_SECRET_KEY",
              label: "Tap Payments secret",
              hint: "sk_test_… / sk_live_… — KSA payments (server-side only)."),
        .init(key: "TAP_PUBLISHABLE_KEY",
              label: "Tap publishable key",
              hint: "pk_test_… — the web card SDK key."),
        .init(key: "RESEND_API_KEY",
              label: "Resend API key",
              hint: "re_… — transactional + broadcast email."),
        .init(key: "OPENROUTER_API_KEY",
              label: "OpenRouter key",
              hint: "One key → 300+ models incl. :free — openrouter.ai/keys."),
        .init(key: "GROQ_API_KEY",
              label: "Groq key",
              hint: "Fastest free inference — console.groq.com/keys."),
        .init(key: "GEMINI_API_KEY",
              label: "Gemini key",
              hint: "Google AI Studio free tier — aistudio.google.com/apikey."),
        .init(key: "CEREBRAS_API_KEY",
              label: "Cerebras key",
              hint: "Fast free tier — cloud.cerebras.ai."),
    ]
}

enum CredStore {
    static let file = Paths.stateDir + "/credentials.env"

    static func load() -> [String: String] {
        guard let text = FS.read(file) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let l = String(line)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let k = String(l[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(l[l.index(after: eq)...])
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    static func save(_ creds: [String: String]) {
        var lines = ["# Claude Manager — shared access tokens & API keys.",
                     "# Injected as env vars into every terminal the app launches. Do not commit."]
        // Catalog keys first (stable order), then any custom extras alphabetically.
        let catalogKeys = CredCatalog.all.map(\.key)
        for k in catalogKeys {
            if let v = creds[k], !v.isEmpty { lines.append("\(k)=\(v)") }
        }
        for k in creds.keys.sorted() where !catalogKeys.contains(k) {
            if let v = creds[k], !v.isEmpty { lines.append("\(k)=\(v)") }
        }
        FS.write(file, lines.joined(separator: "\n") + "\n")
        // Tokens on disk: owner read/write only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
}

// ============================================================================
// Settings section — masked fields with reveal, CLI auth detection, custom keys.
// ============================================================================
struct CredentialsSection: View {
    @EnvironmentObject var app: AppState
    @State private var revealed: Set<String> = []
    @State private var ghStatus = "checking…"
    @State private var fbStatus = "checking…"
    @State private var ghOk = false
    @State private var fbOk = false
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionCap(text: "Access & API keys — shared across projects")
                Text("Stored in ~/.claude-manager/credentials.env (owner-only permissions) and exported as environment variables into every terminal this app launches. Any project you build here can use them; nothing is tied to a single repo.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                // CLI auth detection (informational — env keys below work even without these).
                HStack(spacing: 14) {
                    statusDot(ok: ghOk, text: "GitHub CLI: " + ghStatus)
                    statusDot(ok: fbOk, text: "Firebase CLI: " + fbStatus)
                    Spacer()
                    Button("Re-check") { detect() }.ghostButton()
                }

                ForEach(CredCatalog.all) { spec in
                    credRow(spec)
                }

                Divider().overlay(Color.white.opacity(0.05))

                // Custom keys — anything else a future project needs (Stripe, Moyasar, S3…).
                let extras = app.creds.keys
                    .filter { k in !CredCatalog.all.contains { $0.key == k } }
                    .sorted()
                if !extras.isEmpty {
                    ForEach(extras, id: \.self) { k in
                        customRow(k)
                    }
                }
                HStack(spacing: 8) {
                    DarkField(placeholder: "CUSTOM_ENV_KEY", text: $newKey, mono: true)
                        .frame(width: 220)
                    DarkField(placeholder: "value", text: $newValue, mono: true)
                    Button("Add") {
                        let k = newKey.trimmingCharacters(in: .whitespaces).uppercased()
                            .replacingOccurrences(of: " ", with: "_")
                        guard !k.isEmpty, !newValue.isEmpty else { return }
                        app.setCred(k, newValue)
                        newKey = ""; newValue = ""
                    }.accentButton()
                }
                Text("New terminals pick up changes immediately; terminals already open keep the env they started with.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
            }
        }
        .onAppear { detect() }
    }

    private func credRow(_ spec: CredentialSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                FieldLabel(text: spec.label)
                Text(spec.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textFaint)
                Spacer()
                if !(app.creds[spec.key] ?? "").isEmpty {
                    Text("set").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.green)
                }
                Button(revealed.contains(spec.key) ? "Hide" : "Show") {
                    if revealed.contains(spec.key) { revealed.remove(spec.key) } else { revealed.insert(spec.key) }
                }.ghostButton()
            }
            maskedField(key: spec.key, placeholder: spec.hint)
            Text(spec.hint).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
        }
    }

    private func customRow(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim)
                Spacer()
                Button(revealed.contains(key) ? "Hide" : "Show") {
                    if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                }.ghostButton()
                Button("Remove") { app.setCred(key, "") }.ghostButton()
            }
            maskedField(key: key, placeholder: "value")
        }
    }

    private func maskedField(key: String, placeholder: String) -> some View {
        let binding = Binding<String>(
            get: { app.creds[key] ?? "" },
            set: { app.setCred(key, $0) }
        )
        return Group {
            if revealed.contains(key) {
                DarkField(placeholder: placeholder, text: binding, mono: true)
            } else {
                SecureField(placeholder, text: binding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1))
            }
        }
    }

    private func statusDot(ok: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Theme.green : Theme.yellow).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.textDim)
        }
    }

    private func detect() {
        ghStatus = "checking…"; fbStatus = "checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let sh = Shell.shared
            let gh = sh.bash("gh auth status 2>&1", timeout: 15)
            let ghLogged = gh.out.contains("Logged in") || gh.err.contains("Logged in")
            let ghScopes = (gh.out + gh.err).contains("workflow")
            let fb = sh.bash("firebase login:list 2>&1", timeout: 15)
            let fbText = fb.out + fb.err
            let fbLogged = !fbText.contains("No authorized accounts") && fbText.contains("@")
            let hasFbToken = !(CredStore.load()["FIREBASE_TOKEN"] ?? "").isEmpty
            DispatchQueue.main.async {
                ghOk = ghLogged
                ghStatus = ghLogged ? (ghScopes ? "logged in (workflow scope ✓)" : "logged in (no workflow scope)") : "not logged in"
                fbOk = fbLogged || hasFbToken
                fbStatus = fbLogged ? "logged in" : (hasFbToken ? "CI token set" : "not logged in")
            }
        }
    }
}
