#!/usr/bin/env python3
"""
Personal Agent Business Setup Dashboard -- stdlib only, no pip installs.
Serves a localhost-only guided form to fill .env without fear.
Security model:
  - Binds 127.0.0.1 only.
  - One-time token (secrets.token_urlsafe) required on every request.
  - Writes ONLY to $COCKPIT_DIR/.env, ONLY keys in .env.example.
  - Secrets never logged, never echoed, never returned to DOM raw.
  - No external network calls except explicit /api/test/<service>.
  - Auto-shuts down after IDLE_MINUTES of no requests.
"""

import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import threading
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DEFAULT_PORT = 7475
IDLE_MINUTES = 30
TOKEN_PARAM = "t"
TOKEN_HEADER = "X-Setup-Token"

# Keys that are NOT secrets (their value is safe to show in the DOM).
NON_SECRET_KEYS = {
    "OWNER_EMAIL",
    "AGENT_DOMAIN",
    "OPENAI_BASE_URL",
    "BRAIN_MODEL",
    "CLOUDFLARE_ACCOUNT_ID",
    "SLACK_ALLOWED_USERS",
    "AGENTMAIL_INBOX",
    "ONBOARDER_BASE_URL",
    "SLACK_INVITE_ADDRESS",
    "VERCEL_ORG_ID",
}

# Keys the provisioning + deploy + mint chain needs before the operator can run.
# Auto-detected / defaulted / set-later keys are intentionally NOT required:
#   SSH_PUBKEY (auto-detected), OPENAI_BASE_URL + BRAIN_MODEL (defaulted),
#   SLACK_INVITE_ADDRESS (defaulted), ONBOARDER_BASE_URL (set by deploy),
#   SLACK_ALLOWED_USERS (convenience), VERCEL_ORG_ID (often inferred).
REQUIRED_KEYS = {
    "HETZNER_TOKEN",
    "OPENAI_ADMIN_KEY",
    "AGENTMAIL_API_KEY",
    "AGENTMAIL_INBOX",
    "COMPOSIO_API_KEY",
    "CLOUDFLARE_API_TOKEN",
    "CLOUDFLARE_ACCOUNT_ID",
    "AGENT_DOMAIN",
    "OWNER_EMAIL",
    "VERCEL_TOKEN",
    "SLACK_BOT_TOKEN",
    "SLACK_APP_TOKEN",
}

# ---------------------------------------------------------------------------
# Locate dirs
# ---------------------------------------------------------------------------
SETUP_UI_DIR = os.path.dirname(os.path.abspath(__file__))
COCKPIT_DIR = os.environ.get("COCKPIT_DIR", os.path.dirname(SETUP_UI_DIR))
ENV_EXAMPLE = os.path.join(COCKPIT_DIR, ".env.example")
ENV_FILE = os.path.join(COCKPIT_DIR, ".env")

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
ACCESS_TOKEN = os.environ.get("SETUP_TOKEN") or secrets.token_urlsafe(24)


# ---------------------------------------------------------------------------
# Parse .env.example into groups
# ---------------------------------------------------------------------------
def parse_env_example():
    """
    Parse .env.example into ordered groups.
    Returns list of {service, fields:[{key, help, secret, required, default}]}.
    Groups delimited by '# --- <service> ---' comment lines.
    """
    groups = []
    current_group = None
    pending_comment = []

    try:
        with open(ENV_EXAMPLE) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return []

    for line in lines:
        stripped = line.rstrip("\n")

        # Section header: # --- Service name ---
        m = re.match(r"^#\s*---+\s*(.+?)\s*---+", stripped)
        if m:
            service_name = m.group(1).strip()
            current_group = {"service": service_name, "fields": []}
            groups.append(current_group)
            pending_comment = []
            continue

        # Skip top-level file header comments (before first group)
        if current_group is None:
            continue

        # Comment line (field help)
        if stripped.startswith("#"):
            comment = stripped.lstrip("#").strip()
            if comment:
                pending_comment.append(comment)
            continue

        # Blank line -- reset pending comment
        if not stripped:
            pending_comment = []
            continue

        # KEY=value line
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)", stripped)
        if m:
            key = m.group(1)
            default_val = (m.group(2) or "").strip()
            secret = key not in NON_SECRET_KEYS
            help_text = " ".join(pending_comment) if pending_comment else ""
            current_group["fields"].append(
                {
                    "key": key,
                    "help": help_text,
                    "secret": secret,
                    "required": key in REQUIRED_KEYS,
                    "default": default_val,
                }
            )
            pending_comment = []

    return groups


