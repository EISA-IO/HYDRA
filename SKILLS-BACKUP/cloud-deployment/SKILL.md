---
name: cloud-deployment
description: Ship a website or full-stack app to the cloud fast — Firebase Hosting, Vercel, or Google Cloud Run — with a real backend (Firebase Functions + Firestore, Vercel serverless /api, or a containerized Cloud Run API). Use whenever the user wants to deploy, go live, set up hosting, add a backend/API, wire a database, configure custom domains, secrets, CI/CD, or troubleshoot a failed deploy. Covers the whole project lifecycle: scaffold → build → deploy → connect backend → secure → observe.
---

# Cloud Deployment — full project lifecycle

You are an expert deployment engineer. Get the user's site live quickly and correctly, with a working backend, without leaking secrets or leaving them in a half-deployed state. Prefer the platform that fits the app; don't force one.

## 0. Decide the target in 10 seconds

| App shape | Best target | Backend |
|---|---|---|
| Static site / SPA (Vite, CRA, plain HTML) | **Firebase Hosting** or **Vercel** | Firebase Functions, or Vercel `/api` |
| Next.js / Nuxt / SvelteKit (SSR) | **Vercel** (zero-config) | built-in serverless / edge |
| Long-running server, WebSockets, Docker, any language, >10s requests, background work | **Cloud Run** | the container itself |
| Needs Firestore/Auth/Storage tightly | **Firebase** (Hosting + Functions) | Firestore + Firebase Auth |

Rules of thumb: **Vercel** = fastest for frontend frameworks. **Firebase** = best when you want Firestore + Auth + Hosting as one bundle. **Cloud Run** = when you need a real always-available container (any language, any runtime, scales to zero).

Always confirm: (1) which provider, (2) is there a backend/API, (3) is there a database. Then scaffold config, then deploy.

## 1. Prerequisites (check first, install once)

```bash
node -v && npm -v            # Node 18+ for all CLIs
firebase --version || npm install -g firebase-tools
vercel --version   || npm install -g vercel
gcloud --version   || echo "install Google Cloud SDK (see below)"
docker --version             # only needed for custom Cloud Run images
```

