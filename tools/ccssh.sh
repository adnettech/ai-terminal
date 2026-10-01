#!/usr/bin/env bash
#
# ccssh — ephemeral SSH launcher for Claude Code
#
# A tech pastes host / user / password (from the password manager) once. This opens an
# SSH ControlMaster connection, handing the password to ssh through a one-shot FIFO that
# only the ask-pass helper reads (never on disk, never in the process list, never in any
# process's environment), wipes it, then launches Claude Code already wired to the server
# through `rssh`. When Claude Code exits, the connection closes and every ephemeral
# artifact is removed.
#
# What persists on the box: only known_hosts fingerprints (public, not secret).
# Nothing credential-related is ever written anywhere.
#
# Why a FIFO and not an environment variable: `ssh -f` forks the background master that
# lives for the whole session, and it inherits ssh's environment. A password exported for
# the ask-pass helper would sit in /proc/<master>/environ, readable by anything running as
# this user (Claude Code included) until the session ends.
#
# Requires: OpenSSH >= 8.4 (for SSH_ASKPASS_REQUIRE=force), bash, the `claude`
# CLI. No sshpass dependency.

set -uo pipefail

VERSION="1.1.0"
PROG="${0##*/}"

# ---- config (override via env) --------------------------------------------
CC_CMD="${CCSSH_CC_CMD:-}"        # claude binary; auto-detected if empty
CONNECT_TIMEOUT="${CCSSH_CONNECT_TIMEOUT:-15}"
MAX_PW_ATTEMPTS="${CCSSH_MAX_PW_ATTEMPTS:-3}"

# ---- state (cleaned up on exit) -------------------------------------------
tmpdir=""
socket=""
host="" user="" port="22" password=""
cli_host="" cli_user="" cli_port=""
dry_run=0
test_connection=0

# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
$PROG v$VERSION — ephemeral SSH launcher for Claude Code

Usage:
  $PROG                        Prompt for host/user/port/password, connect, launch Claude Code
  $PROG --host H --user U       Pre-fill fields (still prompts for the password)
  $PROG --test-connection       Connect, prove reachability, tear down (no Claude Code)
  $PROG --self-test             Check prerequisites and exit
  $PROG --dry-run               Show what would run without connecting
  $PROG --help | --version

Options:
  --host <host>       Remote host / A record (skips that prompt). A full URL is
                      fine — http(s):// and any trailing path are stripped
  --user <user>       Remote username (skips that prompt)
  --port <port>       SSH port (default 22)
  --test-connection   Authenticate and run 'rssh hostname' to prove the tunnel
                      works, then close it — does NOT launch Claude Code
  --dry-run           Print the ssh command that would run, then exit
  --self-test         Verify ssh, claude, and OpenSSH version, then exit

Environment:
  CCSSH_CC_CMD            Path/name of the Claude Code CLI (default: claude, then cc)
  CCSSH_CONNECT_TIMEOUT   ssh ConnectTimeout seconds (default 15)
  CCSSH_MAX_PW_ATTEMPTS   Password retries before giving up (default 3)

The password is read hidden, handed to ssh's SSH_ASKPASS helper through a one-shot
FIFO, and wiped once the connection is up. It never touches disk, never appears in
the process list and is never left in any process's environment.
EOF
}

log()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }

normalize_host() {
  # Accept a URL-style host (as stored in a password manager) and reduce it to a bare host.
  # Strips surrounding whitespace, an http(s):// scheme (case-insensitive),
  # and anything from the first '/' on (trailing slash or a full path).
  printf '%s' "$1" | sed -E '
    s#^[[:space:]]+##; s#[[:space:]]+$##;
    s#^[Hh][Tt][Tt][Pp][Ss]?://##;
    s#/.*$##'
}

cleanup() {
  # Close the master connection first, then remove ephemeral files.
  if [ -n "$socket" ] && [ -S "$socket" ]; then
    ssh -S "$socket" -O exit -p "$port" "$user@$host" >/dev/null 2>&1 || true
  fi
  [ -n "$tmpdir" ] && rm -rf "$tmpdir"
  unset CCSSH_PW CCSSH_PWFIFO 2>/dev/null || true
  password=""
}
trap cleanup EXIT INT TERM

# ---- prerequisite checks --------------------------------------------------
detect_cc() {
  if [ -n "$CC_CMD" ]; then command -v "$CC_CMD" >/dev/null 2>&1 && { echo "$CC_CMD"; return 0; }; return 1; fi
  if command -v claude >/dev/null 2>&1; then echo claude; return 0; fi
  if command -v cc >/dev/null 2>&1; then echo cc; return 0; fi
  return 1
}