# ---------------------------------------------------------------------------
# Read current .env values
# ---------------------------------------------------------------------------
def read_env_values():
    """Return dict of KEY->value from current .env (if it exists)."""
    vals = {}
    if not os.path.isfile(ENV_FILE):
        return vals
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)", line)
                if m:
                    vals[m.group(1)] = m.group(2)
    except OSError:
        pass
    return vals


# ---------------------------------------------------------------------------
# Build schema response (secrets masked)
# ---------------------------------------------------------------------------
def build_schema_response():
    groups = parse_env_example()
    current = read_env_values()

    valid_keys = set()
    for g in groups:
        for f in g["fields"]:
            valid_keys.add(f["key"])

    result_groups = []
    for g in groups:
        fields = []
        for f in g["fields"]:
            key = f["key"]
            cur_val = current.get(key, "")
            if f["secret"]:
                value = ""
                is_set = bool(cur_val)
            else:
                value = cur_val if cur_val else f["default"]
                is_set = False
            fields.append(
                {
                    "key": key,
                    "required": f["required"],
                    "secret": f["secret"],
                    "help": f["help"],
                    "value": value,
                    "is_set": is_set,
                }
            )
        result_groups.append({"service": g["service"], "fields": fields})

    return {"groups": result_groups, "valid_keys": list(valid_keys)}


# ---------------------------------------------------------------------------
# Write .env (only valid keys, preserve existing non-submitted)
# ---------------------------------------------------------------------------
def write_env(updates: dict):
    """
    Merge `updates` into .env. Only writes keys from .env.example.
    Returns (saved_keys, rejected_keys).
    """
    groups = parse_env_example()
    valid_keys = set()
    for g in groups:
        for f in g["fields"]:
            valid_keys.add(f["key"])

    safe_updates = {k: v for k, v in updates.items() if k in valid_keys}
    rejected = [k for k in updates if k not in valid_keys]

    existing_lines = []
    if os.path.isfile(ENV_FILE):
        with open(ENV_FILE) as f:
            existing_lines = f.readlines()

    key_to_idx = {}
    for i, line in enumerate(existing_lines):
        m = re.match(r"^([A-Z][A-Z0-9_]*)=", line)
        if m:
            key_to_idx[m.group(1)] = i

    new_lines = list(existing_lines)
    for key, val in safe_updates.items():
        new_line = f"{key}={val}\n"
        if key in key_to_idx:
            new_lines[key_to_idx[key]] = new_line
        else:
            new_lines.append(new_line)

    with open(ENV_FILE, "w") as f:
        f.writelines(new_lines)

    return list(safe_updates.keys()), rejected


# ---------------------------------------------------------------------------
# Credential tests
# ---------------------------------------------------------------------------
def test_hetzner(token: str):
    """Call Hetzner list-servers to verify the token."""
    if not token:
        return {"ok": False, "message": "No token provided."}
    url = "https://api.hetzner.cloud/v1/servers"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                return {"ok": True, "message": "Hetzner token is valid."}
            return {"ok": False, "message": f"Hetzner returned HTTP {resp.status}."}
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return {"ok": False, "message": "Invalid token (Hetzner said 401 Unauthorized)."}
        return {"ok": False, "message": f"Hetzner error: HTTP {e.code}."}
    except Exception as e:
        return {"ok": False, "message": f"Could not reach Hetzner: {e}"}


def test_cloudflare(token: str):
    """Call Cloudflare token verify endpoint."""
    if not token:
        return {"ok": False, "message": "No token provided."}
    url = "https://api.cloudflare.com/client/v4/user/tokens/verify"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = json.loads(resp.read())
            if body.get("success"):
                return {"ok": True, "message": "Cloudflare token is valid."}
            msgs = body.get("messages") or body.get("errors") or []
            return {"ok": False, "message": f"Cloudflare said: {msgs}"}
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return {"ok": False, "message": "Invalid token (Cloudflare said 401 Unauthorized)."}
        return {"ok": False, "message": f"Cloudflare error: HTTP {e.code}."}
    except Exception as e:
        return {"ok": False, "message": f"Could not reach Cloudflare: {e}"}


