# CONTRIBUTING.md -- Developer / Contributor Reference

This file is for people editing the repo. It is NOT loaded as the operator's
guide. The operator's guide is `CLAUDE.md`. The operator's entry point is the
`/setup` command.

---

## Toolchain

`bats`, `shellcheck`, `jq` (all via Homebrew). Scripts target `bash` with
`set -euo pipefail`. The setup UI is stdlib-only Python 3. Later slices add a
vendored TypeScript installer (`tsx` + `vitest`) and Vercel surfaces.

## Commands

```bash
bats test/                                   # full suite
bats test/env.bats                           # one file
bats test/env.bats --filter "require_env"    # one test (substring on its name)
shellcheck -x scripts/*.sh lib/*.sh          # lint (also enforced by test/lint.bats)
scripts/dry_run_all.sh                       # free end-to-end preview -> "DRY-RUN-ALL-OK"
```

---

## Architecture

- **`lib/env.sh`** is the secret-safe core. `load_env` sources `.env` (KEY=VALUE,
  eval'd as bash); `require_env` exits non-zero listing only the NAMES of missing
  keys; `redact` returns "set (N chars)" / "MISSING". Nothing here echoes a value.

- **`scripts/` are deterministic** and emit a grep-able success token on stdout
  (not just an exit code). API / money-touching scripts (added in later slices)
  support `--dry-run`, which prints the request body with secrets collapsed to a
  byte count. SSH-only scripts self-validate with a no-args `usage:` guard that
  `dry_run_all.sh` asserts on.

- **`setup-ui/`** is a stdlib-only Python localhost dashboard (`server.py` +
  `index.html`) that writes `.env` for non-technical operators. Binds 127.0.0.1,
  one-time token per session, only writes keys present in `.env.example`, masks
  secrets, auto-shuts down when idle.

- **`.claude/commands/`** holds the judgment-heavy flows the Cockpit narrates.

---

## Success-token contract

Scripts signal success with a grep-able token on stdout, not just exit code:

| Script               | Success token                  |
|----------------------|--------------------------------|
| `dry_run_all.sh`     | `DRY-RUN-ALL-OK`               |
| `setup.sh`           | `SETUP_URL=http://127.0.0.1:<port>?t=<token>` |

Later slices add: `provision.sh` -> `PROVISION-OK id=<id> ip=<ip>`;
`cf_portal.sh` -> `PORTAL-READY`; `deploy_surfaces.sh` -> `SURFACES-DEPLOYED`;
`mint_client_agent.sh` -> `MINT-OK user_id=<id> ip=<ip>`. Orchestration keys off
these tokens. Preserve them when editing.

---

## Testing conventions

- Tests PATH-shim fake `curl`/`ssh`/`jq`/`cloudflared` via `make_fake_bin`
  (`test/test_helper.bash`) so no test touches a real API or box.

- Guards must be "teethy" (mutation-proven): a dropped check must make a test
  FAIL, not pass silently. When adding a guard, also add the assertion that fails
  without it. Never end a teeth test on a bare `[[ ]]` -- bind it to a `run` +
  status/output assertion so errexit cannot mask a regression.

- `setup_ui.bats` boots the server on a DYNAMIC free port (parsed from the
  printed `SETUP_URL=`), never a hardcoded port.

- `test/lint.bats` enforces shellcheck, `bash -n` parse, and that `.env` is never
  git-tracked. Keep `.env` in `.gitignore`.

---

## Invariants (do not regress)

- Never print a secret. Pass `.env` values into scripts; report "set" / "works".
- Every billable action (the first Hetzner box) is flagged and confirmed first.
- Buyer-facing and client-facing copy is always "personal agent", never
  "wingman". Internal var names and grep-target log tokens are exempt.
- No em dashes anywhere in code, copy, or docs.
