# /provision-agent

Make sure you are connected to your OWN always-on personal agent box: the tracer
that proves the whole chain before any client is ever minted. In Session 3 you
already stood up your cloud agent. Session 4 BUILDS ON THAT SAME BOX, it does not
provision a new one. The default here is to REUSE your Session-3 box (reconnect,
verify it is reachable), then the rest of `/setup` installs the minting engine and
deploys your surfaces onto it. Provisioning a brand-new box is an explicit FALLBACK,
only for an operator who does not already have a Session-3 box.

You are the guide. You run the steps; you own the judgment (SSH reachability,
the brain choice, error recovery). No key is ever printed back.

This command is about YOUR OWN box. Minting a client agent is a separate flow (the
dashboard "Mint an agent for <client>" button).

---

## Before anything else: open the key form and orient

If `.env` does not exist yet, run `./scripts/setup.sh` and tell the operator:

> "I am opening your key form now. It pops up in your browser on a secure one-time
> link. Keep that tab open. Every key goes there as we collect it. If it does not
> open on its own, tell me and I'll give you the exact address it printed."

Never hardcode or invent the port or token. `setup.sh` picks a free port, mints a
one-time token, opens the tokened URL, and prints `SETUP_URL=...`. If nothing
opened, read the printed `SETUP_URL=` line (the address with `?t=`) and give the
operator that URL verbatim.

Then read `PROGRESS.md`. Tell the operator where they are and the single next step.

---

## Phase 1: connect to your Session-3 box (DEFAULT, no charge)

Your Session-3 box already exists. We reuse it. Reusing costs nothing: no new box,
no new charge. Ask, one question at a time, explaining what each answer is for:

- "From Session 3, what is your agent box's IP address?" This is `AGENT_IP`. It may
  already be in `.env` (Session 3 wrote it when the box was created). Confirm it.
- "And the path to the SSH private key you used to reach that box (e.g.
  `~/.ssh/id_ed25519`)?" This is `SSH_KEY`. Confirm it is set.

Put both in `.env` via the key form (or confirm the values already there). Then
VERIFY the box is reachable WITHOUT printing any secret:

```
source lib/env.sh && load_env .env && require_env AGENT_IP
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
  ${SSH_KEY:+-i "$SSH_KEY"} "root@$AGENT_IP" \
  'tail -n5 /var/log/wingman-provision.log 2>/dev/null; echo CONNECTED'
```

If you see `CONNECTED` (and ideally `WINGMAN-PROVISION-DONE` in the tail), the box
is live and reachable. You are done here: skip the fallback entirely and continue
`/setup` to install the engine and deploy surfaces ONTO this box.
(`WINGMAN-PROVISION-DONE` is the box-side install-log token, not operator copy.)

If SSH fails, help the operator fix the basics first (correct IP, correct
`SSH_KEY`, the box is powered on in Hetzner). Only if they genuinely have NO
Session-3 box do you fall through to the fallback below.

Tick PROGRESS.md:
```
- [x] Reconnected to your Session-3 agent box (SSH reachable, no new charge)
```

---

## Fallback: provision a NEW box (ONLY if there is no Session-3 box)

Do NOT run this if Phase 1 connected. This path creates a real, billable box and is
only for an operator who never completed Session 3.

### F1: preflight and dry-run (free, spends nothing)

Validate keys WITHOUT printing any value:

```
source lib/env.sh && load_env .env && require_env HETZNER_TOKEN AGENT_NAME OPENAI_BASE_URL BRAIN_MODEL SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS
```

`OPENAI_API_KEY` is optional. If blank, the box comes up brain-less and the operator
connects a model by OAuth in the dashboard after provisioning (see F4).

Then show the operator exactly what WILL happen, at zero cost:

```
scripts/dry_run_all.sh
```

Confirm the final line is `DRY-RUN-ALL-OK`. The preview prints the real Hetzner and
Cloudflare request bodies with the token collapsed to a byte count. No API is hit.

