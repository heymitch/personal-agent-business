# /provision-agent

Stand up the operator's OWN always-on personal agent: the tracer bullet that
proves the whole provisioning chain before any client is ever minted. You are the
guide. Walk the operator from `.env` to a live, always-on agent one step at a time,
narrating as you go. You run the scripts; you own the judgment steps (OAuth
approvals, the brain choice, move-up, error recovery). No key is ever printed back.

This command provisions YOUR box. Minting a client agent is a separate flow (the
dashboard "Mint an agent for <client>" button, wired in a later slice). Here we get
the operator's own agent live first, so the rest of the build has a proven chain.

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

Ask, one question at a time, and explain what each answer is for before asking:

- "What do you want to call your agent? (short, lowercase, e.g. 'mitch' or 'kai')"
  This becomes `AGENT_NAME`. Record in PROGRESS.md: `Agent name: <answer>`.

Do not ask for keys until the step that needs them.

---

## Phase 1: gather keys (free)

If `.env` does not exist: `cp .env.example .env` and either walk the operator
through `./scripts/setup.sh` (guided browser form) or have them fill `.env` by hand.

Tick PROGRESS.md: `- [x] .env created and keys filled in`

---

## Phase 2: preflight and dry-run (free, spends nothing)

Validate keys WITHOUT printing any value:

```
source lib/env.sh && load_env .env && require_env HETZNER_TOKEN AGENT_NAME OPENAI_BASE_URL BRAIN_MODEL SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS
```

`OPENAI_API_KEY` is optional. If blank, the box comes up brain-less and the operator
connects a model by OAuth in the dashboard after provisioning (see Phase 5).

Then show the operator exactly what WILL happen, at zero cost:

```
scripts/dry_run_all.sh
```

Confirm the final line is `DRY-RUN-ALL-OK`. The preview prints the real Hetzner and
Cloudflare request bodies with the token collapsed to a byte count. No API is hit.

Tick PROGRESS.md:
```
- [x] Keys validated (no values printed)
- [x] Dry-run completed: you saw what will happen
```

---

## Phase 3: create the box (FIRST CHARGE: always flag it)

Say:
> "Next step creates a real Hetzner box (about EUR 7.50/mo). This is the first
> charge. Shall I go ahead?"

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
it does. (`WINGMAN-PROVISION-DONE` is the box-side install log token, not operator
copy: it is the sentinel the install log emits.)

Tick PROGRESS.md:
```
- [x] Hetzner box created (~EUR 7.50/mo, you approved this charge first)
- [x] WINGMAN-PROVISION-DONE confirmed in the boot log
```

---

## Phase 4: give the agent a private web address (Cloudflare)

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

---

## Phase 5: wire the brain, apps, and Slack

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

---

## Phase 6: move the agent up (judgment step)

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

## Phase 7: verify and hand off

- Open the `URL=` from Phase 4 in a browser. The Cloudflare email gate appears, the
  operator logs in, and the dashboard loads.
- DM the agent in Slack. The reply comes back as their own personal agent.

Tick PROGRESS.md:
```
- [x] Web address opens and the Cloudflare login gate appears
- [x] DM in Slack returns a reply from your agent
```

Tell the operator:
> "Your own always-on personal agent is live, behind your email gate, talking in
> Slack, and it knows who it serves. This is the tracer bullet: the same chain now
> mints an agent for each client. Welcome to the other side."
