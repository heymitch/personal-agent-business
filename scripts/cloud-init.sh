#!/bin/bash
# ============================================================================
# YOUR ALWAYS-ON PERSONAL AGENT  -  one-paste cloud setup
# ============================================================================
#
# WHAT THIS DOES (plain English):
#   This script turns a blank cloud computer into YOUR own always-on AI agent.
#   It installs the open-source Hermes agent engine, applies the personal agent
#   look and skill pack, and sets everything to start automatically and stay
#   running forever (even after a reboot). Everything it installs comes from
#   PUBLIC sources only. No private keys are baked in here.
#
# HOW TO USE IT:
#   When you create your server, the provider (Hetzner) shows a box labeled
#   "Cloud config" (also called "user data"). Paste this ENTIRE file into that
#   box, then create the server. That is it. The agent installs itself on first
#   boot (about 4 to 8 minutes).
#
# WHAT YOU CHANGE:
#   NOTHING. Leave everything exactly as it is. You do not paste any keys here.
#   Your login keys (the agent brain, email, app connections) are added LATER,
#   safely, by the cockpit after the box is online.
#
# OPTIONAL TAILSCALE BONUS (advanced, off by default):
#   Cloudflare is the default and needs nothing from you here. If instead you want
#   a private dashboard the instant the box boots with no domain, you may paste a
#   Tailscale auth key into TS_AUTHKEY below. That is the ONLY change you would make.
#
# WHAT HAPPENS AFTER BOOT (the cockpit finishes the job):
#   Once this script prints WINGMAN-PROVISION-DONE, your cockpit (Claude Code,
#   following the playbook) takes over and does the rest for you:
#     - gives your agent a private web address (Cloudflare tunnel + login gate)
#     - connects the brain (the model that thinks)
#     - connects email and your apps
#   You do NOT do any of that in this file.
#
# ============================================================================

# Faithfully derived from the real factory template:
#   /Users/heymitch/wingman/deploy/provision/cloud-init.sh.tmpl
# This is the single-box subset: stock Hermes + the public personal agent skin
# + always-on, from PUBLIC sources only. The operator/queue factory, the
# cloudflared connector, and the brain/email/app keys are intentionally removed
# (the cockpit adds them after boot - see the comments below). Tailscale is kept
# as an OPTIONAL, OFF-by-default bonus (see TS_AUTHKEY).

set -euxo pipefail
exec > /var/log/wingman-provision.log 2>&1   # everything below is captured for debugging

# The public personal agent skin (skin + dashboard theme + SOUL + skill pack).
# This is a PUBLIC gist - copied verbatim from the real template/provision.sh.
WINGMANIZE_URL='https://gist.githubusercontent.com/heymitch/3b9d17a0d3207d7013aeef06bcc3860a/raw/wingmanize.sh'

# OPTIONAL BONUS. Leave blank to use the Cloudflare path (default). Paste a
# Tailscale auth key here to instead put this box on your private Tailscale
# network - then your dashboard is reachable the instant it boots at your tailnet
# IP, no domain or Cloudflare needed.
TS_AUTHKEY=''

# --- 1. base packages + an unprivileged hermes user ---------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl git build-essential python3-dev libffi-dev ripgrep ffmpeg
id hermes >/dev/null 2>&1 || useradd -m -s /bin/bash hermes
echo 'hermes ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/hermes
chmod 0440 /etc/sudoers.d/hermes

# --- 2. install STOCK upstream Hermes (engine, not a fork); skip the wizard ----
su - hermes -c 'curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --skip-setup'

# --- 3. apply the personal agent workspace (skin + SOUL + theme + skill pack) ---
# Public one-paste. No Slack tokens folded in here - the cockpit wires Slack and
# the rest of your connections AFTER boot. Brain is wired later too.
if [ -n "$WINGMANIZE_URL" ]; then
  su - hermes -c "curl -fsSL '$WINGMANIZE_URL' | bash"
fi

# ----------------------------------------------------------------------------
# THE COCKPIT ADDS YOUR KEYS HERE, AFTER BOOT - not in this file.
#   - the agent brain (the model that thinks)
#   - your email inbox (AgentMail)
#   - your app connections (Composio) and Slack
# These are added safely by the cockpit / dashboard once the box is online, so
# no secret ever lives in this pasted text. Nothing for you to edit.
# ----------------------------------------------------------------------------