ssh_version_ok() {
  # OpenSSH >= 8.4 needed for SSH_ASKPASS_REQUIRE=force.
  local v major minor
  v="$(ssh -V 2>&1)"
  major="$(printf '%s' "$v" | sed -n 's/.*OpenSSH_\([0-9]\+\)\.\([0-9]\+\).*/\1/p')"
  minor="$(printf '%s' "$v" | sed -n 's/.*OpenSSH_\([0-9]\+\)\.\([0-9]\+\).*/\2/p')"
  [ -z "$major" ] && return 2                     # couldn't parse
  if [ "$major" -gt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -ge 4 ]; }; then
    return 0
  fi
  return 1
}

preflight() {
  local ok=0
  if command -v ssh >/dev/null 2>&1; then
    log "  ✔ ssh found: $(ssh -V 2>&1)"
  else
    err "  ✗ ssh not found (install OpenSSH client)"; ok=1
  fi

  if ssh_version_ok; then
    log "  ✔ OpenSSH >= 8.4 (SSH_ASKPASS_REQUIRE supported)"
  else
    case $? in
      1) err "  ✗ OpenSSH is older than 8.4 — the in-memory password feed needs >= 8.4"; ok=1 ;;
      2) err "  ! Could not parse the OpenSSH version — proceeding, but >= 8.4 is required" ;;
    esac
  fi

  if cc_bin="$(detect_cc)"; then
    log "  ✔ Claude Code CLI: $cc_bin ($(command -v "$cc_bin"))"
  else
    err "  ✗ Claude Code CLI not found (looked for: ${CC_CMD:-claude, cc})"; ok=1
  fi

  command -v mktemp >/dev/null 2>&1 || { err "  ✗ mktemp not found"; ok=1; }
  return $ok
}

# ---- connection -----------------------------------------------------------
build_askpass() {
  # The helper reads the password from a FIFO the launcher writes ONCE per attempt; the
  # helper file and its environment hold no secret (only the FIFO's path).
  mkfifo -m 600 "$tmpdir/pw" || { err "Could not create the password FIFO."; exit 1; }
  cat > "$tmpdir/askpass" <<'EOF'
#!/usr/bin/env bash
cat "$CCSSH_PWFIFO"
EOF
  chmod 700 "$tmpdir/askpass"
}

ssh_master_opts() {
  printf '%s\0' \
    -f -N -M \
    -S "$socket" \
    -p "$port" \
    -o ControlPersist=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout="$CONNECT_TIMEOUT" \
    -o NumberOfPasswordPrompts=1 \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no
}

open_master() {
  # Returns ssh's exit code; ssh stderr captured to $tmpdir/ssherr.
  local -a opts=()
  local o
  while IFS= read -r -d '' o; do opts+=("$o"); done < <(ssh_master_opts)

  export CCSSH_PWFIFO="$tmpdir/pw"
  export SSH_ASKPASS="$tmpdir/askpass"
  export SSH_ASKPASS_REQUIRE=force
  export DISPLAY="${DISPLAY:-:0}"     # harmless; helps pre-force OpenSSH fall back

  # The writer is a subshell of THIS shell (printf is a builtin: no exec, no argv), so the
  # password is never in an environment or a command line. It blocks until the helper
  # opens the FIFO; if ssh fails before asking (DNS, host key, timeout) it is killed below.
  ( printf '%s\n' "$password" > "$tmpdir/pw" ) &
  local writer=$!
  # shellcheck disable=SC2029  # user@host is meant to expand here, on the client
  ssh "${opts[@]}" "$user@$host" </dev/null 2>"$tmpdir/ssherr"
  local rc=$?
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
  unset CCSSH_PWFIFO SSH_ASKPASS SSH_ASKPASS_REQUIRE
  return $rc
}

build_rssh() {
  # The wrapper Claude Code uses to reach the server. Holds host/user/socket —
  # NO password. BatchMode=yes so a dead socket fails fast instead of prompting.
  cat > "$tmpdir/rssh" <<EOF
#!/usr/bin/env bash
exec ssh -S "$socket" -o ControlMaster=no -o BatchMode=yes -p "$port" "$user@$host" "\$@"
EOF
  chmod 700 "$tmpdir/rssh"
}