- **firebase-tools**: `npm install -g firebase-tools`
- **vercel**: `npm install -g vercel`
- **gcloud**: not on npm. macOS: `brew install --cask google-cloud-sdk` (or the interactive installer from https://cloud.google.com/sdk/docs/install). Then `gcloud init`.

Never commit secrets. Put keys in `.env.local` / platform secret stores and add them to `.gitignore`.

---

## 2. Firebase Hosting (+ Functions + Firestore)

### Deploy a static site / SPA
```bash
firebase login
firebase init hosting          # pick/create project; public dir = "dist" (Vite) or "build" (CRA); SPA rewrite = Yes
npm run build                  # produce the public dir
firebase deploy --only hosting
```

`firebase.json` for a Vite SPA:
```json
{
  "hosting": {
    "public": "dist",
    "ignore": ["firebase.json", "**/.*", "**/node_modules/**"],
    "rewrites": [{ "source": "**", "destination": "/index.html" }]
  }
}
```
`.firebaserc` pins the project:
```json
{ "projects": { "default": "your-project-id" } }
```

### Add a backend — Firebase Functions (2nd gen, runs on Cloud Run under the hood)
```bash
firebase init functions        # language: TypeScript; installs deps in ./functions
```
`functions/src/index.ts`:
```ts
import { onRequest } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2";
setGlobalOptions({ region: "us-central1", maxInstances: 10 });

export const api = onRequest(async (req, res) => {
  res.json({ ok: true, path: req.path });
});
```
Route the frontend to it — add to `firebase.json` hosting (BEFORE the SPA catch-all):
```json
"rewrites": [
  { "source": "/api/**", "function": "api" },
  { "source": "**", "destination": "/index.html" }
]
```
Deploy: `firebase deploy` (both), or `firebase deploy --only functions`.

### Firestore (database)
```bash
firebase init firestore        # writes firestore.rules + firestore.indexes.json
```
Server-side (inside a Function) use the Admin SDK:
```ts
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
initializeApp();
const db = getFirestore();
await db.collection("orders").add({ total: 1000, createdAt: Date.now() });
```
Lock down `firestore.rules` before going live — default-deny, then allow per-auth:
```
rules_version = '2';
service cloud.firestore {
  match /databases/{db}/documents {
    match /users/{uid}/{doc=**} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}
```
Deploy rules: `firebase deploy --only firestore:rules`.

### Secrets (Functions)
```bash
firebase functions:secrets:set STRIPE_API_KEY
```
Then in code: `import { defineSecret } from "firebase-functions/params"; const key = defineSecret("STRIPE_API_KEY");` and list it in the function's `secrets: [key]`.

### Custom domain
Firebase console → Hosting → Add custom domain → add the shown A/TXT records at your registrar.

---

## 3. Vercel (frontend + serverless backend)

### Deploy
```bash
vercel login
vercel            # first run links/creates the project, auto-detects the framework → preview URL
vercel --prod     # promote to production
```
Vercel auto-detects Next.js, Vite, CRA, SvelteKit, Astro, etc. — usually **no config needed**.

`vercel.json` only when you need overrides (SPA rewrite for a non-framework static build):
```json
{
  "rewrites": [{ "source": "/(.*)", "destination": "/" }]
}
```

### Backend — serverless functions in `/api`
Any file in `/api` becomes an endpoint. `api/hello.ts`:
```ts
export default function handler(req, res) {
  res.status(200).json({ ok: true, method: req.method });
}
```
`GET /api/hello` just works. Use Edge runtime for low latency: `export const config = { runtime: "edge" }`.

### Environment variables / secrets
```bash
vercel env add STRIPE_API_KEY production      # prompts for the value; also 'preview' / 'development'
vercel env pull .env.local                    # sync down for local dev
```
Client-exposed vars must be prefixed (`NEXT_PUBLIC_` / `VITE_`). Everything else stays server-only.

### Database on Vercel
Vercel has no DB of its own — connect a managed one: **Neon/Supabase (Postgres)**, **Upstash (Redis)**, **PlanetScale (MySQL)**, or **MongoDB Atlas**. Put the connection string in `DATABASE_URL` env var and use Prisma / the vendor SDK. For Postgres from serverless, use a pooled/serverless driver (Neon serverless, `@vercel/postgres`).

### Custom domain
`vercel domains add example.com` then follow the DNS instructions, or add it in the dashboard.

---

## 4. Google Cloud Run (containerized backend / full-stack, any language)

Cloud Run runs a container that listens on `$PORT` (default **8080**) on `0.0.0.0`. Scales to zero, pay per request. Two ways to deploy: **source** (buildpacks, no Dockerfile) or **image** (your Dockerfile).

### One-command deploy from source (no Dockerfile)
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud run deploy api \
  --source . \
  --region us-central1 \
  --allow-unauthenticated
```
Cloud Buildpacks detect Node/Python/Go/etc. and build for you. First deploy enables the needed APIs (say yes).

### Dockerfile (full control) — Node example
```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
ENV NODE_ENV=production
# Cloud Run injects PORT; the app MUST listen on it.
EXPOSE 8080
CMD ["node", "server.js"]
```
The server MUST bind `process.env.PORT`:
```js
const port = process.env.PORT || 8080;
app.listen(port, "0.0.0.0", () => console.log(`up on ${port}`));
```
`.dockerignore`:
```
node_modules
npm-debug.log
.git
.env*
```
Deploy the image:
```bash
gcloud run deploy api --source . --region us-central1 --allow-unauthenticated
# or build+push then deploy:
gcloud builds submit --tag gcr.io/YOUR_PROJECT_ID/api
gcloud run deploy api --image gcr.io/YOUR_PROJECT_ID/api --region us-central1 --allow-unauthenticated
```

### Env vars & secrets
```bash
gcloud run deploy api --set-env-vars "NODE_ENV=production,APP_URL=https://..." ...
# secrets via Secret Manager (preferred for keys):
echo -n "sk_live_xxx" | gcloud secrets create STRIPE_API_KEY --data-file=-
gcloud run deploy api --update-secrets "STRIPE_API_KEY=STRIPE_API_KEY:latest" ...
```

### Database — Cloud SQL (Postgres/MySQL)
```bash
gcloud run deploy api \
  --add-cloudsql-instances YOUR_PROJECT:us-central1:INSTANCE \
  --set-env-vars "DATABASE_URL=postgres://user:pass@/db?host=/cloudsql/YOUR_PROJECT:us-central1:INSTANCE" ...
```
Or use a serverless Postgres (Neon/Supabase) via a plain `DATABASE_URL` — simpler, no VPC.

### Custom domain
`gcloud run domain-mappings create --service api --domain api.example.com --region us-central1`, then add the shown DNS records. (Or map via a load balancer for apex domains.)

---

## 5. Frontend + separate backend (common full-stack shape)

- **Frontend** on Vercel or Firebase Hosting (static/SSR).
- **Backend API** on Cloud Run (or Functions).
- Wire them: set the frontend's API base URL env var (`VITE_API_URL` / `NEXT_PUBLIC_API_URL`) to the Cloud Run URL.
- **CORS**: the API must allow the frontend origin. Express: `app.use(cors({ origin: "https://your-frontend.vercel.app", credentials: true }))`.
- Prefer same-origin via a rewrite/proxy when possible (Firebase `/api/**` → function, or Vercel `rewrites` to the Cloud Run URL) so you avoid CORS and cookie issues entirely.

---

## 6. GitHub as the core repo + CI/CD (deploy on push)

Keep the project in a **private GitHub repo** as the source of truth, and let GitHub Actions deploy every push to `main`. Create + push the repo:
```bash
gh auth login
git init -b main && git add -A && git commit -m "Initial commit"
gh repo create <name> --private --source . --remote origin --push
```
Add `.env*`, `node_modules`, and build output to `.gitignore` BEFORE the first commit.

### GitHub Actions → Vercel  (`.github/workflows/deploy-vercel.yml`)
Secrets: `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID` (get the IDs from `.vercel/project.json` after `vercel link`).
```yaml
name: Deploy to Vercel
on: { push: { branches: [main] } }
env:
  VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}
  VERCEL_PROJECT_ID: ${{ secrets.VERCEL_PROJECT_ID }}
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm install -g vercel
      - run: vercel pull --yes --environment=production --token=${{ secrets.VERCEL_TOKEN }}
      - run: vercel build --prod --token=${{ secrets.VERCEL_TOKEN }}
      - run: vercel deploy --prebuilt --prod --token=${{ secrets.VERCEL_TOKEN }}
```

### GitHub Actions → Firebase Hosting  (`.github/workflows/deploy-firebase.yml`)
Secret: `FIREBASE_SERVICE_ACCOUNT` (JSON). Easiest: `firebase init hosting:github` auto-creates the SA + secret + workflow.
```yaml
name: Deploy to Firebase Hosting
on: { push: { branches: [main] } }
jobs:
  build_and_deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci && npm run build --if-present
      - uses: FirebaseExtended/action-hosting-deploy@v0
        with:
          repoToken: ${{ secrets.GITHUB_TOKEN }}
          firebaseServiceAccount: ${{ secrets.FIREBASE_SERVICE_ACCOUNT }}
          channelId: live
          projectId: your-project-id
```

### GitHub Actions → Cloud Run  (`.github/workflows/deploy-cloudrun.yml`)
Secret: `GCP_SA_KEY` (JSON with Cloud Run Admin + Cloud Build Editor + Service Account User + Storage Admin).
```yaml
name: Deploy to Cloud Run
on: { push: { branches: [main] } }
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: google-github-actions/auth@v2
        with: { credentials_json: ${{ secrets.GCP_SA_KEY }} }
      - uses: google-github-actions/setup-gcloud@v2
      - run: gcloud run deploy SERVICE --source . --region REGION --project PROJECT --allow-unauthenticated
```
Set secrets with `gh secret set NAME` (reads a value or `< file.json`). Never commit the key files — delete them after uploading. PR previews: Firebase's action posts a preview channel per PR; Vercel does the same when `vercel deploy` runs without `--prod`.

---

## 7. Pre-launch checklist (do NOT skip)

- [ ] Secrets in the platform's secret store, not in the repo. `.env*` in `.gitignore`.
- [ ] Firestore/Storage rules are default-deny + explicit allow (never leave test-mode open rules in prod).
- [ ] Build succeeds locally (`npm run build`) before deploying.
- [ ] Backend binds `$PORT` / `0.0.0.0` (Cloud Run) — the #1 cause of "container failed to start".
- [ ] CORS restricted to the real frontend origin.
- [ ] Custom domain + HTTPS (all three platforms issue certs automatically).
- [ ] Set `--max-instances` / function `maxInstances` to cap cost.
- [ ] Health check / smoke test the live URL after deploy.

## 8. Troubleshooting

- **Cloud Run "container failed to start / didn't listen on PORT"** → app isn't binding `process.env.PORT` on `0.0.0.0`. Fix the listen call.
- **Firebase deploy "functions did not deploy"** → run `npm run build` in `functions/`, check Node runtime in `functions/package.json` `engines`, and that billing (Blaze plan) is enabled — Functions require it.
- **Vercel 404 on refresh of a SPA route** → add the catch-all rewrite to `/`.
- **`permission denied` on gcloud** → `gcloud auth login`, `gcloud config set project ID`, enable APIs: `gcloud services enable run.googleapis.com cloudbuild.googleapis.com`.
- **CORS errors in browser** → the API isn't allowing the frontend origin (and preflight `OPTIONS`).
- **Env var undefined in prod** → set it in the platform (not just `.env.local`), and redeploy; client vars need the `NEXT_PUBLIC_`/`VITE_` prefix.

## 9. Fast-path recipes

**Static SPA → Vercel, live in 60s:** `npm run build` → `vercel --prod`.
**SPA + Firestore + Auth → Firebase:** `firebase init hosting,functions,firestore` → build → `firebase deploy`.
**Any-language API → Cloud Run, live in 2 min:** ensure it listens on `$PORT` → `gcloud run deploy api --source . --region us-central1 --allow-unauthenticated`.

Always end by printing the live URL and running one smoke request against it.
