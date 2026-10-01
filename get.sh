#!/usr/bin/env bash
# ai-terminal one-liner entrypoint:
#
#   curl -fsSL https://get.adnet.tools | bash
#   curl -fsSL https://get.adnet.tools | bash -s -- --with-docker
#   (get.adnet.tools = https://raw.githubusercontent.com/adnettech/ai-terminal/main/get.sh)
#
# Clones (or updates) the kit to ~/ai-terminal, checks out the newest RELEASE TAG
# (never a half-finished main), and hands off to bootstrap.sh with your arguments.
#   AIT_REF=main      track main instead (development)
#   AIT_REF=<tag>     pin a specific release
#   AIT_DIR=<path>    install somewhere other than ~/ai-terminal
#
# A box from the old claude-terminal kit (~/claude-terminal) is moved over once: the
# old checkout is kept as ~/claude-terminal.pre-ai-terminal and ~/claude-terminal
# becomes a link to the new one, so paths baked into ~/.bashrc keep working until
# bootstrap rewrites them.
set -euo pipefail

REPO_URL="${AIT_REPO_URL:-https://github.com/adnettech/ai-terminal.git}"
DEST="${AIT_DIR:-${CLAUDE_TERMINAL_DIR:-$HOME/ai-terminal}}"
OLD="$HOME/claude-terminal"

say() { printf '[ai-terminal] %s\n' "$*"; }

# A fleet-managed terminal (a DCV platform writes /etc/asp-terminal.env) gets its kit
# from its own release channel, never from here — pulling the public kit over it would
# drop the platform's layer. Say so and stop, successfully.
if { [ -f /etc/asp-terminal.env ] || dpkg-query -W -f '${Status}' nice-dcv-server 2>/dev/null | grep -q 'install ok installed'; } \
   && [ "${AIT_ALLOW_MANAGED:-0}" != 1 ]; then
    say "this box is managed by a fleet platform — it updates itself from its release channel; nothing to do here."
    say "(AIT_ALLOW_MANAGED=1 overrides, if you really mean to install the public kit on it.)"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    say "git not found — installing it first (sudo may prompt)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git
fi

# one-time move from the old claude-terminal checkout
if [ ! -e "$DEST" ] && [ -d "$OLD/.git" ] && [ ! -L "$OLD" ]; then
    BAK="$OLD.pre-ai-terminal"
    [ -e "$BAK" ] && BAK="$OLD.pre-ai-terminal.$(date +%Y%m%d%H%M%S)"
    say "moving the old claude-terminal checkout aside → $BAK (kept; delete it once you're happy)"
    mv "$OLD" "$BAK"
    MOVED=1
fi

if [ -d "$DEST/.git" ]; then
    say "updating $DEST"
    git -C "$DEST" remote set-url origin "$REPO_URL"
    git -C "$DEST" fetch --quiet --tags --force origin
else
    say "cloning to $DEST"
    git clone --quiet "$REPO_URL" "$DEST"
fi

REF="${AIT_REF:-}"
if [ -z "$REF" ]; then
    REF="$(git -C "$DEST" tag --list 'v*' --sort=-creatordate | head -1)"
    [ -n "$REF" ] || REF=main
fi
if [ "$REF" = main ]; then
    git -C "$DEST" checkout --quiet main 2>/dev/null || git -C "$DEST" checkout --quiet -B main origin/main
    git -C "$DEST" merge --quiet --ff-only origin/main \
        || say "WARNING: local changes keep $DEST off origin/main — running the tree as it is"
    say "kit: main ($(git -C "$DEST" rev-parse --short HEAD))"
elif git -C "$DEST" -c advice.detachedHead=false checkout --quiet "$REF" 2>/dev/null; then
    say "kit: release $REF"
else
    say "WARNING: could not check out $REF (local changes in $DEST?) — running the tree as it is"
fi

# keep the old path working for anything that baked it in (.bashrc hooks, notes) — only
# on a box that had the old checkout; a fresh install gets no legacy link
if [ "${MOVED:-0}" = 1 ] && [ ! -e "$OLD" ] && [ "$DEST" != "$OLD" ]; then
    ln -s "$DEST" "$OLD"
fi

exec bash "$DEST/bootstrap.sh" "$@"
