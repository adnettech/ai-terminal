#!/usr/bin/env bash
# Read-only state check for an ai-terminal box. Prints PASS/FAIL/SKIP per
# item; exits 1 if anything FAILs. Safe to run any time.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

FAILED=0
p() { printf '  %sPASS%s  %s\n' "$C_GREEN"  "$C_OFF" "$*"; }
f() { printf '  %sFAIL%s  %s\n' "$C_RED"    "$C_OFF" "$*"; FAILED=1; }
s() { printf '  %sSKIP%s  %s\n' "$C_YELLOW" "$C_OFF" "$*"; }

log "ai-terminal verify — core"

# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; then
    p "Ubuntu 24.04 (${PRETTY_NAME:-})"
else
    f "OS is ${PRETTY_NAME:-unknown}, expected Ubuntu 24.04"
fi

for pkg in git gh tmux curl jq unzip lynx xvfb openssh-server; do
    if pkg_installed "$pkg"; then p "apt: $pkg"; else f "apt: $pkg missing"; fi
done

# 03-updates-policy (#71): the release-upgrade dialog must never appear, and
# ordinary updates must not need a Software Updater window.
if sudo -n grep -qsE '^Prompt=never$' /etc/update-manager/release-upgrades 2>/dev/null \
   || grep -qsE '^Prompt=never$' /etc/update-manager/release-upgrades; then
    p "release upgrades: Prompt=never (no 'Ubuntu XX.04 Upgrade Available' dialog)"
else
    f "release upgrades: /etc/update-manager/release-upgrades is not Prompt=never — users can be offered 26.04"
fi
if grep -qs -- '-updates' /etc/apt/apt.conf.d/52claude-terminal-updates \
   && grep -qs 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/52claude-terminal-updates \
   && pkg_installed unattended-upgrades; then
    p "unattended-upgrades: on, -updates pocket included, no automatic reboot"
else
    f "unattended-upgrades policy missing (03-updates-policy writes /etc/apt/apt.conf.d/52claude-terminal-updates)"
fi
if pkg_installed update-notifier; then
    if [ -f /etc/dconf/db/local.d/locks/04-claude-terminal-updates ] && [ -f /etc/dconf/db/local ]; then
        p "update-notifier: notifications + auto-launch off, dist-upgrade check off (dconf-locked); restart prompt kept"
    else
        f "update-notifier quiet policy missing (dconf lock 04-claude-terminal-updates)"
    fi
else
    s "update-notifier not installed (no GUI update prompts to silence)"
fi

# Cloud AMIs can ship /etc/sudoers.d closed to non-root (0750), so fall back
# to a prompt-free sudo read — NOPASSWD working is itself the thing checked.
sudoers_rule="/etc/sudoers.d/010-$(id -un | tr '.' '_')-nopasswd"
if [ -s "$sudoers_rule" ] || sudo -n test -s "$sudoers_rule" 2>/dev/null; then
    p "passwordless sudo rule present"
else
    f "passwordless sudo rule missing or empty ($sudoers_rule)"
fi

# shellcheck disable=SC2088  # tilde is display text; the test itself uses $HOME
if [ -d "$HOME/Projects" ]; then p "~/Projects exists"; else f "~/Projects missing"; fi

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"

if have node && [ "$(node -v | sed 's/^v//; s/\..*//')" = "20" ]; then
    p "node $(node -v)"
else
    f "node 20 not found ($(node -v 2>/dev/null || echo none))"
fi

if [ "$(npm config get prefix 2>/dev/null)" = "$HOME/.npm-global" ]; then
    p "npm prefix ~/.npm-global"
else
    f "npm prefix is '$(npm config get prefix 2>/dev/null)', expected ~/.npm-global"
fi

if have claude; then
    p "claude $(claude --version 2>/dev/null | head -1)"
    if claude_bedrock_ready; then p "claude → Amazon Bedrock (managed settings; no login needed)"
    elif claude_ready; then p "claude logged in"
    else s "claude not logged in yet (run 'claude')"; fi
else
    f "claude not on PATH"
fi

if grep -qE 'PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    p ".bashrc puts ~/.local/bin on PATH (claude reachable without a login shell)"
else
    f ".bashrc does not export ~/.local/bin — claude off PATH in DCV/cloud sessions"
fi

