# shellcheck shell=bash
# ct-desc: Force X11 (disable Wayland at GDM) — RustDesk/Splashtop remote control needs X11

# Remote-control tools (RustDesk, Splashtop) cannot capture/inject input on
# Wayland, and the Hyper-V scroll fix is an Xorg InputClass. Both reference
# machines run with WaylandEnable=false.

# DCV terminals: the fleet host owns all session config and GDM is not in
# use — DCV brings its own X server, so forcing X11 at GDM is moot. Leave it.
if is_dcv_terminal; then
    skip "DCV terminal — host owns session config (GDM not in use)"
fi

CONF=/etc/gdm3/custom.conf
[ -d /etc/gdm3 ] || skip "no GDM here (/etc/gdm3 missing)"

changed=0
if [ ! -f "$CONF" ]; then
    printf '[daemon]\nWaylandEnable=false\n' | sudo tee "$CONF" >/dev/null \
        || fail "could not create $CONF"
    changed=1
elif grep -qE '^WaylandEnable=false' "$CONF"; then
    :   # already forced
elif grep -qE '^[[:space:]]*#[[:space:]]*WaylandEnable=false' "$CONF"; then
    sudo sed -i 's/^[[:space:]]*#[[:space:]]*WaylandEnable=false/WaylandEnable=false/' "$CONF" \
        || fail "could not uncomment WaylandEnable in $CONF"
    changed=1
elif grep -qE '^WaylandEnable=' "$CONF"; then
    sudo sed -i 's/^WaylandEnable=.*/WaylandEnable=false/' "$CONF" \
        || fail "could not rewrite WaylandEnable in $CONF"
    changed=1
elif grep -q '^\[daemon\]' "$CONF"; then
    sudo sed -i '/^\[daemon\]/a WaylandEnable=false' "$CONF" \
        || fail "could not insert WaylandEnable into $CONF"
    changed=1
else
    printf '\n[daemon]\nWaylandEnable=false\n' | sudo tee -a "$CONF" >/dev/null \
        || fail "could not append to $CONF"
    changed=1
fi

if [ "$changed" = 1 ]; then
    next_step "Reboot (or log out to the GDM greeter) so the session switches from Wayland to X11 — remote control won't work until then."
fi

# Automatic login (one checkbox in the Ubuntu installer) means no password is typed at
# sign-in, so PAM can't unlock the GNOME login keyring and the first app that needs a
# stored secret pops an unlock dialog. Auto-login may be deliberate, so warn, never change.
if grep -qiE '^[[:space:]]*AutomaticLoginEnable[[:space:]]*=[[:space:]]*(true|1)[[:space:]]*$' "$CONF" 2>/dev/null; then
    next_step "Automatic login is on ($CONF), so the GNOME login keyring is not unlocked at sign-in and the first app that needs a saved secret asks for your password. To fix: Settings → System → Users → Automatic Login off. Or keep auto-login and accept that one prompt per session."
    ok "Wayland disabled at GDM (X11 forced); automatic login is on — see NEXT STEPS"
fi
ok "Wayland disabled at GDM (X11 forced)"
