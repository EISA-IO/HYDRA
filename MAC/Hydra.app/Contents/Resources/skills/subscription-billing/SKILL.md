---
name: subscription-billing
description: Build cutting-edge subscription infrastructure for a SaaS — recurring billing with Stripe (plans/prices, Checkout, Customer Portal, webhooks, entitlements, trials, proration, dunning, usage-based metering), plus emailing your subscribers (transactional receipts and broadcast campaigns/newsletters) via Resend/Postmark/SendGrid. Use whenever the user wants subscriptions, paid plans, tiers, "charge users monthly", a paywall, manage/cancel/upgrade flows, a billing portal, webhooks for subscription events, or to send email to subscribed users. KSA note: also covers Tap/Moyasar for local recurring payments.
---

# Subscription infrastructure + subscriber email

You are a senior billing engineer. Build subscriptions that are correct, secure, and recoverable — the source of truth for "is this user paid?" is **your database, updated by verified webhooks**, never the client. Never trust the browser to grant access.

## The mental model (get this right first)

```
Product  ──has many──▶  Price (monthly / yearly / usage)  ──▶  Checkout Session
                                                                     │
User picks a plan ─▶ Stripe Checkout (hosted) ─▶ Subscription created
                                                                     │
                         Stripe ─── webhook (signed) ───▶ your backend ─▶ DB: user.plan / status / current_period_end
                                                                     │
Your app reads DB entitlement ─▶ unlocks features. Customer Portal handles upgrade/cancel/card update.
```

Four pillars: **(1) Checkout** to start, **(2) Webhooks** to stay in sync, **(3) Entitlement check** in your app, **(4) Customer Portal** for self-service. Build all four.

---

## 1. Stripe setup

```bash
npm install stripe
# frontend (optional, for embedded elements): npm install @stripe/stripe-js
```
Env (server-only except the publishable key):
```
STRIPE_SECRET_KEY=sk_test_xxx
STRIPE_WEBHOOK_SECRET=whsec_xxx
STRIPE_PRICE_PRO_MONTHLY=price_xxx
STRIPE_PRICE_PRO_YEARLY=price_xxx
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_xxx   # safe on client
```
Create products & prices once (dashboard, or API/Stripe CLI). Store the `price_...` IDs in env, reference them by plan name in code.

## 2. Start a subscription — Checkout Session

```ts
import Stripe from "stripe";
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!);

// POST /api/checkout  { priceId }
export async function createCheckout(userId: string, email: string, priceId: string) {
  // Reuse one Stripe customer per user (store customerId on the user row).
  const customer = await getOrCreateCustomer(userId, email); // create once, persist customer.id
  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: customer.id,
    line_items: [{ price: priceId, quantity: 1 }],
    subscription_data: { trial_period_days: 14 },          // optional free trial
    allow_promotion_codes: true,
    success_url: `${process.env.APP_URL}/billing?success=1&session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${process.env.APP_URL}/pricing?canceled=1`,
    client_reference_id: userId,                            // maps the session back to your user
  });
  return session.url; // redirect the browser here
}
```

## 3. Stay in sync — the webhook (the heart of it)

Verify the signature with the RAW body, then upsert entitlement. This is what actually flips a user to "paid".
```ts
// POST /api/webhooks/stripe  — MUST receive the raw body (no JSON body-parser on this route)
export async function handleStripeWebhook(rawBody: Buffer, sig: string) {
  const event = stripe.webhooks.constructEvent(rawBody, sig, process.env.STRIPE_WEBHOOK_SECRET!);
  switch (event.type) {
    case "checkout.session.completed":
    case "customer.subscription.created":
    case "customer.subscription.updated": {
      const sub = await stripe.subscriptions.retrieve(
        (event.data.object as any).subscription ?? (event.data.object as any).id
      );
      await db.user.updateByCustomerId(sub.customer as string, {
        plan: planFromPriceId(sub.items.data[0].price.id),
        subscriptionStatus: sub.status,                    // active | trialing | past_due | canceled
        currentPeriodEnd: new Date(sub.current_period_end * 1000),
        cancelAtPeriodEnd: sub.cancel_at_period_end,
      });
      break;
    }
    case "customer.subscription.deleted":
      await db.user.updateByCustomerId((event.data.object as any).customer, {
        plan: "free", subscriptionStatus: "canceled",
      });
      break;
    case "invoice.payment_failed":
      // dunning: email the user to update their card; Stripe retries automatically
      await sendEmail(userEmailByCustomer(event), "paymentFailed");
      break;
  }
  return { received: true };
}
```
Local testing: `stripe listen --forward-to localhost:3000/api/webhooks/stripe` (the Stripe CLI prints a `whsec_...` to use as your secret). **Idempotency:** store processed `event.id`s (or upsert idempotently) so retried webhooks don't double-apply.

## 4. Gate features — entitlement check

Single source of truth = your DB row, refreshed by webhooks.
```ts
function isActive(user) {
  return ["active", "trialing"].includes(user.subscriptionStatus)
      && user.currentPeriodEnd > new Date();
}
// middleware
if (!isActive(user)) return res.status(402).json({ error: "subscription required" });
```
Never gate on a client flag or the Checkout success redirect alone (the webhook may arrive a beat later — reconcile on the billing page by fetching the subscription).

## 5. Self-service — Customer Portal (upgrade / cancel / update card)

