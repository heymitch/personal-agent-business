# /doctor -- Is everything healthy?

A single, READ-ONLY health check across your whole personal agent business. It
touches nothing, changes nothing, and never prints a secret value. Run it anytime
you want to know "is my setup still good?" -- after setup, after a change, or if
something feels off.

You are the guide. Run the script, read the result back in plain English, and if
anything is broken, name the ONE next action that fixes it.

---

## Run it

```bash
source lib/env.sh && load_env .env
scripts/doctor.sh
```

`doctor.sh` probes four things and prints a `[PASS]` or `[FAIL]` line for each:

| Component  | What it confirms                                                       |
|------------|------------------------------------------------------------------------|
| `keys`     | Every operator key is present in `.env` (reported as "set", never the value) |
| `box`      | Your own always-on box answers over SSH (`AGENT_IP`)                    |
| `engine`   | The receiver and the timers are running on the box (reconcile + the two daily maintenance timers) |
| `surfaces` | Your deployed Vercel surface URL(s) respond                            |

The last line is the verdict:

- `DOCTOR-OK` -- every check passed. Tell the operator plainly: "All green."
- `DOCTOR-FAIL component=<name> ...` -- one or more pieces are broken; each broken
  component is named.

---

## Read the result back

If `DOCTOR-OK`: say "Everything checks out. Your business is healthy." Done.

If `DOCTOR-FAIL`, map each named component to its fix and offer the SINGLE next step:

- `component=keys` -> a key is missing. Re-open the key form (`/setup` step 2) and fill the blank.
- `component=box` -> the box is unreachable. Re-run `/provision-agent` (or check the box is up).
- `component=engine` -> the receiver or a timer is down. Re-run the engine + maintenance install (`scripts/deploy_engine.sh`, `scripts/deploy_maintenance.sh`).
- `component=surfaces` -> a surface URL did not respond. Re-run `/deploy-surfaces`.

Each underlying step is idempotent (safe to re-run), so repairing one piece never
disturbs the others. After a repair, run `/doctor` again to confirm `DOCTOR-OK`.

---

## Guardrails

- Read-only: `/doctor` never changes anything. It is always safe to run.
- Never print a secret. Keys are reported as "set / missing", never their value.
- Buyer-facing copy is always "personal agent", never "wingman".