if is_dcv_terminal; then
    # #27 items 3+4 — two questions that needed a live desktop, made permanent checks.
    if [ -n "${DISPLAY:-}" ]; then
        if pgrep -u "$(id -u)" -f google-chrome >/dev/null 2>&1; then
            p "Chrome warm start resident (--no-startup-window keeps the process alive)"
        else
            s "Chrome not resident — fine if you closed it; on a fresh untouched session it means --no-startup-window exits instead of staying warm (#27)"
        fi
    else
        s "Chrome warm-start check needs a desktop session (no DISPLAY)"
    fi
    XTL="$HOME/.config/xdg-terminals.list"
    if [ -s "$XTL" ]; then
        p "xdg-terminals.list: default terminal recorded — $(head -n 1 "$XTL") (any entry silences the GNOME 46 prompt)"
    else
        f "xdg-terminals.list missing/empty — GNOME 46 will ask 'set as default terminal?' (40-gnome-qol seeds it)"
    fi
fi

if [ -x "$HOME/.local/bin/cct-finish" ] && grep -q 'claude-terminal postlogin-finish' "$HOME/.bashrc" 2>/dev/null; then
    p "cct-finish + post-login hook installed"
else
    f "cct-finish or its .bashrc hook missing (re-run ./bootstrap.sh)"
fi

if [ -x "$HOME/.bun/bin/bun" ]; then p "bun $("$HOME/.bun/bin/bun" --version)"; else f "bun missing"; fi
if have uv || [ -x "$HOME/.local/bin/uv" ]; then p "uv installed"; else f "uv missing"; fi

if [ -d "$HOME/.claude/plugins/cache/thedotmack" ]; then
    p "claude-mem plugin (thedotmack) present"
else
    if claude_bedrock_ready; then s "claude-mem plugin not installed yet (re-run ./bootstrap.sh or cct-finish)"
    else s "claude-mem plugin not installed yet (needs claude login + re-run bootstrap)"; fi
fi
if [ -d "$HOME/.claude/plugins/cache/superpowers-marketplace" ]; then
    p "superpowers plugin present"
else
    if claude_bedrock_ready; then s "superpowers plugin not installed yet (re-run ./bootstrap.sh or cct-finish)"
    else s "superpowers plugin not installed yet (needs claude login + re-run bootstrap)"; fi
fi

# claude-mem runtime artifacts only exist after the first claude session
# post-install, so absence right after bootstrap is expected (SKIP, not FAIL).
if [ -d "$HOME/.claude-mem" ]; then
    if [ -f "$HOME/.claude-mem/claude-mem.db" ]; then
        p "claude-mem database present"
    else
        s "claude-mem db not created yet (appears after first claude session)"
    fi
    if [ -f "$HOME/.claude-mem/supervisor.json" ] || [ -f "$HOME/.claude-mem/worker.pid" ]; then
        p "claude-mem worker state present"
    else
        s "claude-mem worker not started yet (starts with first session)"
    fi
else
    # shellcheck disable=SC2088  # tilde is display text
    s "~/.claude-mem not present yet (created on first claude session after install)"
fi

