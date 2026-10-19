#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && ok || bad is the reporting idiom here; ok/bad never fail
# auto-update-test.sh — tools/ait-update.sh against a local git origin with two release
# tags and fake sudo/pgrep/loginctl (no network, no sudo, no systemd): it applies only
# when the box is free, follows the ref file, never touches a dirty tree, retries a
# failed bootstrap, and --check changes nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); UPD="$HERE/../tools/ait-update.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rc=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; rc=1; }

# ---- fakes -------------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/fake" "$T/home"
cat > "$T/bin/sudo" <<'SH'
#!/usr/bin/env bash
[ -e "$FAKE/no-sudo" ] && exit 1
[ "$1" = -n ] && shift; exec "$@"
SH
cat > "$T/bin/pgrep" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -x claude "*) [ -e "$FAKE/claude-running" ] ;; *) false ;; esac
SH
cat > "$T/bin/loginctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-sessions) [ -e "$FAKE/session" ] && printf '7 %s user seat0 tty2 active no -\n' "$(id -u)" ;;
  show-session)  [ -e "$FAKE/session" ] && printf 'State=active\nType=x11\nIdleHint=no\nLockedHint=%s\n' "$(cat "$FAKE/session")" ;;
esac
exit 0
SH
cat > "$T/bin/notify-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/notified"
SH
chmod +x "$T/bin/"*
export FAKE="$T/fake" HOME="$T/home" PATH="$T/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# ---- a tiny "kit" origin: a bootstrap stub that records its arguments, two releases ------
git init -q -b main "$T/origin"
cat > "$T/origin/bootstrap.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/bootstrap-args"
[ -e "$FAKE/bootstrap-fails" ] && exit 3
echo "bootstrap ran"
SH
chmod +x "$T/origin/bootstrap.sh"
echo one > "$T/origin/content"
( cd "$T/origin" && git add -A && GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git commit -q -m one && GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git tag v2026.01.01 )
echo two > "$T/origin/content"
( cd "$T/origin" && git add -A && GIT_COMMITTER_DATE=2026-01-02T00:00:00Z git commit -q -m two && GIT_COMMITTER_DATE=2026-01-02T00:00:00Z git tag v2026.01.02 )
echo three > "$T/origin/content"
( cd "$T/origin" && git add -A && GIT_COMMITTER_DATE=2026-01-03T00:00:00Z git commit -q -m "main ahead of the newest tag" )

