# shellcheck shell=bash
# ct-desc: Claude Code (official native installer) + cc/phonecc aliases + context-fill statusline

if ! have claude; then
    log "installing Claude Code (native installer)"
    curl -fsSL https://claude.ai/install.sh | bash || fail "Claude Code installer failed"
    have claude || fail "claude not on PATH after install — open a new shell and re-run"
fi

# Statusline: a live context-fill readout in every session — the visible teaching
# tool for session hygiene (wrap up before the window fills). Never clobbers a
# statusline the user set themselves.
mkdir -p "$HOME/.local/bin"
if ! cmp -s "$SCRIPT_DIR/tools/cc-statusline.sh" "$HOME/.local/bin/cc-statusline"; then
    install -m 0755 "$SCRIPT_DIR/tools/cc-statusline.sh" "$HOME/.local/bin/cc-statusline" \
        || fail "could not install cc-statusline"
fi
python3 - <<'PY' || fail "could not wire statusLine into ~/.claude/settings.json"
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
p.parent.mkdir(exist_ok=True)
try:
    cfg = json.loads(p.read_text())
except Exception:
    cfg = {}
if "statusLine" not in cfg:  # never clobber a user's own statusline
    cfg["statusLine"] = {"type": "command",
                         "command": str(pathlib.Path.home() / ".local/bin/cc-statusline")}
    p.write_text(json.dumps(cfg, indent=2) + "\n")
PY

# `cc` = Claude Code with permission prompts off — the point of the box. A platform
# that ships this kit inside a larger release may supply a workspace launcher as
# templates/cc-launcher.sh; when it is present `cc` opens that instead.
CC_CMD='claude --dangerously-skip-permissions'
if [ -f "$SCRIPT_DIR/templates/cc-launcher.sh" ]; then
    if ! cmp -s "$SCRIPT_DIR/templates/cc-launcher.sh" "$HOME/.local/bin/cc-launcher"; then
        install -m 0755 "$SCRIPT_DIR/templates/cc-launcher.sh" "$HOME/.local/bin/cc-launcher" \
            || fail "could not install cc-launcher into ~/.local/bin"
    fi
    CC_CMD='cc-launcher'
fi
append_block "$HOME/.bashrc" "claude-terminal aliases" <<EOF
# DCV/cloud sessions skip the login-shell pass through ~/.profile, so the
# claude install dir must go on PATH here in .bashrc.
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH" ;; esac
alias cc='$CC_CMD'
alias phonecc='tmux new-session -A -s claude $CC_CMD'
EOF

# (No next_step here when logged out — the dispatcher already queues the
# login reminder, and two differently-worded copies survive the dedup.)
if claude_ready; then
    ok "$(claude --version 2>/dev/null | head -1)"
else
    ok "installed; not logged in yet"
fi