# Switcher window picker (46-switcher). Its whole job is telling terminal windows apart by
# title, so the checks that matter are the binding and the three patch markers — an
# extension update silently reverts the patches, and notify-send on a box nobody watches is
# not a signal. SKIP wherever it was never installed.
SW="$HOME/.local/share/gnome-shell/extensions/switcher@landau.fi"
if [ -d "$SW" ]; then
    # Ask the ENABLED LIST, not the runtime State. An extension that is enabled but which
    # the shell has not loaded yet reports INITIALIZED, and that is precisely the state
    # 46-switcher leaves behind -- it tells you to reload the shell rather than doing it to
    # a live desktop. Checking State therefore FAILed every freshly-provisioned box.
    if gnome-extensions list --enabled 2>/dev/null | grep -qx 'switcher@landau.fi'; then
        if gnome-extensions info switcher@landau.fi 2>/dev/null | grep -qiE 'state: *ENABLED'; then
            p "switcher extension enabled"
        else
            s "switcher enabled but not loaded yet — reload the shell or log out/in"
        fi
    else
        f "switcher installed but not enabled — gnome-extensions enable switcher@landau.fi"
    fi
    if [ "$(gsettings --schemadir "$SW/schemas" get org.gnome.shell.extensions.switcher show-switcher 2>/dev/null)" = "['<Alt>grave']" ]; then
        p "switcher bound to Alt+\`"
    else
        f "switcher not bound to Alt+\` — re-run ./bootstrap.sh"
    fi
    case "$(gsettings get org.gnome.desktop.wm.keybindings switch-group 2>/dev/null)" in
        *Alt\>Above_Tab*) f "GNOME switch-group still claims Alt+\` — it wins over the switcher" ;;
        *) p "Alt+\` freed from GNOME switch-group" ;;
    esac
    SWBAD=""
    grep -qF 'Activate BEFORE dropping the modal grab' "$SW/extension.js" 2>/dev/null      || SWBAD="$SWBAD focus-fix"
    grep -qF 'hide launchable (not running) apps'      "$SW/modes/launcher.js" 2>/dev/null || SWBAD="$SWBAD hide-apps"
    grep -qF 'EXCLUDED_WM_CLASSES'                     "$SW/modes/switcher.js" 2>/dev/null || SWBAD="$SWBAD exclude-wm"
    if [ -n "$SWBAD" ]; then
        f "switcher patches missing:$SWBAD — an extension update reverted them; run ~/.local/bin/switcher-patches"
    else
        p "switcher patches present (focus-fix, hide-apps, exclude-wm)"
    fi
    if systemctl --user is-active switcher-patches.path >/dev/null 2>&1; then
        p "switcher-patches.path watching for extension updates"
    elif [ -L "$HOME/.config/systemd/user/default.target.wants/switcher-patches.path" ]; then
        p "switcher-patches.path enabled (starts with the user session — not running in this shell)"
    else
        f "switcher-patches.path not enabled — an extension update will silently revert the patches (re-run ./bootstrap.sh)"
    fi
else
    s "switcher not installed (46-switcher skipped: no GNOME, or no build for this shell)"
fi

# A root-owned XDG dir silently defeats dconf/xdg-mime writes (gsettings still
# exits 0), so check ownership before trusting any GNOME state below.
_xdg_bad=""
for _d in .config .local .cache; do
    [ -e "$HOME/$_d" ] || continue
    [ "$(stat -c %u "$HOME/$_d" 2>/dev/null)" = "$(id -u)" ] || _xdg_bad="$_xdg_bad ~/$_d"
done
if [ -n "$_xdg_bad" ]; then
    f "not owned by $(id -un):$_xdg_bad — user-level writes (dconf, xdg-mime) fail silently; re-run ./bootstrap.sh to repair"
else
    p "XDG dirs owned by $(id -un)"
fi

# GNOME state reads straight from the dconf database — no session or bus
# needed, so these run on headless boxes too (cloud/DCV, unattended builds).
if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.shell$'; then
    if [ "$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null)" = "false" ]; then
        p "screen lock disabled"
    else
        f "screen lock still enabled"
    fi
    if [ "$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null)" = "uint32 0" ]; then
        p "idle blanking disabled"
    else
        f "idle-delay not 0"
    fi
    # DCV hosts lock the dock to Chrome (no Firefox snap there); everywhere
    # else the kit pins Firefox. Same three-slot dock, different browser.
    if is_dcv_terminal; then
        FAVS="['google-chrome.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']"
        FAVS_LABEL="Chrome, Files, Terminal (host-managed)"
    else
        FAVS="['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']"
        FAVS_LABEL="Firefox, Files, Terminal"
    fi
    if [ "$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)" = "$FAVS" ]; then
        p "dock favorites converged ($FAVS_LABEL)"
    else
        f "dock favorites are $(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo unreadable) — expected $FAVS_LABEL"
    fi
    if have dconf && [ -n "$(dconf dump /org/gnome/terminal/legacy/ 2>/dev/null)" ]; then
        p "terminal prefs present (seeded or user-customized)"
    else
        f "GNOME Terminal prefs tree empty — 42-terminal-prefs never seeded"
    fi
else
    s "no GNOME desktop on this box — GNOME checks skipped"
fi

if is_dcv_terminal; then
    s "DCV terminal — host owns session config (GDM not in use) — Wayland check n/a"
elif [ -d /etc/gdm3 ]; then
    if grep -qE '^WaylandEnable=false' /etc/gdm3/custom.conf 2>/dev/null; then
        p "Wayland disabled at GDM (X11 forced)"
    else
        f "WaylandEnable=false not set in /etc/gdm3/custom.conf (RustDesk/Splashtop need X11)"
    fi
else
    s "no GDM on this box (session comes from xrdp/etc.) — Wayland check n/a"
fi

