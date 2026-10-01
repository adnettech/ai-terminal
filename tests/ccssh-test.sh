#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && ok || bad is the reporting idiom here; ok/bad never fail
# ccssh-test.sh — tools/ccssh.sh with a fake `ssh` (no network): the ask-pass helper gets
# the password, the long-lived master's ENVIRONMENT never holds it, a wrong password is
# retried, --test-connection runs through rssh, and a connection that DROPS mid-session is
# re-opened by the keeper while rssh waits (the session stays durable).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); CCSSH="$HERE/../tools/ccssh.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# fake ssh: "$FAKE_DIR/alive" stands in for a live ControlMaster
cat > "$T/bin/ssh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -V "*) echo "OpenSSH_9.6p1 Ubuntu" >&2; exit 0 ;;
  *" -O check "*) [ -f "$FAKE_DIR/alive" ]; exit $? ;;
  *" -O exit "*) rm -f "$FAKE_DIR/alive"; exit 0 ;;
  *" -M "*)  # the master: ask for the password exactly like OpenSSH does, record our env
     pw=$("$SSH_ASKPASS")
     tr '\0' '\n' < /proc/$$/environ > "$FAKE_DIR/master-env.$(date +%s%N)"
     echo "$pw" >> "$FAKE_DIR/received"
     [ "$pw" = "$FAKE_GOOD_PW" ] && { touch "$FAKE_DIR/alive"; exit 0; }
     echo "Permission denied, please try again." >&2; exit 255 ;;
  *" ControlMaster=no "*)
     [ -f "$FAKE_DIR/alive" ] || { echo "Control socket connect: No such file or directory" >&2; exit 255; }
     shift $(( $# - 1 )); bash -c "$1"; exit $? ;;
esac
exit 99
SH
chmod +x "$T/bin/ssh"
# fake claude: one command, a simulated drop, a second command that must survive it
cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
rssh 'echo first-ok' >> "$FAKE_DIR/claude.out" 2>&1
rm -f "$FAKE_DIR/alive"                     # the link drops (network blip / server reboot)
rssh 'echo after-drop-ok' >> "$FAKE_DIR/claude.out" 2>&1
SH
chmod +x "$T/bin/claude"
fails=0; ok(){ echo "ok   $*"; }; bad(){ echo "FAIL $*"; fails=$((fails+1)); }
run() { PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_GOOD_PW="s3cret-pw" CCSSH_CHECK_EVERY=1 CCSSH_RSSH_WAIT=30 "$@"; }
noleak() { local f; for f in "$T"/master-env.*; do grep -v '^FAKE_GOOD_PW=' "$f" | grep -q 's3cret-pw' && return 1; done; return 0; }

: > "$T/received"
out=$(printf 's3cret-pw\n' | run bash "$CCSSH" --host https://srv.example.com/x --user u --port 22 --test-connection 2>&1); rc=$?
[ "$rc" = 0 ] && ok "connects and --test-connection passes" || bad "rc=$rc: $out"
grep -qx 's3cret-pw' "$T/received" && ok "ask-pass helper delivered the password" || bad "helper got: $(cat "$T/received")"
noleak && ok "master's environment holds no password (harness's own FAKE_GOOD_PW excepted)" || bad "password found in a master's environment"
printf '%s' "$out" | grep -q 'host normalized: https://srv.example.com/x  →  srv.example.com' && ok "URL host normalized" || bad "no normalization line"
printf '%s' "$out" | grep -q 'reached' && ok "rssh ran the test command" || bad "rssh did not run"

: > "$T/received"
out=$(printf 'wrong\ns3cret-pw\n' | run bash "$CCSSH" --host h --user u --port 22 --test-connection 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l < "$T/received")" = 2 ] && ok "wrong password retried, then accepted" || bad "retry rc=$rc received=$(wc -l < "$T/received")"

out=$(printf 'wrong\nwrong\nwrong\n' | run bash "$CCSSH" --host h --user u --port 22 --test-connection 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'failed 3 times' && ok "gives up after 3 attempts" || bad "rc=$rc"

# durability: a full session (fake claude) whose connection drops between two commands
: > "$T/received"; rm -f "$T"/master-env.* "$T/claude.out"
out=$(printf 's3cret-pw\n' | timeout 60 env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_GOOD_PW="s3cret-pw" CCSSH_CHECK_EVERY=1 CCSSH_RSSH_WAIT=30 bash "$CCSSH" --host h --user u --port 22 2>&1); rc=$?
grep -qx 'first-ok' "$T/claude.out" && ok "session: first command ran" || bad "session: first command missing ($(cat "$T/claude.out" 2>/dev/null))"
grep -q 'dropped — waiting for ccssh to reconnect' "$T/claude.out" && ok "session: rssh noticed the drop and waited" || bad "session: no wait message"
grep -qx 'after-drop-ok' "$T/claude.out" && ok "session: command after the drop ran on the re-opened connection" || bad "session: command after the drop failed (rc=$rc; $(tail -3 "$T/claude.out" 2>/dev/null))"
[ "$(wc -l < "$T/received")" = 2 ] && ok "session: keeper re-sent the password through the FIFO (2 logins)" || bad "session: logins=$(wc -l < "$T/received")"
noleak && ok "session: no master's environment ever held the password" || bad "session: password found in a master's environment"
[ ! -f "$T/alive" ] && ok "session: master closed when Claude Code exited" || bad "session: master left open"
pgrep -f "$T/" >/dev/null 2>&1 && bad "session: a ccssh process survived the session" || ok "session: no keeper survived the session"

ls -d "${TMPDIR:-/tmp}"/ccssh.* >/dev/null 2>&1 && bad "an ephemeral ccssh.* dir was left behind" || ok "ephemeral dirs removed"
echo; [ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
