#!/usr/bin/env bash
# ait-update — keep a public-kit box on the newest release without anyone touching it.
# Installed to ~/.local/bin by modules/core/04-auto-update.sh and run by the user timer
# ai-terminal-update.timer (every ~2 h). By hand:
#   ait-update            what the timer does: apply a newer release if the box is free
#   ait-update --check    say what it would do; changes nothing, stamps nothing
#   ait-update --now      apply even while someone is working here (you asked for it)
#
# Windows-Update-style: fetch, compare, and apply ONLY when nobody is working on this
# box — no `claude` process for this user, no active unlocked desktop session — else
# defer and let the timer retry. A checkout with local changes is never touched.
# The run is logged to ~/.local/state/ai-terminal/update.log; the last outcome goes to
# update-last (KEY=VALUE lines, what verify.sh reads).
#
# Which ref to follow: ~/.config/ai-terminal/ref, written by get.sh from AIT_REF —
# absent = newest release tag, "main" = track main, anything else = pinned (no-op).
# Extras: ~/.config/ai-terminal/extras, the union of every --with-<extra> this box ran
# bootstrap with (bootstrap.sh records it) — drop a line to stop maintaining one.
# Opt out of the whole thing: touch ~/.config/ai-terminal/no-auto-update
set -u
AIT_DIR="${AIT_DIR:-$HOME/ai-terminal}"
CONF="${AIT_CONF_DIR:-$HOME/.config/ai-terminal}"
STATE="${AIT_STATE_DIR:-$HOME/.local/state/ai-terminal}"
LOG="$STATE/update.log"; LAST="$STATE/update-last"; PENDING="$STATE/bootstrap-pending"

MODE=apply
case "${1:-}" in
    "")        ;;
    --check)   MODE=check ;;
    --now)     MODE=now ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "ait-update: unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
mkdir -p "$STATE" "$CONF"
have() { command -v "$1" >/dev/null 2>&1; }
say() {
    printf '[ait-update] %s\n' "$*"
    [ "$MODE" = check ] || printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}
# finish RESULT FROM TO REASON — one outcome per run: current | applied | deferred |
# skipped | failed. A deferral keeps the first deferral's timestamp and a count so
# verify.sh can tell "waiting for a free moment" from "stuck".
finish() {
    local result=$1 from=$2 to=$3 reason=$4 since="" count=0 prev_result="" prev_to=""
    say "$result${to:+ → $to}${reason:+: $reason}"
    [ "$MODE" = check ] && exit 0
    if [ -r "$LAST" ]; then
        prev_result=$(sed -n 's/^result=//p' "$LAST"); prev_to=$(sed -n 's/^to=//p' "$LAST")
        since=$(sed -n 's/^deferred_since=//p' "$LAST"); count=$(sed -n 's/^deferred_count=//p' "$LAST")
    fi
    if [ "$result" = deferred ]; then
        if [ "$prev_result" = deferred ] && [ "$prev_to" = "$to" ] && [ -n "$since" ]; then
            count=$(( ${count:-0} + 1 ))
        else
            since=$(date -u +%Y-%m-%dT%H:%M:%SZ); count=1
        fi
    else
        since=""; count=0
    fi
    {
        printf 'at=%s\nresult=%s\nfrom=%s\nto=%s\nreason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" "$from" "$to" "$reason"
        if [ -n "$since" ]; then printf 'deferred_since=%s\ndeferred_count=%s\n' "$since" "$count"; fi
    } > "$LAST.tmp" && mv -f "$LAST.tmp" "$LAST"
    case "$result" in failed) exit 1 ;; *) exit 0 ;; esac
}

# ---- is this box ours to update? ------------------------------------------------------
if [ -f /etc/asp-terminal.env ] || dpkg-query -W -f '${Status}' nice-dcv-server 2>/dev/null | grep -q 'install ok installed'; then
    finish skipped "" "" "fleet-managed box — its platform's updater delivers the kit"
fi
[ -e "$CONF/no-auto-update" ] && finish skipped "" "" "opted out ($CONF/no-auto-update exists)"
[ -d "$AIT_DIR/.git" ] || finish skipped "" "" "$AIT_DIR is not a git checkout"
have git || finish skipped "" "" "git not installed"
if [ -n "$(git -C "$AIT_DIR" status --porcelain 2>/dev/null)" ]; then
    finish skipped "" "" "local changes in $AIT_DIR — leaving the tree as it is"
fi
exec 9>"$STATE/update.lock"
if ! flock -n 9; then say "another run holds the lock"; exit 0; fi

