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
- Prerendered routes run your components in NODE at build time: any touch of
  localStorage / window / document outside useEffect (including useState INITIALIZERS)
  throws "ReferenceError: localStorage is not defined" and kills the CI build. Guard with
  `typeof window === "undefined"` and move browser reads into useEffect. Always run the
  production client build locally before pushing UI that touches browser APIs.
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
  Before shipping the webhook, drive the WHOLE lifecycle locally with hand-signed
  payloads (created → payment_failed → cancelled → expired → duplicate replay): a
  20-line script catches mapping bugs that only surface with real subscribers.
- KSA-local only (mada/STC Pay) → **Moyasar** (fastest onboarding, amounts in HALALAS ×100)
  or Tap (amounts in MAJOR units — the two are opposite; read the spec, not your memory).
  Tap approval takes weeks — never put it on the critical path.
- Stripe is NOT available to KSA-domiciled businesses (only via a foreign entity).
- Hybrid pattern: MoR primary + local gateway later; keep both behind one /api/checkout.

## Phase 6 — Custom domain: Namecheap → Firebase Hosting (proven ~40 min end to end)
Nearly everything is HEADLESS via the Hosting REST API — the console is never needed.
The only human steps are buying the domain and pasting 3 DNS records.
1. Buy: namecheap.com → search the name → .com/.ai/.io → enable the free Domain Privacy
   (WhoisGuard) → checkout, skip every upsell. Domain is usable in minutes.
2. Register the domain with Hosting via API (access token minted from the CI refresh
   token — NOTE: those access tokens expire in ~1h, re-mint per session, never cache):
   - apex: `POST https://firebasehosting.googleapis.com/v1beta1/projects/<p>/sites/<s>/customDomains?customDomainId=yourdomain.com` body `{"redirectTarget":""}`
   - www:  same endpoint, `customDomainId=www.yourdomain.com`, body `{"redirectTarget":"yourdomain.com"}` (301 to apex)
   - `GET .../customDomains/yourdomain.com` → `requiredDnsUpdates.desired[].records[]`
     gives the EXACT records. Current Firebase infra wants just:
     `TXT @ hosting-site=<site-id>`, `A @ 199.36.158.100`, `CNAME www <site>.web.app`.
3. User pastes those 3 rows in Namecheap → Domain List → Manage → Advanced DNS.
   DELETE Namecheap's default parking CNAME/URL-redirect records first — they shadow yours.
4. Poll (all observable, no console): `dig` until the A + TXT resolve (Namecheap ≈ minutes),
   then GET the customDomain until `hostState: HOST_ACTIVE` (A seen) and
   `ownershipState: OWNERSHIP_ACTIVE` (TXT verified). Cert: it will sit at
   `cert.type: TEMPORARY, state: CERT_PROPAGATING` while ALREADY serving real TLS
   (Google Trust Services) — the site is live at this point; do NOT wait for CERT_ACTIVE,
   the dedicated cert swaps in on its own.
5. THE STEPS EVERYONE FORGETS — update every reference to the old .web.app URL:
   - Auth authorized domains, headless: `PATCH identitytoolkit .../config?updateMask=authorizedDomains`
     appending the new apex + www (sign-in silently fails on them otherwise).
   - Fly server secrets: WASP_WEB_CLIENT_URL + APP_URL → https://yourdomain.com (CORS
     breaks otherwise); `fly secrets set` restarts machines; verify with an OPTIONS
     preflight from the new Origin (expect 200).
   - Repo secret REACT_APP_API_URL stays the server URL; if the server gets its own
     subdomain: `fly certs add api.yourdomain.com -a <name>-server` + Namecheap
     `CNAME api → <name>-server.fly.dev`, then update REACT_APP_API_URL and push.
   - Payment provider store/redirect URLs, GA4 stream URL, sitemap/OG urls.
   - Finish with a real e2e from the new origin: signup → authed API call → delete user.

## Phase 6b — Analytics & monitoring implementation (per ANALYTICS.md, proven pattern)
- Client: `src/analytics/ga.ts` — consent state in localStorage, gtag injected ONLY after
  Accept, `trackEvent()` no-ops before consent/without a measurement id, plus SPA
  `trackPageView` on route change. A ~40-line ConsentBanner component beats a cookie lib.
- Wire funnel events at the SUCCESS points, not the clicks: sign_up/login (with method)
  right before the post-auth redirect, trial_started after the API confirms,
  begin_checkout before handing off to the processor, one event per core action.
- Server: `src/analytics/mp.ts` — GA4 Measurement Protocol with a sha256(userId) client id.
  Fire `purchase` ONLY on the payment-success webhook event (money moved), never also on
  subscription_created — the two arrive in any order and double-count revenue.
- Health: `GET /api/health` runs `SELECT 1` so "up" means serving, wired into
  `[[http_service.checks]]` in fly-server.toml — unhealthy machines self-restart.
- All of it ships with EMPTY env ids and no-ops gracefully; the user creates the GA4
  property (property + web stream + MP api_secret = 3 minutes) whenever ready.

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

## Skills to load, per phase (MANDATORY — load BEFORE the phase's work, not after)
The installed Claude skills encode taste and guardrails this playbook depends on.
Skipping them produces generic output that later needs redoing — slower, not faster.
- **Whole build, always on**: `karpathy-guidelines` (surgical changes, no
  overengineering, verifiable success criteria) + `full-output-enforcement`
  (no stubs, no placeholders, complete files only).
- **Phase 2 UI work**: `design-taste-frontend` (the anti-slop design system: dial
  calibration, banned AI-tells, layout discipline) — load it BEFORE writing the first
  component, declare the design read, and run its pre-flight check before shipping
  pages. Complement with `high-end-visual-design` / `gpt-taste` when the brief wants
  premium polish, `imagegen-frontend-web` + `image-to-code` when real visuals are needed.
- **All user-facing COPY (landing, about, emails, empty states)**: `stop-slop` — strip
  the AI writing tells (em-dashes are banned everywhere anyway, hedging, "delve",
  mirrored parallelisms). Copy reads like a person wrote it or it gets rewritten.
- **Phase 2 AI features**: `ai-integration` (the router ladder is its reference impl).
- **Phase 3 deploys**: `cloud-deployment`.
- **Phase 5 billing + email**: `subscription-billing` (four pillars, webhook rules,
  KSA specifics, deliverability).
- **Before any commit of nontrivial product code**: run `verify` (drive the changed
  flow end-to-end) and a `/code-review` pass on the diff.

## Sequencing summary (the fast path)
Phase 0 all-at-once → 1 scaffold → 3 skeleton deploy (yes, before the product) →
2 product build → 4 auth clicks (user, 2 min) → 5 payments → 6 domain → 6b monitoring →
7 email → 8 accept.
Human-blocking steps (0, 4, parts of 5/6) get requested EARLY and in BATCHES —
never serialize a build behind a waiting human.
Reference timings from a real run (Page Byte, 2026-07): scaffold→compiling ~15 min,
skeleton live on Hosting same hour, Fly server + Postgres ~20 min, Auth enablement
2 clicks + 5 min, LS integration incl. lifecycle tests ~1h, domain purchase→live TLS
~40 min, GA4+monitoring ~45 min. A focused end-to-end is a same-day ship.