if [ "$(systemd-detect-virt 2>/dev/null)" = "microsoft" ]; then
    if [ -f /etc/X11/xorg.conf.d/99-libinput-no-hires-scroll.conf ]; then
        p "hi-res scroll fix present"
    else
        f "hi-res scroll fix missing"
    fi
    if id -nG | grep -qw video; then p "user in video group"; else f "user not in video group"; fi
else
    s "not Hyper-V — VM QoL checks skipped"
fi

if pkg_installed okular; then p "okular installed"; else f "okular missing"; fi
if [ "$(xdg-mime query default text/markdown 2>/dev/null)" = "okularApplication_md.desktop" ]; then
    p "markdown opens in okular"
else
    s "text/markdown default is '$(xdg-mime query default text/markdown 2>/dev/null)'"
fi

# ---- 41-splashtop-cursorfix ---------------------------------------------------
# Only meaningful where Splashtop is installed; RustDesk/other boxes SKIP.
cursors_static() {   # exit 0 when no animated Xcursor files live under $1/*/cursors/
    python3 - "$1" <<'PY'
import struct, glob, os, sys
bad = 0
for p in glob.glob(os.path.join(sys.argv[1], '*', 'cursors', '*')):
    if os.path.islink(p) or not os.path.isfile(p) or p.endswith('.animated'):
        continue
    d = open(p, 'rb').read()
    if d[:4] != b'Xcur':
        continue
    n = struct.unpack_from('<I', d, 12)[0]
    seen = {}
    for i in range(n):
        t, sub, _ = struct.unpack_from('<III', d, 16 + i * 12)
        if t == 0xfffd0002:
            seen[sub] = seen.get(sub, 0) + 1
    if seen and max(seen.values()) > 1:
        bad += 1
sys.exit(1 if bad else 0)
PY
}

if ! pkg_installed splashtop-streamer; then
    s "no Splashtop streamer — cursor-crash-guard checks skipped"
elif ! have python3; then
    s "no python3 — cursor-crash-guard checks skipped"
else
    if [ -d /usr/share/icons ]; then
        if cursors_static /usr/share/icons; then p "host cursor themes all static"
        else f "animated cursors remain under /usr/share/icons"; fi
    else
        s "no /usr/share/icons — host cursor check skipped"
    fi

    gct=/snap/gtk-common-themes/current/share/icons
    if [ -d "$gct" ]; then
        if cursors_static "$gct"; then p "snap theme cursors all static"
        else f "animated cursors remain in gtk-common-themes (snap apps will crash the streamer)"; fi
    else
        s "gtk-common-themes snap absent — snap cursor check skipped"
    fi

    if dpkg-divert --list 2>/dev/null | grep -q '\.animated$'; then
        p "cursor diversions in place (survive theme upgrades)"
    else
        f "no .animated dpkg diversions — theme upgrades will restore animated cursors"
    fi

    if [ -e /var/lib/snapd/desktop/applications/firefox_firefox.desktop ]; then
        if grep -q '^StartupNotify=false$' /usr/local/share/applications/firefox_firefox.desktop 2>/dev/null; then
            p "Firefox launch spinner disabled"
        else
            f "Firefox .desktop override missing or still StartupNotify=true"
        fi
    else
        s "no snap Firefox — launch-spinner check skipped"
    fi

    if systemctl cat SRStreamer.service >/dev/null 2>&1; then
        if [ -e /usr/local/lib/splashtop-pixbuf-shim.so ] &&
           systemctl show SRStreamer.service -p Environment 2>/dev/null | grep -q splashtop-pixbuf-shim; then
            p "pixbuf race shim wired into SRStreamer.service"
        else
            f "pixbuf race shim not wired into SRStreamer.service"
        fi
    else
        s "no SRStreamer.service — shim check skipped"
    fi
fi