### F2: create the box (FIRST CHARGE: always flag it)

Say:
> "Next step creates a real Hetzner box. Hetzner bills it HOURLY, capped at about
> $8 a month and prorated, so a quick test costs cents. This is the first charge.
> Shall I go ahead?"

Wait for an explicit yes. Then:

```
scripts/provision.sh
```

Capture `PROVISION-OK id=<id> ip=<ip>`. Hold the IP (it is also written to `.env`
as `AGENT_IP`). Then wait for first boot: poll

```
ssh root@<ip> 'tail -n50 /var/log/wingman-provision.log'
```

until `WINGMAN-PROVISION-DONE` appears (about 4 to 8 minutes). Do not continue until
it does.

Tick PROGRESS.md:
```
- [x] Hetzner box created (billed hourly, capped at about $8/mo prorated, you approved this charge first)
- [x] WINGMAN-PROVISION-DONE confirmed in the boot log
```

### F3: give the agent a private web address (Cloudflare)

```
scripts/cf_portal.sh
```

Capture `PORTAL-READY`, `URL=...`, and `TUNNEL_TOKEN=...`. Never print the token.
The dry-run already proved the ingress carries `httpHostHeader: localhost` (the 502
fix); the real run keeps it.

Then install the connector on the box (the token rides the encrypted SSH channel and
is never written to a file or printed):

```
scripts/install_connector.sh <ip> <TUNNEL_TOKEN>
```

Expect `CONNECTOR-OK`.

Tick PROGRESS.md: `- [x] Private web address live behind the Cloudflare email gate`

### F4: wire the brain, apps, and Slack

```
scripts/configure_box.sh <ip>
```

Expect `CONFIGURE-OK`. This wires Slack tokens + allowlist, and the brain when
`OPENAI_API_KEY` is set.

The brain footgun (proven): the provider MUST be `openai-api` with an EXPLICIT
`base_url`. An admin key cannot infer the endpoint. `configure_box.sh` sets exactly
`model.provider openai-api` + `model.base_url "$OPENAI_BASE_URL"`. For an always-on
agent an OpenRouter API key is the clean default (no automated-use ToS concerns).

If `OPENAI_API_KEY` was blank, tell the operator:
> "Your agent is up but has no brain yet. Open the dashboard, go to Providers, and
> connect your model by signing in (OAuth)."

Composio app OAuth is YOUR human-in-the-loop step. Tell the operator:
> "Now connect your apps in Composio: open the Composio dashboard, click Connect
> Apps, and OAuth each app you want your agent to use. I'll wait."

Tick PROGRESS.md:
```
- [x] Brain wired (openai-api + explicit base_url on the box)
- [x] Composio apps connected (OAuth through the Composio dashboard)
- [x] Slack connected (bot token + app token on the box)
```

### F5: move the agent up (judgment step)

Lift the operator's local SOUL, skills, and memory to the box:

```
scripts/move_up.sh <ip>
```

Expect `MOVE-UP-OK`. Then VERIFY the persona actually landed: DM the agent, or SSH
in and ask it "who do I serve?". The answer must name the operator in their SOUL's
voice. If it answers generically, the SOUL did not land. Re-check and retry before
calling this done.

Tick PROGRESS.md:
```
- [x] Local SOUL/memory/skills copied to the cloud box
- [x] Agent answers "who do I serve?" in your voice
```

---

## Verify and hand off

- Open the box's `URL=` in a browser. The Cloudflare email gate appears, the operator
  logs in, and the dashboard loads.
- DM the agent in Slack. The reply comes back as their own personal agent.

Tick PROGRESS.md:
```
- [x] Web address opens and the Cloudflare login gate appears
- [x] DM in Slack returns a reply from your agent
```

Tell the operator:
> "You are connected to your own always-on personal agent box, behind your email
> gate, talking in Slack. This is the tracer bullet. The rest of /setup installs the
> minting engine and deploys your surfaces onto THIS SAME box, and the same chain
> then mints an agent for each client. Welcome to the other side."
