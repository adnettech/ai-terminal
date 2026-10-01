# shellcheck shell=bash
# ct-desc: never offer a release upgrade; every other update applies silently — the only prompt a user sees is "restart required"

# Ubuntu 26.04.1 shipped, and from that day every 24.04 desktop pops
# "A new version of Ubuntu is available. Would you like to upgrade?" with
# "Yes, Upgrade Now" one click away (#71). A release upgrade on a terminal —
# custom Xdcv, dconf-locked GNOME, the needrestart deferral, this whole kit —
# is a rebuild, not an update. Nothing prevented it: the stock file says
# Prompt=lts. Three settings, all system-wide, so they hold for every user and
# survive re-imaging by the daily get.sh run:
#   1. release-upgrades Prompt=never — honoured by the GTK check that draws the
#      dialog, by do-release-upgrade, and by the server motd nag.
#   2. unattended-upgrades: on, and the -updates pocket added to the stock
#      security-only origins, so ordinary updates need no Software Updater
#      window. Automatic-Reboot stays false: the user reboots (a DCV session
#      must never be cut by apt; #19's needrestart deferral covers dcvserver).
#   3. update-notifier (where GNOME exists): no update notifications, no
#      auto-launched Software Updater, no "new release" check from the GUI;
#      hide-reboot-notification stays false — that prompt is the one we WANT.
# Same files whether the box is a DCV terminal, a Hyper-V VM or a laptop.

changed=0

# ---- 1. release upgrades: never ------------------------------------------
ru=/etc/update-manager/release-upgrades
if sudo test -f "$ru" && sudo grep -qE '^Prompt=never$' "$ru"; then
    :
else
    tmp="$CT_TMP/release-upgrades"
    if sudo test -f "$ru" && sudo grep -qE '^Prompt=' "$ru"; then
        sed -E 's/^Prompt=.*/Prompt=never/' "$ru" > "$tmp"   # world-readable; no sudo needed to read
    else
        printf '[DEFAULT]\n# claude-terminal (03-updates-policy): never offer a release upgrade\nPrompt=never\n' > "$tmp"
    fi
    sudo install -o root -g root -m 0644 -D "$tmp" "$ru" || fail "could not write $ru"
    changed=1
fi

# ---- 2. unattended-upgrades: on, -updates included, no automatic reboot ---
pkg_installed unattended-upgrades || apt_install unattended-upgrades
aptconf=/etc/apt/apt.conf.d/52claude-terminal-updates
tmp="$CT_TMP/52claude-terminal-updates"
cat > "$tmp" <<'APT'
// claude-terminal (03-updates-policy, #71): every ordinary update applies
// unattended; only a release upgrade is refused (release-upgrades Prompt=never)
// and only a reboot is left to the user.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-updates";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
APT
if ! sudo cmp -s "$tmp" "$aptconf" 2>/dev/null; then
    # apt-config parses the whole tree, so a syntax slip here is caught before it
    # lands (a broken apt.conf.d file breaks every apt call on the box)
    APT_CONFIG=/dev/null apt-config -c "$tmp" dump >/dev/null 2>&1 \
        || fail "generated apt config failed to parse — system untouched"
    sudo install -o root -g root -m 0644 "$tmp" "$aptconf" || fail "could not write $aptconf"
    changed=1
fi

# ---- 3. update-notifier: quiet, except the restart prompt -----------------
if pkg_installed update-notifier && have dconf; then
    profile=/etc/dconf/profile/user
    if ! sudo test -f "$profile"; then
        # stock GNOME has no profile file; this is the standard one (same as the
        # DCV host writes) — user settings first, then the system db
        printf 'user-db:user\nsystem-db:local\n' > "$CT_TMP/dconf-profile"
        sudo install -o root -g root -m 0644 -D "$CT_TMP/dconf-profile" "$profile" || fail "could not write $profile"
        changed=1
    fi
    db=/etc/dconf/db/local.d/04-claude-terminal-updates
    lock=/etc/dconf/db/local.d/locks/04-claude-terminal-updates
    cat > "$CT_TMP/dconf-updates" <<'DCONF'
# claude-terminal (03-updates-policy, #71)
[com/ubuntu/update-notifier]
no-show-notifications=true
regular-auto-launch-interval=0
hide-reboot-notification=false
# the update-manager schema's dconf path is /apps/update-manager/, not its id
[apps/update-manager]
check-dist-upgrades=false
DCONF
    printf '%s\n' /com/ubuntu/update-notifier/no-show-notifications \
                  /com/ubuntu/update-notifier/regular-auto-launch-interval \
                  /com/ubuntu/update-notifier/hide-reboot-notification \
                  /apps/update-manager/check-dist-upgrades > "$CT_TMP/dconf-updates-lock"
    if ! sudo cmp -s "$CT_TMP/dconf-updates" "$db" 2>/dev/null || ! sudo cmp -s "$CT_TMP/dconf-updates-lock" "$lock" 2>/dev/null; then
        sudo install -o root -g root -m 0644 -D "$CT_TMP/dconf-updates" "$db" || fail "could not write $db"
        sudo install -o root -g root -m 0644 -D "$CT_TMP/dconf-updates-lock" "$lock" || fail "could not write $lock"
        sudo dconf update || fail "dconf update failed"
        changed=1
    fi
fi

if [ "$changed" = 1 ]; then
    ok "release upgrades never offered; updates unattended (no auto-reboot); GUI update prompts off"
else
    ok "already configured"
fi
