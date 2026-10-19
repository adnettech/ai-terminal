# shellcheck shell=bash
# ct-desc: the kit keeps itself current — a user timer applies new releases when nobody is working here (opt out: ~/.config/ai-terminal/no-auto-update)

# Claude Code updates itself; until now the kit around it only moved when someone
# remembered the one-liner, so boxes drifted (2026-10: the client gained idle compaction
# and no plain box could follow). tools/ait-update.sh is a Windows-Update-style updater:
# a user timer ticks every ~2 h, fetches the release tags, and applies a newer one only
# when the box is free — no `claude` process, no unlocked desktop session — re-running
# bootstrap with the extras this box opted into. Fleet terminals are excluded: their
# platform ships the kit inside its own release and refuses get.sh. A release package
# (VERSION file, no .git) has no origin to follow either.
is_dcv_terminal && skip "fleet-managed terminal — its platform's updater delivers the kit"
[ -d "$SCRIPT_DIR/.git" ] || skip "not a git checkout (a release package is updated by whatever shipped it)"
have git || fail "git missing (00-base-cli installs it)"

CONF="$HOME/.config/ai-terminal"
UNITD="$HOME/.config/systemd/user"
WANT="$UNITD/timers.target.wants/ai-terminal-update.timer"
mkdir -p "$HOME/.local/bin" "$CONF" "$UNITD/timers.target.wants"

if [ -e "$CONF/no-auto-update" ]; then
    rm -f "$WANT"
    ensure_user_dbus && systemctl --user stop ai-terminal-update.timer 2>/dev/null
    skip "opted out ($CONF/no-auto-update) — remove the file and re-run to turn it back on"
fi

if ! cmp -s "$SCRIPT_DIR/tools/ait-update.sh" "$HOME/.local/bin/ait-update"; then
    install -m 0755 "$SCRIPT_DIR/tools/ait-update.sh" "$HOME/.local/bin/ait-update" \
        || fail "could not install ait-update into ~/.local/bin"
fi

# compare-then-write, so an unchanged unit never triggers a reload for nothing
write_unit() { # name content
    if [ "$(cat "$UNITD/$1" 2>/dev/null)" != "$2" ]; then
        printf '%s\n' "$2" > "$UNITD/$1" || fail "could not write $UNITD/$1"
        CHANGED=1
    fi
}
CHANGED=0
write_unit ai-terminal-update.service "[Unit]
Description=Ai Terminal kit auto-update (ait-update)
# the checkout this box was set up from — the updater follows its origin and ref file
[Service]
Type=oneshot
Environment=AIT_DIR=$SCRIPT_DIR
ExecStart=%h/.local/bin/ait-update
Nice=10"
write_unit ai-terminal-update.timer "[Unit]
Description=Ai Terminal kit auto-update, every ~2 h while logged in
[Timer]
OnBootSec=15min
OnUnitActiveSec=2h
RandomizedDelaySec=20min
Persistent=true
[Install]
WantedBy=timers.target"
# enabled by symlink, not `systemctl --user enable`: that needs a running user instance,
# and headless provisioning (SSH, first boot) has none — the link makes the timer start
# at the next login regardless
[ "$(readlink "$WANT" 2>/dev/null)" = "../ai-terminal-update.timer" ] || ln -sfn ../ai-terminal-update.timer "$WANT"

if ensure_user_dbus && systemctl --user daemon-reload 2>/dev/null; then
    if systemctl --user is-active --quiet ai-terminal-update.timer; then
        [ "$CHANGED" = 1 ] && systemctl --user restart ai-terminal-update.timer 2>/dev/null
    else
        systemctl --user start ai-terminal-update.timer 2>/dev/null \
            || { warn "could not start ai-terminal-update.timer now (it starts at the next login)"; ok "auto-update timer enabled (starts at the next login)"; }
    fi
    ok "auto-update on — every ~2 h, new releases apply when nobody is working here (ait-update --check shows the state)"
fi
ok "auto-update timer enabled; it starts at the next login (no user systemd instance in this session)"