# --- 3b. OPTIONAL Tailscale: join your private tailnet (the access gate) -------
# OFF by default. Only runs if you pasted a TS_AUTHKEY at the top. When set, the
# box joins your private Tailscale network, and step 6's dashboard binds the
# tailnet IP, so the dashboard is reachable the instant it boots from any device
# on your tailnet - no domain, no Cloudflare. Lines copied from the real template.
if [ -n "$TS_AUTHKEY" ]; then
  curl -fsSL https://tailscale.com/install.sh | sh
  # Do NOT let a bad/expired/used-up authkey abort the whole provision (set -e).
  tailscale up --authkey="$TS_AUTHKEY" --hostname="wingman" --accept-dns=false \
    || echo "WINGMAN-TAILSCALE-FAILED: 'tailscale up' failed. Check TS_AUTHKEY is valid, REUSABLE, and unexpired."
fi

# --- 4. wait for the hermes binary to be ready -------------------------------
for _ in $(seq 1 60); do
  if su - hermes -c 'command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1'; then break; fi
  sleep 5
done
HUID="$(id -u hermes)"; RT="/run/user/$HUID"

# --- 5. gateway as a NATIVE user-scope service (ALWAYS-ON) --------------------
# `hermes gateway install` enables systemd linger, creates the user-scope unit,
# and starts it. A USER service (not a root system service) is what lets the
# dashboard's in-app "Restart Gateway" button work WITHOUT root. `yes` answers
# its "start now?" prompt. systemd + linger = it survives reboots and restarts.
sudo -u hermes XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" \
  bash -lc 'yes | hermes gateway install' || true

# --- 5b. silent daily self-updater (this is the "gets better every week" part) -
# A systemd USER timer (NOT hermes cron, which would message you in chat) that
# runs `hermes update` daily, restarts the gateway, and health-checks -- silently,
# logging to ~/.hermes/logs/self-update.log. Only updates / restarts when an
# update actually exists; backs up first. Copied from the real template.
sudo -u hermes XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" bash -lc '
  set -e
  HH="$HOME/.hermes"; UD="$HOME/.config/systemd/user"; JOB="$HH/wingman-self-update.sh"
  mkdir -p "$HH/logs" "$UD"
  cat > "$JOB" <<'"'"'JOB_EOF'"'"'
#!/usr/bin/env bash
set -uo pipefail
LOG="$HOME/.hermes/logs/self-update.log"; mkdir -p "$(dirname "$LOG")"
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
export PATH="$HOME/.local/bin:$PATH"
RT="/run/user/$(id -u)"; export XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus"
echo "[$(ts)] check (current: $(hermes --version 2>/dev/null | head -1))" >> "$LOG"
chk="$(hermes update --check 2>>"$LOG" || true)"; echo "$chk" >> "$LOG"
if ! echo "$chk" | grep -qiE "available|behind|commits"; then echo "[$(ts)] no update" >> "$LOG"; exit 0; fi
echo "[$(ts)] updating..." >> "$LOG"
if hermes update --yes --backup >>"$LOG" 2>&1; then
  hermes gateway restart >>"$LOG" 2>&1 || true; sleep 6
  if systemctl --user is-active --quiet hermes-gateway; then
    echo "[$(ts)] OK -> $(hermes --version 2>/dev/null | head -1); gateway active" >> "$LOG"
  else
    echo "[$(ts)] CRITICAL gateway down; retry" >> "$LOG"; hermes gateway restart >>"$LOG" 2>&1 || true; sleep 6
    systemctl --user is-active --quiet hermes-gateway && echo "[$(ts)] recovered" >> "$LOG" || echo "[$(ts)] STILL DOWN — operator attention (backup taken)" >> "$LOG"
  fi
  if systemctl cat hermes-dashboard >/dev/null 2>&1; then sudo systemctl restart hermes-dashboard >>"$LOG" 2>&1 || true; sleep 4; echo "[$(ts)] dashboard: $(systemctl is-active hermes-dashboard 2>/dev/null)" >> "$LOG"; fi