# ---------------------------------------------------------------------------
# Idle-shutdown timer
# ---------------------------------------------------------------------------
_shutdown_event = threading.Event()
_idle_timer = None


def reset_idle_timer(httpd):
    global _idle_timer
    if _idle_timer:
        _idle_timer.cancel()
    _idle_timer = threading.Timer(IDLE_MINUTES * 60, lambda: initiate_shutdown(httpd))
    _idle_timer.daemon = True
    _idle_timer.start()


def initiate_shutdown(httpd):
    print("\n[setup-ui] Idle timeout -- shutting down.", flush=True)
    threading.Thread(target=httpd.shutdown, daemon=True).start()
    _shutdown_event.set()


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------
class SetupHandler(http.server.BaseHTTPRequestHandler):
    httpd_ref = None  # set after server creation

    def log_message(self, fmt, *args):
        # Never log request bodies (could contain secrets). Log method + path only.
        path = args[0].split("?")[0] if args else ""
        print(f"[setup-ui] {self.command} {path}", flush=True)

    # ---- Token check -------------------------------------------------------
    def _check_token(self):
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        token_from_qs = (qs.get(TOKEN_PARAM) or [""])[0]
        token_from_header = self.headers.get(TOKEN_HEADER, "")
        provided = token_from_qs or token_from_header
        return secrets.compare_digest(provided, ACCESS_TOKEN)

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_forbidden(self):
        self._send_json({"error": "Forbidden -- missing or invalid token."}, 403)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return b""
        return self.rfile.read(length)

    # ---- GET ---------------------------------------------------------------
    def do_GET(self):
        reset_idle_timer(self.httpd_ref)

        from urllib.parse import urlparse
        path = urlparse(self.path).path

        if path == "/" or path == "/index.html":
            if not self._check_token():
                self._send_forbidden()
                return
            self._serve_html()
        elif path == "/api/schema":
            if not self._check_token():
                self._send_forbidden()
                return
            self._send_json(build_schema_response())
        else:
            self.send_response(404)
            self.end_headers()

    # ---- POST --------------------------------------------------------------
    def do_POST(self):
        reset_idle_timer(self.httpd_ref)

        from urllib.parse import urlparse
        path = urlparse(self.path).path

        if not self._check_token():
            self._send_forbidden()
            return

        if path == "/api/save":
            self._handle_save()
        elif path.startswith("/api/test/"):
            service = path[len("/api/test/"):]
            self._handle_test(service)
        elif path == "/api/done":
            self._handle_done()
        elif path == "/api/generate-ssh":
            self._handle_generate_ssh()
        else:
            self.send_response(404)
            self.end_headers()

    # ---- Handlers ----------------------------------------------------------
    def _serve_html(self):
        html_path = os.path.join(SETUP_UI_DIR, "index.html")
        try:
            with open(html_path, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()

    def _handle_save(self):
        raw = self._read_body()
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._send_json({"error": "Invalid JSON"}, 400)
            return
        if not isinstance(data, dict):
            self._send_json({"error": "Expected JSON object"}, 400)
            return

        groups = parse_env_example()
        required_keys = set()
        for g in groups:
            for f in g["fields"]:
                if f["required"]:
                    required_keys.add(f["key"])

        saved, rejected = write_env(data)
        current = read_env_values()
        missing_required = [k for k in required_keys if not current.get(k)]

        self._send_json(
            {
                "saved": saved,
                "rejected": rejected,
                "missing_required": missing_required,
            }
        )

    def _handle_test(self, service: str):
        raw = self._read_body()
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {}

        token_val = data.get("token", "")

        if service == "hetzner":
            result = test_hetzner(token_val)
        elif service == "cloudflare":
            result = test_cloudflare(token_val)
        else:
            result = {
                "ok": None,
                "message": "No automated test for this service -- verify manually in their dashboard.",
            }
        self._send_json(result)

    def _handle_done(self):
        raw = self._read_body()
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {}
        if data:
            write_env(data)
        self._send_json(
            {
                "ok": True,
                "message": "Your .env is saved. You can close this tab. Next: run /setup in Claude Code.",
            }
        )

        def _stop():
            import time
            time.sleep(0.5)
            if self.httpd_ref:
                initiate_shutdown(self.httpd_ref)
        threading.Thread(target=_stop, daemon=True).start()

    def _handle_generate_ssh(self):
        """Generate an ed25519 SSH keypair, write SSH_PUBKEY + SSH_KEY to .env.
        Never returns private key material. Token gate is enforced by do_POST.
        """
        keygen = shutil.which("ssh-keygen")
        if not keygen:
            self._send_json({
                "ok": False,
                "message": "ssh-keygen not found - on Windows install Git for Windows",
            })
            return

        ssh_dir = os.path.expanduser("~/.ssh")
        base_name = "pab_ed25519"
        key_path = os.path.join(ssh_dir, base_name)

        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)

        # If a key already exists, reuse it rather than clobbering.
        if os.path.isfile(key_path):
            pub_path = key_path + ".pub"
            if os.path.isfile(pub_path):
                try:
                    fp_result = subprocess.run(
                        [keygen, "-lf", pub_path],
                        capture_output=True, text=True, timeout=10,
                    )
                    fingerprint = fp_result.stdout.strip()
                    with open(pub_path) as f:
                        pub_contents = f.read().strip()
                    write_env({"SSH_PUBKEY": pub_contents})
                    self._send_json({
                        "ok": True,
                        "path": os.path.basename(key_path),
                        "fingerprint": fingerprint,
                    })
                except Exception as e:
                    self._send_json({"ok": False, "message": f"Error reading existing key: {e}"})
                return
            suffix = 2
            while os.path.isfile(key_path):
                key_path = os.path.join(ssh_dir, f"{base_name}_{suffix}")
                suffix += 1

        pub_path = key_path + ".pub"

        try:
            result = subprocess.run(
                [keygen, "-t", "ed25519", "-N", "", "-C", "personal-agent-business", "-f", key_path],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode != 0:
                self._send_json({
                    "ok": False,
                    "message": f"ssh-keygen failed: {result.stderr.strip()}",
                })
                return
        except Exception as e:
            self._send_json({"ok": False, "message": f"ssh-keygen error: {e}"})
            return

        try:
            with open(pub_path) as f:
                pub_contents = f.read().strip()
        except OSError as e:
            self._send_json({"ok": False, "message": f"Could not read public key: {e}"})
            return

        try:
            fp_result = subprocess.run(
                [keygen, "-lf", pub_path],
                capture_output=True, text=True, timeout=10,
            )
            fingerprint = fp_result.stdout.strip()
        except Exception:
            fingerprint = ""

        # Write only the PUBLIC key to .env. Private key never leaves ~/.ssh.
        write_env({"SSH_PUBKEY": pub_contents})

        self._send_json({
            "ok": True,
            "path": os.path.basename(key_path),
            "fingerprint": fingerprint,
        })


# ---------------------------------------------------------------------------
# Find a free port
# ---------------------------------------------------------------------------
def find_port(preferred=DEFAULT_PORT):
    import socket
    for port in [preferred] + list(range(49152, 49200)):
        try:
            s = socket.socket()
            s.bind(("127.0.0.1", port))
            s.close()
            return port
        except OSError:
            continue
    raise RuntimeError("Could not find a free port.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    port = find_port(int(os.environ.get("SETUP_PORT", DEFAULT_PORT)))
    url = f"http://127.0.0.1:{port}/?{TOKEN_PARAM}={ACCESS_TOKEN}"

    class Handler(SetupHandler):
        pass

    httpd = http.server.HTTPServer(("127.0.0.1", port), Handler)
    Handler.httpd_ref = httpd

    reset_idle_timer(httpd)

    print("\n[setup-ui] Personal Agent Business setup dashboard running.", flush=True)
    print("[setup-ui] Open this URL in your browser:", flush=True)
    print(f"\n  {url}\n", flush=True)
    print(f"[setup-ui] Reads schema from: {ENV_EXAMPLE}", flush=True)
    print(f"[setup-ui] Writes .env to:   {ENV_FILE}", flush=True)
    print(f"[setup-ui] Auto-shuts down after {IDLE_MINUTES} min idle.", flush=True)
    print("[setup-ui] Ctrl-C to stop early.\n", flush=True)

    # Also write the URL to stdout for the launcher script to pick up
    print(f"SETUP_URL={url}", flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[setup-ui] Stopped.", flush=True)
    finally:
        if _idle_timer:
            _idle_timer.cancel()


if __name__ == "__main__":
    main()
