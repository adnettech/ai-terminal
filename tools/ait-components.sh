#!/usr/bin/env bash
# ait-components — keep what the kit installed current between kit releases.
# Installed to ~/.local/bin by modules/core/26-component-updates.sh and run once a day by
# the user timer ai-terminal-components.timer. By hand:
#   ait-components            update everything below that has something newer
#   ait-components --check    list what is managed and its version; changes nothing
#   ait-components --now      also update system packages while someone is working here
#
# A kit release re-runs bootstrap, and bootstrap installs what is missing — it never
# moved anything that was already there. So a box kept the plugin, runtime and package
# versions of the day it was set up. This is the other half: each component is asked for
# its own newest version, on the box's own schedule.
#
#   Claude Code      claude update (it also updates itself; this covers a box where it has not)
#   plugins          every plugin installed for this user, from its marketplace — claude-mem,
#                    superpowers and any added since. A session picks the new version up the
#                    next time it starts.
#   bun, uv          their own self-update (only the copies the kit installed under ~)
#   usagemeter       the --with-usagemeter checkout, when it is behind its origin
#   system packages  the third-party apt packages the kit installed (Node.js, Docker,
#                    Tailscale) plus any named in ~/.config/ai-terminal/component-packages,
#                    one per line. Ubuntu's own packages are unattended-upgrades' job
#                    (03-updates-policy); it does not cover third-party repositories.
#
# The per-user steps disturb nothing that is running, so they run whenever the timer fires.
# System packages restart services, so they wait for a free box — no `claude` process, no
# unlocked desktop session — and Docker also waits while a container is running. They need
# passwordless sudo (01-sudo-nopasswd); without it they are skipped, never prompted for.
# One step failing never stops the others. Log: ~/.local/state/ai-terminal/components.log;
# last outcome: components-last (KEY=VALUE lines, what verify.sh reads).
# Opt out: touch ~/.config/ai-terminal/no-component-update
set -u
CONF="${AIT_CONF_DIR:-$HOME/.config/ai-terminal}"
STATE="${AIT_STATE_DIR:-$HOME/.local/state/ai-terminal}"
LOG="$STATE/components.log"; LAST="$STATE/components-last"
STEP_TIMEOUT="${AIT_STEP_TIMEOUT:-900}"
# the third-party apt packages the kit's own modules install (05-node, docker, tailscale)
KIT_PACKAGES="nodejs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin tailscale"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

MODE=apply
case "${1:-}" in
    "")        ;;
    --check)   MODE=check ;;
    --now)     MODE=now ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "ait-components: unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
mkdir -p "$STATE" "$CONF"
have() { command -v "$1" >/dev/null 2>&1; }
logline() { [ "$MODE" = check ] || printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
# run a step's command: bounded, no terminal to wait on, output to the log only
run() { if [ "$MODE" = check ]; then return 0; fi; timeout "$STEP_TIMEOUT" "$@" </dev/null >>"$LOG" 2>&1; }

UPDATED=(); FAILED=(); WAITING=()
# note NAME STATE DETAIL — STATE: current | updated | waiting | skipped | failed (--check: installed)
note() {
    printf '  %-16s %-9s %s\n' "$1" "$2" "$3"
    logline "$1: $2 $3"
    case "$2" in
        updated) UPDATED+=("$1") ;;
        failed)  FAILED+=("$1") ;;
        waiting) WAITING+=("$1") ;;
    esac
}
# moved NAME BEFORE AFTER RC — the usual ending of a step that has a version to compare
moved() {
    if [ "$4" != 0 ]; then note "$1" failed "exit $4 (see $LOG)"
    elif [ -n "$3" ] && [ "$2" != "$3" ]; then note "$1" updated "$2 → $3"
    else note "$1" current "$2"; fi
}

if [ -e "$CONF/no-component-update" ] && [ "$MODE" = apply ]; then
    echo "[ait-components] opted out ($CONF/no-component-update exists)"
    printf 'at=%s\nresult=skipped\nreason=opted out\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LAST"
    exit 0
fi
if [ "$MODE" != check ]; then
    exec 9>"$STATE/components.lock"
    flock -n 9 || { echo "[ait-components] another run holds the lock"; exit 0; }
    # bootstrap installs and configures the same things; let it finish first
    if pgrep -u "$(id -u)" -f '/bootstrap\.sh' >/dev/null 2>&1; then
        echo "[ait-components] bootstrap.sh is running — next time"; exit 0
    fi
    # keep the log from growing without bound: the last ~2000 lines are plenty
    if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 4000 ]; then
        tail -2000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
    fi
    logline "---- run ($MODE)"
