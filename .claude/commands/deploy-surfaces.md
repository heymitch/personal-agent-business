# /deploy-surfaces

Deploy the three client-facing surfaces to the operator's OWN Vercel:

- **onboarding** the connect-on-page where each client picks and authorizes their
  apps (vendored, ready to ship).
- **landing** the public offer page the operator brands with their own copy.
- **operator-console** the minting dashboard. The "Mint an agent" button is a stub
  in this slice (it returns a clear "not connected yet" notice); a later slice wires
  it to real provisioning.

You are the guide. Walk the operator from a built repo to three live URLs, one step
at a time. You run the deploy script; you own the judgment steps (confirming Vercel
auth, branding the landing copy, reading the URLs back). No key is ever printed back.

---

## Before anything else: branding the landing page

The landing page ships as a NEUTRAL template with eleven labeled placeholder slots
(hero, social proof, problem, solution, how it works, features, offer, testimonials,
pricing, FAQ, final CTA). It is NOT pre-written marketing copy: the operator brands
it with their own offer.

Ask, one question at a time:

> "Your landing page is a clean shell with eleven slots to fill. Do you want to
> generate the copy now with a landing prompt, or deploy the shell first and fill it
> after? Either is fine. The shell deploys and renders as-is."

If they want copy now, point them at the workspace landing/offer skills to draft it,
then paste each section into `surfaces/landing/index.html` (replace every `[[ SLOT ]]`
and the `#cta` link). Do not write the marketing copy for them; the operator owns the
brand voice. The placeholders are clearly labeled so nothing is ambiguous.

---

## Step 1: confirm Vercel is connected in Claude Code (free)

Vercel auth is a Claude Code connection, not a pasted token. Confirm the operator is
connected by checking the logged-in CLI session:

```
vercel whoami
```

If that prints a username, Vercel is connected. If it errors, have the operator run
`vercel login` once (no token to copy, no key to store). Then confirm `COMPOSIO_API_KEY`
is present (validate WITHOUT printing the value):

```
source lib/env.sh && load_env .env && require_env COMPOSIO_API_KEY
```

If `COMPOSIO_API_KEY` is missing, send the operator to the key form (`./scripts/setup.sh`)
to add it. It is needed by the onboarding page's serverless functions (it lists the app
catalog and mints connect links). No Vercel token is required.

---

## Step 2: preview the deploy (free, spends nothing)

Show the operator exactly what WILL happen, at zero cost:

```
scripts/deploy_surfaces.sh --dry-run
```

This prints the per-surface `vercel deploy --prod` command sequence with every secret
collapsed to a byte count. No deploy runs. Confirm all three surfaces appear:
onboarding, landing, operator-console.

---

## Step 3: deploy the three surfaces

```
scripts/deploy_surfaces.sh
```

This pushes each surface to the operator's Vercel in order (onboarding, then landing,
then console), setting `COMPOSIO_API_KEY` into the onboarding project's Vercel env so
its functions work in production. Capture the success line:

```
SURFACES-DEPLOYED onboarding=<url> landing=<url> console=<url>
```

Read the three URLs back to the operator plainly. Never print the Vercel token.

---

## Step 4: set ONBOARDER_BASE_URL from the onboarding URL

The onboarding URL is the base the client invite links are built from. Write it back
into `.env` so the later minting flow can hand each client their connect link:

```
ONBOARDER_BASE_URL=<the onboarding url from Step 3>
```

Use the key form or edit `.env` directly. Confirm with:

```
source lib/env.sh && load_env .env && redact ONBOARDER_BASE_URL
```

---

## Step 5: verify and hand off

- Open the **landing** URL. The template renders with its placeholder slots (or the
  operator's filled copy). Confirm the page loads.
- Open the **onboarding** URL with a test `?user=` parameter. The app catalog loads
  and the Slack invite step shows.
- Open the **operator-console** URL. The mint form shows the client account dropdown
  (optional), person name, and person email, plus a capabilities picker. The
  capabilities (including "Voice-match my writing") are a per-client, build-time
  choice you make LATER when you actually mint a client's agent, NOT a setup step.
  Do not fill anything in now and do not ask the operator for their writing voice
  here: voice-match is configured with the client's own samples at build time. Click
  "Mint an agent": it returns the "not connected yet" notice. That is correct for this
  slice. The button wires to real provisioning later.

Tell the operator:

> "Your three surfaces are live: a landing page you brand, the client onboarding
> connect page, and your operator console. The mint button is a placeholder for now,
> we wire it to real provisioning next. Fill in your landing copy whenever you like
> and redeploy."
