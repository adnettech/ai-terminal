#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1091  # A && ok || bad is the intended reporting idiom (ok/bad never fail); the scratch kit path does not exist at lint time
# smoke.sh — no-network, no-sudo checks of the kit's plumbing (CI runs it in ubuntu:24.04):
# every script parses, --help/--list work, and the layer hooks pick up a layer's files.
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; rc=1; }

while IFS= read -r f; do bash -n "$f" || bad "syntax: $f"; done < <(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')
ok "every *.sh parses"

./bootstrap.sh --help | grep -q -- '--with-<extra>' && ok "--help" || bad "--help"
L=$(./bootstrap.sh --list)
for m in 00-base-cli 10-claude-code 27-postlogin-finish docker xrdp; do
    printf '%s' "$L" | grep -q "$m" || bad "--list misses $m"
done
ok "--list"
./bootstrap.sh --with-nonsense >/dev/null 2>&1 && bad "unknown extra accepted" || ok "unknown extra refused"

# a layer: a module, a helper and a verify check copied onto a scratch copy of the kit
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r . "$T/kit"; rm -rf "$T/kit/.git"
mkdir -p "$T/kit/lib/common.d" "$T/kit/verify.d"
printf 'layer_hello() { echo layer-helper-loaded; }\n' > "$T/kit/lib/common.d/50-test.sh"
printf '# shellcheck shell=bash\n# ct-desc: a layer module\nok "layer"\n' > "$T/kit/modules/core/08-layer-test.sh"
( . "$T/kit/lib/common.sh"; layer_hello ) | grep -q layer-helper-loaded && ok "lib/common.d is sourced" || bad "lib/common.d not sourced"
"$T/kit/bootstrap.sh" --list | grep -q '08-layer-test .*a layer module' && ok "layer module sorts into --list" || bad "layer module missing from --list"
grep -q 'verify.d' verify.sh && ok "verify.sh has the verify.d hook" || bad "verify.d hook missing"

# get.sh refuses on a managed box (simulated: AIT test hook not needed — read the guard)
grep -q '/etc/asp-terminal.env' get.sh && grep -q 'AIT_ALLOW_MANAGED' get.sh && ok "get.sh fleet guard present" || bad "get.sh fleet guard missing"

exit $rc
