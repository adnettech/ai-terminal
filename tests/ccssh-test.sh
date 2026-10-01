#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && ok || bad is the reporting idiom here; ok/bad never fail
# ccssh-test.sh — the password path of tools/ccssh.sh, with a fake `ssh` (no network):
# the ask-pass helper receives the password, the long-lived master's ENVIRONMENT never
# holds it, a wrong password is retried, and --test-connection runs through rssh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); CCSSH="$HERE/../tools/ccssh.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -V "*) echo "OpenSSH_9.6p1 Ubuntu" >&2; exit 0 ;;
  *" -O exit "*) exit 0 ;;
  *" -M "*)  # the master: ask for the password exactly like OpenSSH does, then record our env
     pw=$("$SSH_ASKPASS")
     tr '\0' '\n' < /proc/$$/environ > "$FAKE_DIR/master-env"
     echo "$pw" >> "$FAKE_DIR/received"
     [ "$pw" = "$FAKE_GOOD_PW" ] && exit 0
     echo "Permission denied, please try again." >&2; exit 255 ;;
  *" ControlMaster=no "*) shift $(( $# - 1 )); bash -c "$1"; exit $? ;;   # rssh: run locally
esac
exit 99
SH
chmod +x "$T/bin/ssh"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"
fails=0; ok(){ echo "ok   $*"; }; bad(){ echo "FAIL $*"; fails=$((fails+1)); }
run() { PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_GOOD_PW="s3cret-pw" "$@"; }

: > "$T/received"
out=$(printf 's3cret-pw\n' | run bash "$CCSSH" --host https://srv.example.com/x --user u --port 22 --test-connection 2>&1); rc=$?
[ "$rc" = 0 ] && ok "connects and --test-connection passes" || bad "rc=$rc: $out"
grep -qx 's3cret-pw' "$T/received" && ok "ask-pass helper delivered the password" || bad "helper got: $(cat "$T/received")"
grep -v '^FAKE_GOOD_PW=' "$T/master-env" | grep -q 's3cret-pw' && bad "password found in the master's environment" || ok "master's environment holds no password (only the harness's own FAKE_GOOD_PW)"
printf '%s' "$out" | grep -q 'host normalized: https://srv.example.com/x  →  srv.example.com' && ok "URL host normalized" || bad "no normalization line"
printf '%s' "$out" | grep -q 'reached' && ok "rssh ran the test command" || bad "rssh did not run"

: > "$T/received"
out=$(printf 'wrong\ns3cret-pw\n' | run bash "$CCSSH" --host h --user u --port 22 --test-connection 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l < "$T/received")" = 2 ] && ok "wrong password retried, then accepted" || bad "retry rc=$rc received=$(wc -l < "$T/received")"

out=$(printf 'wrong\nwrong\nwrong\n' | run bash "$CCSSH" --host h --user u --port 22 --test-connection 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'failed 3 times' && ok "gives up after 3 attempts" || bad "rc=$rc"

ls -d "${TMPDIR:-/tmp}"/ccssh.* >/dev/null 2>&1 && bad "an ephemeral ccssh.* dir was left behind" || ok "ephemeral dir removed"
echo; [ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
