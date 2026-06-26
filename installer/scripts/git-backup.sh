#!/usr/bin/env bash
# Daily backup of the operator's AGENCY STATE (their config / mint registry /
# skills working dir) to a configurable GitHub backup remote. Box-side: installed
# by deploy_maintenance.sh and run by the git-backup.timer.
#
# SECRET-SAFE BY CONSTRUCTION: a hard ignore list ALWAYS excludes .env and key
# material, and any such path is unstaged after `git add -A` even if it slipped
# past .gitignore. No secret is ever committed or pushed. Idempotent: a no-op when
# nothing changed (emits the token, does not push).
#
# Config (the git-backup.timer loads these from the box's own provision env file):
#   BACKUP_GIT_REMOTE   the GitHub remote to push to               (REQUIRED)
#   BACKUP_DIR          the agency-state working dir to back up     (REQUIRED)
#   BACKUP_GIT_BRANCH   branch to push                              (default: main)
#
# Success token (mutation-proven): GIT-BACKUP-OK <pushed|nothing-to-commit>.
set -euo pipefail

GIT="${GIT:-git}"
REMOTE="${BACKUP_GIT_REMOTE:-}"
DIR="${BACKUP_DIR:-}"
BRANCH="${BACKUP_GIT_BRANCH:-main}"

[ -n "$REMOTE" ] || { echo "usage: set BACKUP_GIT_REMOTE (and BACKUP_DIR) before running git-backup.sh" >&2; exit 2; }
[ -n "$DIR" ]    || { echo "usage: set BACKUP_DIR (the agency-state working dir)" >&2; exit 2; }
[ -d "$DIR" ]    || { echo "ERROR: BACKUP_DIR does not exist: $DIR" >&2; exit 1; }

cd "$DIR" || exit 1

# Paths that must NEVER be backed up: secrets first, then bulky/derived dirs.
SECRET_GLOBS=(".env" ".env.*" "*.key" "*.pem" "*.secret" "id_rsa" "id_rsa.pub" "id_ed25519" "id_ed25519.pub" "session-store*.json")
IGNORE_PATTERNS=("${SECRET_GLOBS[@]}" "*.log" "node_modules/")

ensure_ignore() {
  local gi=".gitignore" pat
  touch "$gi"
  for pat in "${IGNORE_PATTERNS[@]}"; do
    grep -qxF "$pat" "$gi" 2>/dev/null || printf '%s\n' "$pat" >> "$gi"
  done
}

[ -d .git ] || "$GIT" init -q
ensure_ignore

"$GIT" add -A
# Belt-and-suspenders: unstage any secret path even if .gitignore was bypassed.
# --ignore-unmatch + --cached drops them from the index without touching the file,
# and works before the first commit (no HEAD required).
"$GIT" rm -q --cached --ignore-unmatch -- "${SECRET_GLOBS[@]}" >/dev/null 2>&1 || true

if "$GIT" diff --cached --quiet; then
  echo "GIT-BACKUP-OK nothing-to-commit"
  exit 0
fi

"$GIT" -c user.email="agency-backup@localhost" -c user.name="agency-backup" \
  commit -q -m "agency state backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
"$GIT" push -q "$REMOTE" "HEAD:${BRANCH}"
echo "GIT-BACKUP-OK pushed"