BOX="$T/home/ai-terminal"
git clone -q "$T/origin" "$BOX" && git -C "$BOX" -c advice.detachedHead=false checkout -q v2026.01.01
export AIT_DIR="$BOX"
CONF="$HOME/.config/ai-terminal"; STATE="$HOME/.local/state/ai-terminal"; mkdir -p "$CONF"
at()     { git -C "$BOX" describe --tags --exact-match HEAD 2>/dev/null || git -C "$BOX" rev-parse --short HEAD; }
last()   { sed -n "s/^$1=//p" "$STATE/update-last" 2>/dev/null; }
run()    { bash "$UPD" "$@" >"$T/out" 2>&1; echo $? > "$T/rc"; }
reset()  { rm -f "$FAKE"/* "$STATE/update-last" "$STATE/bootstrap-pending"; }

echo "1. --check on a box behind the newest tag: says so, applies nothing, stamps nothing"
run --check
grep -q 'applied → v2026.01.02: would apply' "$T/out" && ok "--check reports the pending release" || bad "--check output: $(cat "$T/out")"
[ "$(at)" = v2026.01.01 ] && ok "checkout untouched" || bad "checkout moved to $(at)"
[ ! -e "$STATE/update-last" ] && ok "no stamp written" || bad "stamp written by --check"

echo "2. claude running → deferred, nothing applied"
touch "$FAKE/claude-running"; run
[ "$(last result)" = deferred ] && [ "$(at)" = v2026.01.01 ] && ok "deferred ($(last reason))" || bad "result=$(last result) at $(at)"
[ "$(last deferred_count)" = 1 ] && ok "deferral count starts at 1" || bad "deferred_count=$(last deferred_count)"
run; [ "$(last deferred_count)" = 2 ] && ok "second deferral counts up" || bad "deferred_count=$(last deferred_count)"
rm -f "$FAKE/claude-running"

echo "3. someone at an unlocked desktop → deferred"
echo no > "$FAKE/session"; run
[ "$(last result)" = deferred ] && grep -q "at the desktop" "$STATE/update-last" && ok "deferred: $(last reason)" || bad "result=$(last result): $(last reason)"

echo "4. sudo wants a password → deferred with the --now hint"
touch "$FAKE/no-sudo"; run
[ "$(last result)" = deferred ] && grep -q 'ait-update --now' "$STATE/update-last" && ok "deferred: $(last reason)" || bad "result=$(last result)"
rm -f "$FAKE/no-sudo"

echo "5. screen locked → applied: newest tag checked out, bootstrap re-run with the recorded extras"
echo yes > "$FAKE/session"; printf 'docker\nxrdp\n' > "$CONF/extras"; run
[ "$(last result)" = applied ] && ok "applied" || bad "result=$(last result): $(last reason) / $(cat "$T/out")"
[ "$(at)" = v2026.01.02 ] && ok "checkout now at v2026.01.02" || bad "checkout at $(at)"
[ "$(cat "$FAKE/bootstrap-args" 2>/dev/null)" = "--with-docker --with-xrdp" ] && ok "bootstrap ran with --with-docker --with-xrdp" || bad "bootstrap args: $(cat "$FAKE/bootstrap-args" 2>/dev/null)"
[ "$(last deferred_count)" = "" ] && ok "deferral counter cleared" || bad "deferred_count still $(last deferred_count)"
grep -q "updated to v2026.01.02" "$FAKE/notified" 2>/dev/null && ok "desktop notified" || bad "no notification"
run; [ "$(last result)" = current ] && ok "next tick: current" || bad "next tick: $(last result)"
[ "$(wc -l < "$FAKE/bootstrap-args")" = 1 ] && ok "bootstrap not re-run when current" || bad "bootstrap re-run"

echo "6. a failed bootstrap is retried on the next tick, on the same ref"
reset; echo yes > "$FAKE/session"; git -C "$BOX" -c advice.detachedHead=false checkout -q v2026.01.01
touch "$FAKE/bootstrap-fails"; run
[ "$(cat "$T/rc")" = 1 ] && [ "$(last result)" = failed ] && ok "failed, exit 1: $(last reason)" || bad "rc=$(cat "$T/rc") result=$(last result)"
[ -e "$STATE/bootstrap-pending" ] && ok "pending marker set" || bad "no pending marker"
rm -f "$FAKE/bootstrap-fails"; run
[ "$(last result)" = applied ] && [ ! -e "$STATE/bootstrap-pending" ] && ok "retried and applied" || bad "retry: $(last result)"

echo "7. local changes → skipped, tree untouched"
reset; echo yes > "$FAKE/session"; git -C "$BOX" -c advice.detachedHead=false checkout -q v2026.01.01; echo edit >> "$BOX/content"; run
[ "$(last result)" = skipped ] && [ "$(at)" = v2026.01.01 ] && ok "skipped: $(last reason)" || bad "result=$(last result) at $(at)"
git -C "$BOX" checkout -q -- content

echo "8. ref file pins a tag → current even though a newer tag exists"
reset; echo yes > "$FAKE/session"; echo v2026.01.01 > "$CONF/ref"; run
[ "$(last result)" = current ] && [ "$(at)" = v2026.01.01 ] && ok "pinned: $(last reason)" || bad "result=$(last result) at $(at)"

echo "9. ref file says main → fast-forwards to origin/main (ahead of every tag)"
reset; echo yes > "$FAKE/session"; echo main > "$CONF/ref"; run
[ "$(last result)" = applied ] && [ "$(git -C "$BOX" rev-parse HEAD)" = "$(git -C "$T/origin" rev-parse main)" ] && ok "on origin/main" || bad "result=$(last result) at $(at)"
rm -f "$CONF/ref"

echo "10. opt-out file → skipped; --now applies even with someone at the desktop"
reset; echo no > "$FAKE/session"; touch "$CONF/no-auto-update"; git -C "$BOX" -c advice.detachedHead=false checkout -q v2026.01.01; run
[ "$(last result)" = skipped ] && grep -q "opted out" "$STATE/update-last" && ok "opted out" || bad "result=$(last result)"
rm -f "$CONF/no-auto-update"; run --now
[ "$(last result)" = applied ] && [ "$(at)" = v2026.01.02 ] && ok "--now applied with the desktop in use" || bad "result=$(last result) at $(at)"

echo "11. no session at all (SSH-only box) and no claude → applies"
reset; git -C "$BOX" -c advice.detachedHead=false checkout -q v2026.01.01; run
[ "$(last result)" = applied ] && ok "applied with no graphical session" || bad "result=$(last result): $(last reason)"

echo "12. log has the run, --help works"
grep -q "v2026.01.01 → v2026.01.02" "$STATE/update.log" && ok "update.log records the move" || bad "log: $(tail -3 "$STATE/update.log")"
bash "$UPD" --help | grep -q -- '--check' && ok "--help" || bad "--help"

[ "$rc" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $rc