briefing() {
  cat <<EOF
A remote server is connected for this session over an SSH ControlMaster socket.

To run ANY command on that server, use the \`rssh\` wrapper on your PATH, e.g.:
    rssh 'hostname && whoami'
    rssh 'systemctl status nginx'

Connection: user "$user" on host "$host" (port $port).

You do NOT have the server's password and it is not stored anywhere on this
machine — do not try to find, read, or reconstruct it. When the user asks you
to do something "on the server," route those commands through rssh.

Start by running \`rssh 'hostname'\` to confirm the connection, then ask what
they need done.
EOF
}

# ---- argument parsing -----------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --host) cli_host="${2:-}"; shift 2 ;;
    --user) cli_user="${2:-}"; shift 2 ;;
    --port) cli_port="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --test-connection) test_connection=1; shift ;;
    --self-test)
      log "$PROG self-test:"
      if preflight; then log ""; log "All prerequisites satisfied."; exit 0
      else err ""; err "One or more prerequisites are missing."; exit 1; fi
      ;;
    --help|-h) usage; exit 0 ;;
    --version|-V) log "$PROG v$VERSION"; exit 0 ;;
    *) err "Unknown option: $1"; err "Try '$PROG --help'."; exit 2 ;;
  esac
done

# ---- main -----------------------------------------------------------------
if ! preflight >/dev/null 2>&1 && [ "$dry_run" -eq 0 ]; then
  err "Prerequisite check failed. Run '$PROG --self-test' for details."
  exit 1
fi
cc_bin="$(detect_cc || true)"

# Gather connection details (CLI flags skip the matching prompt).
if [ -n "$cli_host" ]; then
  host="$cli_host"
else
  log "Paste a URL as-is if that's what you have — the hostname is pulled out for you."
  read -r -p "Remote host (hostname or URL): " host
fi
if [ -n "$cli_user" ]; then user="$cli_user"; else read -r -p "Username: " user; fi
if [ -n "$cli_port" ]; then port="$cli_port"; else read -r -p "Port [22]: " port; port="${port:-22}"; fi

raw_host="$host"
host="$(normalize_host "$host")"
[ "$host" != "$raw_host" ] && log "  (host normalized: $raw_host  →  $host)"

[ -n "$host" ] || { err "Host is required."; exit 2; }
[ -n "$user" ] || { err "Username is required."; exit 2; }

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ccssh.XXXXXXXX")" || { err "Could not create temp dir."; exit 1; }
socket="$tmpdir/s"     # short path stays under the ~104-char UNIX socket limit
build_askpass

if [ "$dry_run" -eq 1 ]; then
  log ""
  log "DRY RUN — would open a ControlMaster connection with:"
  log "  ssh -f -N -M -S <socket> -p $port \\"
  log "      -o ControlPersist=yes -o StrictHostKeyChecking=accept-new \\"
  log "      -o ConnectTimeout=$CONNECT_TIMEOUT -o NumberOfPasswordPrompts=1 \\"
  log "      -o PreferredAuthentications=password,keyboard-interactive \\"
  log "      -o PubkeyAuthentication=no $user@$host"
  log "  (password fed via SSH_ASKPASS in memory; then wiped)"
  log "  then launch: ${cc_bin:-<claude not found>}  in  $PWD"
  log ""
  log "No connection was made."
  exit 0
fi

if [ "$test_connection" -eq 0 ] && [ -z "$cc_bin" ]; then
  err "Claude Code CLI not found; aborting before connect."; exit 1
fi

# Password (always prompted unless already supplied for testing via CCSSH_PW).
if [ -z "${CCSSH_PW:-}" ]; then
  read -r -s -p "Password (paste from your password manager): " password; echo
else
  password="$CCSSH_PW"; unset CCSSH_PW
fi
[ -n "$password" ] || { err "Password is required."; exit 2; }

log ""
log "Connecting to $user@$host:$port …"

attempts=0
while true; do
  if open_master; then
    break
  fi
  if grep -qiE 'permission denied|authentication failed' "$tmpdir/ssherr"; then
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$MAX_PW_ATTEMPTS" ]; then
      err "  ✗ Authentication failed $MAX_PW_ATTEMPTS times. Re-check the password."
      exit 1
    fi
    log "  ✗ Authentication failed — try again ($attempts/$MAX_PW_ATTEMPTS)."
    read -r -s -p "Password: " password; echo
    continue
  else
    err "  ✗ Could not connect:"
    sed 's/^/      /' "$tmpdir/ssherr" >&2
    exit 1
  fi
done

password=""   # no longer needed; the socket is authenticated

log "  ✔ connected."
build_rssh
export PATH="$tmpdir:$PATH"

if [ "$test_connection" -eq 1 ]; then
  log "  Running connection test (Claude Code will NOT launch)…"
  # shellcheck disable=SC2016  # single-quoted on purpose: it expands on the REMOTE side
  rssh 'echo "  reached $(hostname) as $(whoami)"'
  rc=$?
  log ""
  if [ "$rc" -eq 0 ]; then
    log "  ✔ connection test passed — the server is reachable over the socket."
    log "    Tearing down now; nothing was saved."
  else
    err "  ✗ connection test failed (rssh exit $rc)."
  fi
  exit "$rc"
fi

log "  Launching Claude Code — the server is wired up (use rssh to reach it)."
log ""

"$cc_bin" "$(briefing)"

# Falls through to trap cleanup: close master, remove ephemeral files.
