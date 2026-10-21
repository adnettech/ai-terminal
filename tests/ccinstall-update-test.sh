#!/usr/bin/env bash
# Windows self-update (ccinstall.ps1 -Update): download, compare, defer while Claude Code runs,
# apply, opt-out, log. Needs pwsh (PowerShell 7) - SKIPs without it; offline, everything mocked.
set -u
cd "$(dirname "$0")/.." || exit 1
if ! command -v pwsh >/dev/null; then echo "SKIP  pwsh not installed"; exit 0; fi
R=$(mktemp -d); trap '/bin/rm -rf "$R"' EXIT
mkdir -p "$R/home/.local/bin" "$R/state"
# installed = this checkout's files, so the first run must report "current"
cp windows/ccinstall.ps1 "$R/state/"; cp assets/windows/claude-code.ico "$R/state/"
cp windows/cc-launcher.js windows/cc-statusline.js "$R/home/.local/bin/"
pwsh -NoProfile -File tests/ccinstall-update-test.ps1 -Script windows/ccinstall.ps1 -Root "$R" -Checkout "$PWD"