fi
echo "[ait-components] $([ "$MODE" = check ] && echo "managed components (nothing is changed)" || echo "updating components")"

# ---- Claude Code -----------------------------------------------------------------------
# An explicit "no auto-updates" (the documented setting, in the environment or any settings
# file) is a pin somebody chose; honour it here too.
claude_pinned() {
    [ "${DISABLE_AUTOUPDATER:-}" = 1 ] && return 0
    grep -qsE '"DISABLE_AUTOUPDATER"[[:space:]]*:[[:space:]]*"?(1|true)' \
        "$HOME/.claude/settings.json" /etc/claude-code/managed-settings.json
}
if have claude; then
    v1=$(claude --version 2>/dev/null | awk '{print $1; exit}')
    if claude_pinned; then note claude-code skipped "$v1 — auto-updates are turned off (DISABLE_AUTOUPDATER)"
    elif [ "$MODE" = check ]; then note claude-code installed "$v1"
    else
        run claude update; rc=$?
        moved claude-code "$v1" "$(claude --version 2>/dev/null | awk '{print $1; exit}')" "$rc"
    fi

    # ---- plugins: every one installed for this user --------------------------------------
    if have jq; then
        PL=$(timeout 60 claude plugin list --json 2>/dev/null \
            | jq -r '.[] | select(.scope == "user" and (.id | endswith("@builtin") | not)) | "\(.id)\t\(.version)"' 2>/dev/null)
        if [ -z "$PL" ]; then
            note plugins skipped "none installed for this user"
        else
            if [ "$MODE" != check ]; then
                run claude plugin marketplace update || note marketplaces failed "could not refresh the plugin marketplaces (offline?) — see $LOG"
            fi
            while IFS=$'\t' read -r id v1; do
                [ -n "$id" ] || continue
                name=${id%%@*}
                if [ "$MODE" = check ]; then note "$name" installed "$v1  ($id)"; continue; fi
                # a marketplace that declares a command to run is never accepted unattended:
                # without -y the CLI refuses it and this reports the failure
                out=$(timeout "$STEP_TIMEOUT" claude plugin update "$id" --json </dev/null 2>>"$LOG"); rc=$?
                printf '%s\n' "$out" >> "$LOG"
                v2=$(printf '%s\n' "$out" | tail -1 | jq -r '.newVersion // empty' 2>/dev/null)
                moved "$name" "$v1" "${v2:-$v1}" "$rc"
            done <<< "$PL"
        fi
    else
        note plugins skipped "jq is not installed (00-base-cli installs it)"
    fi
else
    note claude-code skipped "not installed"
fi

# ---- bun, uv: only the copies the kit's installers put under ~ ---------------------------
if [ -x "$HOME/.bun/bin/bun" ]; then
    v1=$("$HOME/.bun/bin/bun" --version 2>/dev/null)
    if [ "$MODE" = check ]; then note bun installed "$v1"
    else run "$HOME/.bun/bin/bun" upgrade; rc=$?; moved bun "$v1" "$("$HOME/.bun/bin/bun" --version 2>/dev/null)" "$rc"; fi
fi
if [ -x "$HOME/.local/bin/uv" ]; then
    v1=$("$HOME/.local/bin/uv" --version 2>/dev/null | awk '{print $2; exit}')
    if [ "$MODE" = check ]; then note uv installed "$v1"
    else run "$HOME/.local/bin/uv" self update; rc=$?; moved uv "$v1" "$("$HOME/.local/bin/uv" --version 2>/dev/null | awk '{print $2; exit}')" "$rc"; fi
fi

# ---- usagemeter (--with-usagemeter): a git checkout with its own installer ---------------
UM="$HOME/.local/share/usagemeter"
if [ -d "$UM/.git" ] && have git; then
    v1=$(git -C "$UM" rev-parse --short HEAD 2>/dev/null)
    if [ "$MODE" = check ]; then note usagemeter installed "$v1"
    elif [ -n "$(git -C "$UM" status --porcelain 2>/dev/null)" ]; then note usagemeter skipped "$v1 — local changes in $UM"
    elif ! run git -C "$UM" fetch --quiet origin; then note usagemeter failed "fetch failed (offline?)"
    elif [ "$(git -C "$UM" rev-parse HEAD)" = "$(git -C "$UM" rev-parse FETCH_HEAD 2>/dev/null)" ]; then note usagemeter current "$v1"
    else
        run git -C "$UM" merge --quiet --ff-only FETCH_HEAD && ( cd "$UM" && run bash install.sh ); rc=$?
        moved usagemeter "$v1" "$(git -C "$UM" rev-parse --short HEAD 2>/dev/null)" "$rc"
    fi