# ---- scheduling hygiene (#16) ------------------------------------------------
# Terminal boxes sleep more than they run. A timed crontab entry has no
# catch-up — it silently skips every night the box is off at that minute —
# and a calendar timer only survives downtime with Persistent=true. anacron
# covers /etc/cron.daily|weekly|monthly, so run-parts jobs are fine. Only
# local units (files in /etc/systemd/system) are policed: stock distro timers
# are Ubuntu's problem, jobs added on an engagement are ours.
if systemctl list-units >/dev/null 2>&1; then
    BADT=""
    while read -r t _; do
        [ -f "/etc/systemd/system/$t" ] || continue
        [ -n "$(systemctl show "$t" -p TimersCalendar --value 2>/dev/null)" ] || continue
        [ "$(systemctl show "$t" -p Persistent --value 2>/dev/null)" = "yes" ] || BADT="$BADT $t"
    done < <(systemctl list-unit-files --type=timer --state=enabled --no-legend 2>/dev/null)
    if [ -n "$BADT" ]; then
        f "calendar timer(s) without Persistent=true:$BADT — they silently skip while the box sleeps"
    else
        p "local calendar timers all have Persistent=true (missed runs fire on wake)"
    fi
    CRONS=$({ crontab -l 2>/dev/null; sudo -n crontab -l 2>/dev/null; } \
        | grep -cE '^[[:space:]]*([0-9*]|@(hourly|daily|midnight|weekly|monthly|yearly|annually))')
    if [ "${CRONS:-0}" -gt 0 ]; then
        f "$CRONS timed crontab entr(y|ies) — plain cron has no catch-up on a box that sleeps; use a Persistent=true systemd timer"
    else
        p "no timed crontab entries (user/root)"
    fi
else
    s "systemd not reachable — scheduling hygiene checks skipped"
fi

log "extras (reported only when artifacts exist)"
if pkg_installed docker-ce; then
    if systemctl is-active docker >/dev/null 2>&1; then p "docker active"; else f "docker installed but not active"; fi
fi
if pkg_installed xrdp; then
    if systemctl is-active xrdp >/dev/null 2>&1; then p "xrdp active"; else f "xrdp installed but not active"; fi
fi
if have tailscale; then
    if systemctl is-active tailscaled >/dev/null 2>&1; then p "tailscaled active"; else f "tailscale installed but daemon inactive"; fi
fi
if pkg_installed splashtop-streamer; then
    if systemctl is-active SRStreamer.service >/dev/null 2>&1; then
        p "splashtop streamer active"
    else
        f "splashtop installed but SRStreamer.service inactive"
    fi
fi
if pkg_installed cups-browsed && systemctl is-enabled cups-browsed >/dev/null 2>&1; then
    s "cups-browsed still enabled (run --with-printing-direct to disable auto-queues)"
fi

# ---- am I up to date? -------------------------------------------------------
# Which kit is on this box: a git checkout (get.sh) or a release package (a VERSION
# file, shipped by a fleet platform). Offline by design: no network call, so it never
# hangs and never lies about what it could not reach. A platform's own release
# clocks are its verify.d checks, below.
echo
log "ai-terminal verify — versions"
KITV=$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)
if [ -f "$SCRIPT_DIR/VERSION" ]; then
    # installed from a release package (not a git checkout): whatever shipped the package
    # judges whether it is current (its verify.d checks below); here we only report it
    p "kit $(tr -d '[:space:]' <"$SCRIPT_DIR/VERSION") (installed from a release package)"
elif [ "$KITV" = unknown ]; then
    s "kit version unknown — not a git checkout, so get.sh cannot be updating it"
else
    KITD=$(git -C "$SCRIPT_DIR" log -1 --format=%cd --date=short 2>/dev/null || echo "?")
    KITT=$(git -C "$SCRIPT_DIR" log -1 --format=%ct 2>/dev/null || date +%s)
    KITAGE=$(( ( $(date +%s) - KITT ) / 86400 ))
    # a checkout more than a month stale on a box someone re-runs get.sh on means the
    # update is not happening — releases are tagged, not daily, so the bar is generous
    if [ "$KITAGE" -gt 30 ]; then
        s "kit $KITV is from $KITD (${KITAGE}d old) — update with: curl -fsSL https://get.adnet.tools | bash"
    else
        p "kit $KITV ($KITD)"
    fi
fi

# ---- layers ------------------------------------------------------------------
# A platform that ships this kit inside a larger release adds its own checks as
# verify.d/*.sh — sourced here in name order, with p/f/s and every lib helper in
# scope. The public kit ships none.
if [ -d "$SCRIPT_DIR/verify.d" ]; then
    for _vf in "$SCRIPT_DIR"/verify.d/*.sh; do
        if [ -f "$_vf" ]; then
            # shellcheck disable=SC1090
            . "$_vf"
        fi
    done
    unset _vf
fi

echo
if [ "$FAILED" = 1 ]; then
    warn "verify finished with failures"
    exit 1
fi
log "verify finished — no failures"
