# shellcheck shell=bash
# ct-desc: what the kit installed stays current — a daily user timer updates Claude Code, the plugins, bun, uv and the kit's third-party packages (opt out: ~/.config/ai-terminal/no-component-update)

# Bootstrap installs what is missing and leaves what is there, so a kit release never
# moved a plugin or a runtime: a box ran the claude-mem, superpowers, bun and uv of the
# day it was set up, and Node/Docker/Tailscale sat outside unattended-upgrades' origins.
# tools/ait-components.sh asks each one for its newest version once a day (what it covers
# and when it waits is in its header). Unlike 04-auto-update this is not about the kit's
# own checkout, so it runs on every box — a release package and a fleet terminal included.
CONF="$HOME/.config/ai-terminal"
UNITD="$HOME/.config/systemd/user"
WANT="$UNITD/timers.target.wants/ai-terminal-components.timer"
mkdir -p "$HOME/.local/bin" "$CONF" "$UNITD/timers.target.wants"

if [ -e "$CONF/no-component-update" ]; then
    rm -f "$WANT"
    ensure_user_dbus && systemctl --user stop ai-terminal-components.timer 2>/dev/null
    skip "opted out ($CONF/no-component-update) — remove the file and re-run to turn it back on"
fi

if ! cmp -s "$SCRIPT_DIR/tools/ait-components.sh" "$HOME/.local/bin/ait-components"; then
    install -m 0755 "$SCRIPT_DIR/tools/ait-components.sh" "$HOME/.local/bin/ait-components" \
        || fail "could not install ait-components into ~/.local/bin"
fi

# compare-then-write, so an unchanged unit never triggers a reload for nothing
write_unit() { # name content
    if [ "$(cat "$UNITD/$1" 2>/dev/null)" != "$2" ]; then
        printf '%s\n' "$2" > "$UNITD/$1" || fail "could not write $UNITD/$1"
        CHANGED=1
    fi
}
CHANGED=0
write_unit ai-terminal-components.service "[Unit]
Description=Ai Terminal component updates (ait-components)
[Service]
Type=oneshot
ExecStart=%h/.local/bin/ait-components
Nice=10"
# half an hour after this user's systemd instance starts (a login, or boot where the user
# lingers), then every 24 h — not at the moment someone sits down
write_unit ai-terminal-components.timer "[Unit]
Description=Ai Terminal component updates, once a day while logged in
[Timer]
OnStartupSec=30min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
[Install]
WantedBy=timers.target"
# enabled by symlink, as in 04-auto-update: `systemctl --user enable` needs a running user
# instance, and a headless provision has none — the link starts the timer at the next login
[ "$(readlink "$WANT" 2>/dev/null)" = "../ai-terminal-components.timer" ] || ln -sfn ../ai-terminal-components.timer "$WANT"

if ensure_user_dbus && systemctl --user daemon-reload 2>/dev/null; then
    if systemctl --user is-active --quiet ai-terminal-components.timer; then
        [ "$CHANGED" = 1 ] && systemctl --user restart ai-terminal-components.timer 2>/dev/null
    else
        systemctl --user start ai-terminal-components.timer 2>/dev/null \
            || { warn "could not start ai-terminal-components.timer now (it starts at the next login)"; ok "component updates enabled (timer starts at the next login)"; }
    fi
    ok "component updates on — once a day (ait-components --check lists what is covered)"
fi
ok "component updates enabled; the timer starts at the next login (no user systemd instance in this session)"