fi

# ---- system packages from third-party apt repositories -------------------------------------
pkg_version() { dpkg-query -W -f '${Status}\t${Version}' "$1" 2>/dev/null | sed -n 's/^install ok installed\t//p'; }
# Echoes why the box is not free, nothing when it is — the same rule ait-update applies.
busy_reason() {
    if pgrep -u "$(id -u)" -x claude >/dev/null 2>&1; then echo "claude is running"; return; fi
    have loginctl || return 0
    local s State Type LockedHint IdleHint
    for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -u)" '$2 == u { print $1 }'); do
        State=""; Type=""; LockedHint=""; IdleHint=""
        eval "$(loginctl show-session "$s" -p State -p Type -p IdleHint -p LockedHint 2>/dev/null | grep -E '^(State|Type|IdleHint|LockedHint)=')"
        case "$Type" in x11|wayland|mir) ;; *) continue ;; esac
        if [ "$State" = active ] && [ "$LockedHint" != yes ] && [ "$IdleHint" != yes ]; then
            echo "someone is at the desktop"; return
        fi
    done
}
PKGS=()
for p in $KIT_PACKAGES $( [ -r "$CONF/component-packages" ] && sed -e 's/#.*//' "$CONF/component-packages" ); do
    case " ${PKGS[*]:-} " in *" $p "*) continue ;; esac
    [ -n "$(pkg_version "$p")" ] && PKGS+=("$p")
done
if [ ${#PKGS[@]} -eq 0 ]; then
    :
elif [ "$MODE" = check ]; then
    for p in "${PKGS[@]}"; do note "$p" installed "$(pkg_version "$p")  (apt)"; done
elif ! sudo -n true 2>/dev/null; then
    note packages skipped "sudo needs a password here (01-sudo-nopasswd not applied): ${PKGS[*]}"
elif BUSY=$(busy_reason); [ -n "$BUSY" ] && [ "$MODE" != now ]; then
    note packages waiting "$BUSY — ${PKGS[*]} update when the box is free (or: ait-components --now)"
else
    if [ "$MODE" != now ] && have docker && [ -n "$(timeout 20 docker ps -q 2>/dev/null)" ]; then
        KEEP=()
        for p in "${PKGS[@]}"; do case "$p" in docker-*|containerd.io) ;; *) KEEP+=("$p") ;; esac; done
        [ ${#KEEP[@]} -ne ${#PKGS[@]} ] && note docker waiting "a container is running — Docker updates once none is"
        PKGS=(${KEEP[@]+"${KEEP[@]}"})
    fi
    if [ ${#PKGS[@]} -gt 0 ]; then
        APT=(sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300)
        declare -A BEFORE=()
        for p in "${PKGS[@]}"; do BEFORE[$p]=$(pkg_version "$p"); done
        if ! run "${APT[@]}" update -q; then
            note packages failed "apt-get update failed (see $LOG): ${PKGS[*]}"
        else
            # keep a config file somebody edited: an unattended run must never stop to ask
            run "${APT[@]}" install -y -q --only-upgrade -o Dpkg::Options::=--force-confold "${PKGS[@]}"; rc=$?
            for p in "${PKGS[@]}"; do moved "$p" "${BEFORE[$p]}" "$(pkg_version "$p")" "$rc"; done
        fi
    fi
fi

# ---- outcome ---------------------------------------------------------------------------------
[ "$MODE" = check ] && exit 0
result=ok; [ ${#FAILED[@]} -gt 0 ] && result=failed
{
    printf 'at=%s\nresult=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result"
    printf 'updated=%s\nfailed=%s\nwaiting=%s\n' "${UPDATED[*]:-}" "${FAILED[*]:-}" "${WAITING[*]:-}"
} > "$LAST.tmp" && mv -f "$LAST.tmp" "$LAST"
echo "[ait-components] ${#UPDATED[@]} updated${UPDATED[*]:+ (${UPDATED[*]})}, ${#FAILED[@]} failed${FAILED[*]:+ (${FAILED[*]})}${WAITING[*]:+, waiting: ${WAITING[*]}}"
[ "$result" = ok ]
