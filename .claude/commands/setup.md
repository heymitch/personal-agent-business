# /setup -- The Operator's Entry Point

This is a GUIDED SETUP for a non-technical person. You are walking an operator
from a downloaded folder to a running personal agent business.

DO NOT analyze, document, summarize, or /init this repository. Do not make the
operator read a script. You run the scripts; you narrate what happens; you own
the judgment calls.

---

## Step 1 -- Greet

Say exactly:

> "I'm your Cockpit -- I'll walk you through standing up your personal agent
> business, one step at a time, and I'll explain everything as we go. Nothing
> bills until you say so."

---

## Step 2 -- Open the key form

Run `./scripts/setup.sh` and tell the operator:

> "I am opening your key form now. It will pop up in your browser with a secure
> one-time link. Keep that tab open -- every key goes there as we collect it. If
> it does not open on its own, tell me and I'll give you the exact address it
> printed."

Never hardcode or invent the port or token. `setup.sh` picks a free port, mints a
one-time token, opens the tokened URL, and prints it as `SETUP_URL=...`. If the
operator says nothing opened, read the printed `SETUP_URL=` line (the address
with `?t=`) and give it to them verbatim.

The form collects every OPERATOR key: Hetzner, the brain admin key + base URL +
model, AgentMail, Composio, Cloudflare, Vercel, and Slack. It writes them to
`.env` (gitignored) and never echoes a value back.

---

## Step 3 -- Orient from PROGRESS.md

Read `PROGRESS.md`. Tell the operator in one or two plain sentences where they
are and the single next step. Do not list options.

---

## Step 4 -- Preflight + dry-run (free)

Once the keys are in, validate them without printing any value, then preview the
whole chain at zero cost:

```bash
source lib/env.sh && load_env .env
scripts/dry_run_all.sh
```

`dry_run_all.sh` touches no real API and spends nothing. It prints
`DRY-RUN-ALL-OK` as its last line when the preview is clean. Confirm that token
to the operator in plain English before any billable step.

---

## Step 5 -- Stand up the business (the clone-to-live run)

`/setup` is the ONE guided flow from a downloaded folder to a live business. Run
these phases IN ORDER, with a checkpoint between each. Every phase is IDEMPOTENT:
re-running `/setup` safely skips or repeats completed steps, so it is always safe
to resume here after a stop.

Before each phase, glance at `PROGRESS.md` (and you may run `/doctor` to see what
is already green). If a phase's box is already ticked and `/doctor` shows it
healthy, tell the operator it is done and move to the next. Otherwise run it.

1. **Connect to your Session-3 agent box** -> run `/provision-agent`. You already
   stood this box up in Session 3, so the DEFAULT is to REUSE it: reconnect with
   your `AGENT_IP` + `SSH_KEY` and verify it is reachable over SSH. No new box, no
   new charge. Everything below installs onto THIS SAME box. (Only if the operator
   has no Session-3 box does `/provision-agent` fall back to provisioning a new one,
   which is the FIRST CHARGE: billed HOURLY, capped at about $8 a month and
   prorated, so a quick test costs cents. Flag it and wait for a "yes" first.)
   Confirm the agent answers in the owner's voice before moving on.
2. **Your selling surfaces** -> run `/deploy-surfaces`. Deploys the console +
   onboarding + landing to the operator's Vercel and seeds `ONBOARDER_BASE_URL`.
3. **Your minting engine** -> run `scripts/deploy_engine.sh` (over SSH to the box
   from step 1). Installs the receiver + the reconcile timer. Confirm
   `ENGINE-DEPLOYED`.
4. **Your daily maintenance** -> run `scripts/deploy_maintenance.sh` (same box,
   same SSH channel). Installs the two DAILY timers: `hermes-update.timer` (keeps
   the personal agent current) and `git-backup.timer` (pushes agency state to your
   backup remote, never secrets). Confirm `MAINTENANCE-DEPLOYED`.

After each phase: report the outcome in plain English, tick the matching checkbox
in `PROGRESS.md`, and tell the operator the single next step.

---

## Step 6 -- Verify everything is live

Close the loop with the health check:

```bash
scripts/doctor.sh
```

When it prints `DOCTOR-OK`, the clone-to-live run is complete. If it prints
`DOCTOR-FAIL component=<name>`, repair the named piece (each repair step is
idempotent, see `/doctor`) and re-run until `DOCTOR-OK`.

Final handoff, once `DOCTOR-OK`:

> "Your personal agent business is live. Mint a client agent anytime from your
> dashboard -- click 'Mint an agent for <client>' and I take it from there."

---

## Guardrails

- Never print a secret. Read `.env`, pass values to scripts, report "set / works".
- Flag any charge clearly before it runs and wait for a yes.
- Idempotent: every phase is safe to re-run; `/setup` resumes, it never double-charges.
- Buyer-facing and client-facing copy is always "personal agent", never "wingman".
- If the operator runs /init or asks you to analyze the code, say: "This is your
  setup cockpit, not code to read -- let's get your personal agent business live."
  Then continue the setup journey.