else
  echo "[$(ts)] update FAILED; gateway untouched" >> "$LOG"
fi
JOB_EOF
  chmod +x "$JOB"
  printf "[Unit]\nDescription=Wingman silent self-updater\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/bin/env bash %s\n" "$JOB" > "$UD/wingman-self-update.service"
  printf "[Unit]\nDescription=Run the Wingman self-updater daily\n\n[Timer]\nOnCalendar=*-*-* 04:00:00\nRandomizedDelaySec=1800\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n" > "$UD/wingman-self-update.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now wingman-self-update.timer
' || echo "WINGMAN-SELFUPDATER-FAILED: could not install the daily self-updater (non-fatal)."

# --- 5c. heartbeat: proactive work every 30m, silent unless it needs you ------
# A recurring cron job (the proactive loop). Does a real unit of work each tick
# and stays silent unless something needs a human decision. Copied from the real
# template. (It only acts on connections you wire later via the cockpit.)
sudo -u hermes XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" bash -lc \
  'hermes cron create "every 30m" "Heartbeat tick. Quietly scan the connected tools (email, calendar, tasks) for anything time-sensitive or that needs the owner judgment, and correlate signals. Do the real work (triage, draft, flag) and dedupe so you never re-action the same item. Stay COMPLETELY SILENT unless something genuinely needs a human decision; never send a status report. Route any real send through approval-gate." --name heartbeat' \
  || echo "WINGMAN-HEARTBEAT-FAILED: could not create the heartbeat cron (non-fatal)."

# --- 6. dashboard as a system service (ALWAYS-ON) ----------------------------
# ALWAYS runs and restarts on failure / reboot. The dashboard ALWAYS binds
# 127.0.0.1:9119 (loopback). Reach it from your laptop with "open my agent"
# (the SSH-forward in scripts/open_dashboard.sh). Tailscale is optional hardening
# and does NOT affect the bind address. Restart=on-failure + WantedBy=multi-user.target
# = back after reboot.
cat > /etc/systemd/system/hermes-dashboard.service <<'DUNIT'
[Unit]
Description=Hermes personal agent web dashboard
After=network-online.target
Wants=network-online.target

[Service]
User=hermes
WorkingDirectory=/home/hermes
TimeoutStartSec=0
# --insecure is a no-op on loopback but kept for consistency with the real template.
# The gate is Cloudflare Access (added after boot by the cockpit) or the SSH-forward
# ("open my agent"); the session token still protects the sensitive /api routes.
# Builds the web UI on first start (~2-3 min).
ExecStart=/bin/bash -lc 'echo "dashboard bind host: 127.0.0.1"; exec hermes dashboard --host 127.0.0.1 --port 9119 --insecure --no-open'
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/hermes-dashboard.log
StandardError=append:/var/log/hermes-dashboard.log

[Install]
WantedBy=multi-user.target
DUNIT
mkdir -p /etc/systemd/system/hermes-dashboard.service.d
printf '[Service]\nEnvironment=XDG_RUNTIME_DIR=%s\nEnvironment=DBUS_SESSION_BUS_ADDRESS=unix:path=%s/bus\n' "$RT" "$RT" > /etc/systemd/system/hermes-dashboard.service.d/env.conf
systemctl daemon-reload
systemctl enable --now hermes-dashboard.service || true
echo "WINGMAN-DASHBOARD-URL: http://127.0.0.1:9119 (reach it from your laptop with \"open my agent\")"

# ----------------------------------------------------------------------------
# THE COCKPIT INSTALLS THE CLOUDFLARED CONNECTOR HERE, AFTER BOOT.
# The connector needs a tunnel TOKEN that does not exist yet - it only exists
# AFTER the cockpit creates your tunnel via the Cloudflare API (see the playbook
# / the cf_portal step). At that point the cockpit SSHes in and runs:
#     cloudflared service install <TOKEN>
# That is what gives your loopback dashboard a private, login-gated web address.
# We do NOT inline a token here (there is none to inline). Nothing for you to do.
# ----------------------------------------------------------------------------

echo "WINGMAN-PROVISION-DONE"