```ts
// POST /api/portal
const portal = await stripe.billingPortal.sessions.create({
  customer: user.stripeCustomerId,
  return_url: `${process.env.APP_URL}/billing`,
});
return portal.url; // redirect
```
Configure allowed actions once in Dashboard → Billing → Customer Portal (cancel, switch plan, proration behavior, invoice history). This removes almost all custom billing UI.

## 6. Advanced billing (use when needed)

- **Trials**: `subscription_data.trial_period_days`, or set a trial on the price. Handle `trialing` as active.
- **Proration**: Stripe prorates on plan switch by default; control with `proration_behavior`.
- **Usage-based / metered**: create a metered price; report usage with `stripe.subscriptionItems.createUsageRecord(itemId, { quantity, timestamp })`. Bill per seat with `quantity`.
- **Dunning**: enable Smart Retries + the built-in "past_due" emails in Dashboard → Billing → Revenue Recovery; also handle `invoice.payment_failed` yourself.
- **Tax**: enable Stripe Tax (`automatic_tax: { enabled: true }`) for VAT/sales tax.
- **Annual + monthly**: one product, two prices; offer both, let the Portal switch.

## 7. KSA / regional recurring (Tap & Moyasar)

Stripe isn't available for KSA-domiciled businesses — use a local PSP for recurring:
- **Tap Payments**: tokenize the card (Card SDK) → create a saved-card token → charge on a schedule via your own cron, or use Tap subscriptions where available. Amount is in **major units** (10.00 SAR = `10.00`). Verify the `hashstring` on webhooks. Methods: mada, Apple Pay, STC Pay, cards.
- **Moyasar**: save a `token` source, then `POST /payments` with `source.type = "token"` on your billing cadence. Amount is in **halalas** (10.00 SAR = `1000`, ×100 — opposite of Tap). Verify the `secret_token` on the webhook.
- For both: you own the recurrence (a scheduled job charges the saved token each period), your DB holds the subscription state, and you email receipts/dunning yourself.

---

## 8. Emailing your subscribers

Two distinct jobs — don't mix them:
1. **Transactional** (one recipient, triggered by an event): welcome, receipt, payment failed, trial ending, password reset. High deliverability, sent from your API.
2. **Broadcast / campaign** (many recipients): newsletters, product updates, announcements to all paid users. Must honor unsubscribe.

### Provider choice
- **Resend** — modern, great DX, React Email templates. `npm install resend`.
- **Postmark** — best transactional deliverability, separate message streams for transactional vs broadcast.
- **SendGrid** — mature, has Marketing Campaigns for broadcasts.

### Transactional (Resend)
```ts
import { Resend } from "resend";
const resend = new Resend(process.env.RESEND_API_KEY);

await resend.emails.send({
  from: "Acme <billing@yourdomain.com>",   // must be a verified domain
  to: user.email,
  subject: "Welcome to Pro 🎉",
  html: renderWelcome(user),               // or react: <WelcomeEmail .../> via @react-email
});
```
Wire these to billing events: on `checkout.session.completed` → welcome; `invoice.paid` → receipt; `invoice.payment_failed` → update-card; `customer.subscription.updated` with `cancel_at_period_end` → win-back.

### Broadcast to all subscribers
```ts
// Fetch the audience from YOUR db (paid + opted-in), then send in batches with unsubscribe links.
const subs = await db.user.findMany({
  where: { subscriptionStatus: { in: ["active", "trialing"] }, emailOptIn: true },
});
// Resend Broadcasts / audiences, or batch send:
for (const batch of chunk(subs, 100)) {
  await resend.batch.send(batch.map(u => ({
    from: "Acme <news@yourdomain.com>",
    to: u.email,
    subject: "What's new in Acme",
    html: renderNewsletter(u) + unsubscribeFooter(u),   // one-click unsubscribe REQUIRED
  })));
}
```

### Deliverability & compliance (non-negotiable)
- **Verify your sending domain**: add SPF, DKIM, and DMARC DNS records (the provider gives them). Without these you land in spam.
- **One-click unsubscribe** on every broadcast (List-Unsubscribe header + footer link). Store the opt-out and never send again. Required by CAN-SPAM / GDPR / Gmail & Yahoo bulk-sender rules.
- **Separate streams**: keep transactional and marketing on different subdomains/streams so a marketing complaint never blocks receipts.
- Track bounces/complaints via the provider's webhook and suppress bad addresses.
- Never email people who didn't opt in. Double opt-in for newsletters is safest.

---

## 9. Data model (minimum)

```
User { id, email, emailOptIn, stripeCustomerId,
       plan, subscriptionStatus, currentPeriodEnd, cancelAtPeriodEnd }
WebhookEvent { id (stripe event id), processedAt }        // idempotency
EmailLog { id, userId, type, sentAt, status }             // audit + suppression
```

## 10. Ship checklist

- [ ] Webhook signature verified with the RAW body; endpoint idempotent.
- [ ] Entitlement read from DB, refreshed only by webhooks — never client-trusted.
- [ ] Customer Portal enabled for cancel/upgrade/card update.
- [ ] Trial, proration, and `past_due`/dunning paths handled.
- [ ] Secrets server-side; only the publishable key is client-side.
- [ ] Sending domain has SPF + DKIM + DMARC; broadcasts have one-click unsubscribe.
- [ ] Test cards used (`4242 4242 4242 4242`); go live only after a real end-to-end subscribe → webhook → unlock → cancel test.
- [ ] `stripe listen` used to verify webhooks locally before deploy.
