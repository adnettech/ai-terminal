# shellcheck shell=bash
# ct-desc: Base CLI tools (git, gh, tmux, curl, jq, unzip, lynx, xvfb, openssh-server)
# Sourced by bootstrap.sh inside a subshell; ends via ok/skip/fail.

PKGS=(git gh tmux curl wget jq unzip lynx xvfb openssh-server ca-certificates gnupg)

missing=()
for p in "${PKGS[@]}"; do
    pkg_installed "$p" || missing+=("$p")
done

if [ ${#missing[@]} -gt 0 ]; then
    apt_install "${missing[@]}" || fail "apt install failed for: ${missing[*]}"
fi

[ ${#missing[@]} -gt 0 ] || ok "all present"
ok "installed: ${missing[*]}"
