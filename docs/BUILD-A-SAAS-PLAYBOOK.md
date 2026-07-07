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
- CORS PREFLIGHT (cost us a full debugging cycle — do this from the start): Wasp attaches
  its cors middleware PER-ROUTE by the route's HTTP method, so a browser OPTIONS preflight
  matches NO route and returns without Access-Control-Allow-Origin — blocking EVERY authed
  browser call (any request with an Authorization or JSON content-type header triggers a
  preflight). It is invisible to curl/server-to-server tests (they send no preflight), so
  it only shows up in a real browser. Fix: add ONE `apiNamespace("/api", { middlewareConfigFn })`
  in a spec file (a passthrough `(c)=>c` is enough) — apiNamespace mounts via router.use,
  which DOES match OPTIONS. Verify with `curl -X OPTIONS <server>/api/me -H "Origin: <client>"
  -H "Access-Control-Request-Method: GET" -H "Access-Control-Request-Headers: authorization"`
  → expect 204 + access-control-allow-origin. Test in an actual browser before calling auth done.
- IDENTITY CONFLICT (unique email vs firebaseUid upsert): mirror users keyed by firebaseUid,
  but User.email is unique. If the same person signs in under a NEW uid while a row already
  holds their email (switched Google↔password, or a leftover test row), a plain
  `upsert({where:{firebaseUid}})` throws P2002 on email → /api/me 500s → the app looks
  totally broken (no login, no admin). requireUser must: find by uid → else find by email
  and CLAIM that row (update its firebaseUid) → else create. Never leave orphaned auth rows
  from test accounts; deleting the Firebase user does NOT delete the mirrored DB row.
- ADMIN PANEL from day one (every SaaS needs it): an admin-only /admin page gated by an
  `isAdmin` User flag (granted when the email is in ADMIN_EMAILS on sign-in — set that Fly
  secret BEFORE first admin login). Include: business KPIs (MRR/ARR, subscribers, trials,
  trial→paid, signups, past-due), a support INBOX reading the contact-form table (reply
  emails the customer + marks handled), and a user directory with per-user detail + controls
  (grant/revoke admin — guard against self-lockout, change plan, reset usage). Every admin
  endpoint calls requireAdmin; verify a non-admin token gets 403.
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
- DISPLAY CURRENCY = the MoR's currency (LS bills in USD and localizes at checkout), which
  is usually NOT the local currency you first hardcoded. Keep ONE canonical `priceUsd` (or
  whatever the processor charges) in a shared plans module; the dormant local gateway
  converts at charge time. Sweeping SAR→USD across UI + emails + analytics after the fact
  is tedious — pick the processor's currency from the start.
- When no processor key is set yet, /api/checkout must return a clean 4xx ("payments not
  live yet"), never a stack trace mentioning a specific unconfigured gateway.

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

## Phase 7 — Email: inbound + outbound (two separate jobs, both easy to get wrong)
INBOUND (support@yourdomain — customers reach you): Namecheap → Domain → Manage → Email
Forwarding (free): add `support` → your inbox. It auto-adds root MX (eforward1-5.registrar-
servers.com). Verify `dig MX yourdomain` shows them.
OUTBOUND (send receipts/replies): Resend → add sending domain → it lists DKIM (TXT) + an SPF
TXT + an MX, all on a `send.` subdomain. Add them, click Verify (poll the Resend domains API
for status:"verified"; DKIM alone won't flip it — the send MX is required). Then set
RESEND_API_KEY + EMAIL_FROM=support@yourdomain and send a live test.
- THE CONFLICT (cost us a broken inbox): Namecheap "Email Forwarding" and "Custom MX" are
  MUTUALLY EXCLUSIVE in the Mail Settings dropdown. Resend's send-subdomain MX needs Custom
  MX, and switching to it WIPES the eforward forwarding records — silently killing inbound
  support mail. Fix: under Custom MX, re-add ALL of it by hand — the 5 eforward MX on host
  `@` (restores forwarding) PLUS the Resend MX on host `send`. Verify BOTH directions after:
  `dig MX yourdomain` (eforward present) and `dig MX send.yourdomain` (Resend present).
- RESILIENT SENDS: the contact form / any user-facing action must STORE first and treat the
  email as best-effort (try/catch, never 500 on a send failure — the domain may still be
  verifying). But an admin "reply" should check Resend's returned `error` and NOT mark the
  ticket resolved if the send actually failed. Until RESEND_API_KEY exists, log to console.
- Transactional and broadcast stay separate streams; every broadcast carries
  List-Unsubscribe + a one-click unsubscribe endpoint.

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

## Human-blocking steps — collect these ALL at the start (they gate, code doesn't)
Everything a human must click sits behind an account or a payment. Ask for them in ONE
batch up front, build while they trickle in, and make every feature no-op gracefully
until its key/value lands. The full list for a Firebase+Fly+LS+Resend SaaS:
- `gh auth refresh -s workflow`, `firebase login:ci`, `fly auth login` (+card).
- Firebase console: Authentication → Get started + enable Google (the 2 clicks).
- Payments: create the LS store + 2 subscription products (products are DASHBOARD-ONLY;
  the API can't create them). Then 5 values: API key, Store ID, webhook secret, and the
  2 monthly variant IDs (the rest — store lookup, webhook creation, variant discovery — I
  do via the LS API from just the API key).
- GA4: create property + web stream + a Measurement Protocol secret (Google gates account
  creation to the owner's browser; my token can't).
- Domain: buy it; add DNS rows I hand you; set up email forwarding + Resend records.
Each of these is the ONLY thing that ever blocks for real time. Request early, in bulk.

## Sequencing summary (the fast path)
Phase 0 all-at-once → 1 scaffold → 3 skeleton deploy (yes, before the product) →
2 product build (incl. admin panel + contact/support form) → 4 auth clicks (user, 2 min) →
5 payments → 6 domain → 6b monitoring → 7 email (inbound + outbound) → 8 accept.
Human-blocking steps get requested EARLY and in BATCHES — never serialize a build behind
a waiting human.
Reference timings from a real run (Page Byte, 2026-07): scaffold→compiling ~15 min,
skeleton live on Hosting same hour, Fly server + Postgres ~20 min, Auth enablement
2 clicks + 5 min, LS integration incl. lifecycle tests ~1h, domain purchase→live TLS
~40 min, GA4+monitoring ~45 min, admin panel + support inbox ~45 min. Same-day ship.
The debugging cycles that DIDN'T need to happen (and now shouldn't): CORS preflight,
the unique-email identity 500, prerender localStorage crash, forwarding-vs-CustomMX
inbox wipe. All are pre-empted above — read Phase 2 and Phase 7 before writing code.