# ---- where are we, where should we be? --------------------------------------------------
g() { git -C "$AIT_DIR" "$@"; }
head_id=$(g rev-parse HEAD 2>/dev/null) || finish skipped "" "" "cannot read HEAD in $AIT_DIR"
from=$(g describe --tags --exact-match HEAD 2>/dev/null || g rev-parse --short HEAD)
ref=""; [ -r "$CONF/ref" ] && ref=$(tr -d '[:space:]' < "$CONF/ref")

if ! timeout 120 git -C "$AIT_DIR" fetch --quiet --tags --force origin 2>>"$LOG"; then
    finish deferred "$from" "" "fetch failed (offline?) — retrying at the next tick"
fi
case "$ref" in
    "")   target=$(g tag --list 'v*' --sort=-creatordate | head -1)
          [ -n "$target" ] || finish skipped "$from" "" "no release tags in origin"
          target_id=$(g rev-parse "$target^{commit}" 2>/dev/null) ;;
    main) target=main; target_id=$(g rev-parse origin/main 2>/dev/null) ;;
    *)    target=$ref
          target_id=$(g rev-parse "$ref^{commit}" 2>/dev/null) || finish skipped "$from" "$ref" "pinned ref not found in origin" ;;
esac
[ -n "${target_id:-}" ] || finish skipped "$from" "$target" "cannot resolve $target"

if [ "$head_id" = "$target_id" ] && [ ! -e "$PENDING" ]; then
    finish current "$from" "$target" "already at $target"
fi
# a bootstrap that failed last time is retried on the same ref (it is idempotent)
[ "$head_id" = "$target_id" ] && from="$target (bootstrap pending)"

# ---- is anybody working here? ------------------------------------------------------------
if [ "$MODE" != now ]; then
    if ! sudo -n true 2>/dev/null; then
        finish deferred "$from" "$target" "sudo needs a password here (01-sudo-nopasswd not applied) — bootstrap cannot run unattended; run: ait-update --now"
    fi
    if pgrep -u "$(id -u)" -x claude >/dev/null 2>&1; then
        finish deferred "$from" "$target" "claude is running — not while someone is mid-session"
    fi
    if pgrep -u "$(id -u)" -f '/bootstrap\.sh' >/dev/null 2>&1; then
        finish deferred "$from" "$target" "bootstrap.sh is already running"
    fi
    # an active, unlocked graphical session = a person at the desk. A locked screen or
    # an SSH-only login counts as free (the same "nobody connected" rule as a fleet box).
    if have loginctl; then
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -u)" '$2 == u { print $1 }'); do
            State=""; Type=""; LockedHint=""; IdleHint=""
            eval "$(loginctl show-session "$s" -p State -p Type -p IdleHint -p LockedHint 2>/dev/null | grep -E '^(State|Type|IdleHint|LockedHint)=')"
            case "$Type" in x11|wayland|mir) ;; *) continue ;; esac
            if [ "$State" = active ] && [ "$LockedHint" != yes ] && [ "$IdleHint" != yes ]; then
                finish deferred "$from" "$target" "someone is at the desktop (session $s unlocked) — applies once it is locked or idle"
            fi
        done
    fi
fi
[ "$MODE" = check ] && finish applied "$from" "$target" "would apply now"

# ---- apply ---------------------------------------------------------------------------------
say "updating $AIT_DIR: $from → $target"
if [ "$head_id" != "$target_id" ]; then
    if [ "$target" = main ]; then
        { g checkout --quiet main 2>/dev/null || g checkout --quiet -B main origin/main; } \
            && g merge --quiet --ff-only origin/main
    else
        g -c advice.detachedHead=false checkout --quiet "$target"
    fi >>"$LOG" 2>&1 || finish failed "$from" "$target" "git checkout of $target failed (see $LOG)"
fi
extras=()
if [ -r "$CONF/extras" ]; then
    while IFS= read -r e; do
        e=$(printf '%s' "$e" | tr -d '[:space:]'); [ -n "$e" ] && extras+=("--with-$e")
    done < "$CONF/extras"
fi
: > "$PENDING"
say "running bootstrap.sh ${extras[*]:-} (log: $LOG)"
if timeout 3600 bash "$AIT_DIR/bootstrap.sh" ${extras[@]+"${extras[@]}"} >>"$LOG" 2>&1; then
    rm -f "$PENDING"
    have notify-send && notify-send "Ai Terminal" "Kit updated to $target" 2>/dev/null
    finish applied "$from" "$target" "bootstrap ok${extras[*]:+ (${extras[*]})}"
else
    rc=$?
    have notify-send && notify-send -u critical "Ai Terminal" "Kit update to $target failed — see $LOG" 2>/dev/null
    finish failed "$from" "$target" "bootstrap exited $rc — retried at the next tick; log: $LOG"
fi
