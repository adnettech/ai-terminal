#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && ok || bad is the reporting idiom here; ok/bad never fail
# components-test.sh — tools/ait-components.sh against fake claude/bun/uv/dpkg-query/
# apt-get/sudo/docker/pgrep/loginctl (no network, no sudo, no systemd): every component
# is asked for its newest version, a failing one does not stop the rest, system packages
# wait for a free box and for Docker's containers, and --check changes nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); CMP="$HERE/../tools/ait-components.sh"
command -v jq >/dev/null || { echo "SKIP jq not installed"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rc=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; rc=1; }

# ---- fakes: each component's version is a file in $FAKE; "<name>.new" is what an update finds
mkdir -p "$T/bin" "$T/fake" "$T/home/.bun/bin" "$T/home/.local/bin"
export FAKE="$T/fake" HOME="$T/home"
cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/claude-calls"
bump() { [ -e "$FAKE/$1.new" ] && mv -f "$FAKE/$1.new" "$FAKE/$1"; }
case "$*" in
  --version) echo "$(cat "$FAKE/claude") (Claude Code)" ;;
  update)    [ -e "$FAKE/claude-update-fails" ] && exit 1; bump claude; exit 0 ;;
  "plugin list --json")
    printf '[{"id":"claude-mem@thedotmack","version":"%s","scope":"user"},{"id":"superpowers@superpowers-marketplace","version":"%s","scope":"user"},{"id":"extra@somewhere","version":"%s","scope":"user"},{"id":"team@somewhere","version":"1.0.0","scope":"project"},{"id":"cc-plugin-x@builtin","version":"unknown","scope":"user"}]\n' \
      "$(cat "$FAKE/claude-mem")" "$(cat "$FAKE/superpowers")" "$(cat "$FAKE/extra")" ;;
  "plugin marketplace update") [ -e "$FAKE/offline" ] && exit 1; exit 0 ;;
  "plugin update "*)
    n=${3%%@*}; old=$(cat "$FAKE/$n" 2>/dev/null)
    [ -e "$FAKE/$n-update-fails" ] && { echo '{"outcome":"error"}'; exit 1; }
    bump "$n"; printf '{"outcome":"ok","oldVersion":"%s","newVersion":"%s"}\n' "$old" "$(cat "$FAKE/$n")" ;;
esac
SH
for t in bun uv; do
  cat > "$T/home/$([ $t = bun ] && echo .bun/bin || echo .local/bin)/$t" <<SH
#!/usr/bin/env bash
case "\$*" in
  --version) [ $t = uv ] && echo "uv \$(cat "\$FAKE/$t")" || cat "\$FAKE/$t" ;;
  upgrade|"self update") [ -e "\$FAKE/$t.new" ] && mv -f "\$FAKE/$t.new" "\$FAKE/$t"; exit 0 ;;
esac
SH
done
cat > "$T/bin/dpkg-query" <<'SH'
#!/usr/bin/env bash
p=${*: -1}; [ -e "$FAKE/pkg-$p" ] && printf 'install ok installed\t%s' "$(cat "$FAKE/pkg-$p")"
SH
cat > "$T/bin/sudo" <<'SH'
#!/usr/bin/env bash
[ -e "$FAKE/no-sudo" ] && exit 1
[ "$1" = -n ] && shift; exec "$@"
SH
cat > "$T/bin/apt-get" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/apt-calls"
case " $* " in *" install "*) for a in "$@"; do [ -e "$FAKE/pkg-$a.new" ] && mv -f "$FAKE/pkg-$a.new" "$FAKE/pkg-$a"; done ;; esac
exit 0
SH
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
[ "$1" = ps ] && [ -e "$FAKE/container-running" ] && echo abc123
exit 0
SH
cat > "$T/bin/pgrep" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -x claude "*) [ -e "$FAKE/claude-running" ] ;; *) false ;; esac
SH
cat > "$T/bin/loginctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$T/bin/"* "$T/home/.bun/bin/bun" "$T/home/.local/bin/uv"
# the fakes come first, the tool's own PATH additions (~/.local/bin, ~/.bun/bin) hold bun/uv
export PATH="$T/bin:$PATH"
CONF="$HOME/.config/ai-terminal"; STATE="$HOME/.local/state/ai-terminal"; mkdir -p "$CONF"
last() { sed -n "s/^$1=//p" "$STATE/components-last" 2>/dev/null; }
run()  { bash "$CMP" "$@" >"$T/out" 2>&1; echo $? > "$T/rc"; }
seed() {
    rm -rf "$FAKE"; mkdir -p "$FAKE"; rm -f "$STATE/components-last" "$CONF/component-packages" "$CONF/no-component-update"
    echo 2.1.0 > "$FAKE/claude"; echo 16.0.0 > "$FAKE/claude-mem"; echo 7.0.0 > "$FAKE/superpowers"; echo 0.1.0 > "$FAKE/extra"
    echo 1.4.0 > "$FAKE/bun"; echo 0.13.0 > "$FAKE/uv"
    echo 20.1.0 > "$FAKE/pkg-nodejs"; echo 27.0 > "$FAKE/pkg-docker-ce"
}

echo "1. --check lists what is managed and changes nothing"
seed; echo 16.1.0 > "$FAKE/claude-mem.new"; run --check
for w in 'claude-code +installed +2.1.0' 'claude-mem +installed +16.0.0' 'superpowers +installed +7.0.0' 'extra +installed' 'bun +installed +1.4.0' 'uv +installed +0.13.0' 'nodejs +installed +20.1.0' 'docker-ce +installed +27.0'; do
    grep -qE "$w" "$T/out" || bad "--check lacks /$w/: $(cat "$T/out")"
done
grep -qE 'team|builtin|tailscale' "$T/out" && bad "--check lists a project plugin, a built-in or a package that is not installed" || ok "--check lists the user's plugins and the installed packages only"
[ "$(cat "$FAKE/claude-mem")" = 16.0.0 ] && [ ! -e "$STATE/components-last" ] && ! grep -q 'update' "$FAKE/claude-calls" \
    && ok "--check updated nothing and stamped nothing" || bad "--check changed something"

echo "2. newer versions everywhere → each is updated, the rest report current"
seed; echo 2.2.0 > "$FAKE/claude.new"; echo 16.1.0 > "$FAKE/claude-mem.new"; echo 0.2.0 > "$FAKE/extra.new"
echo 1.5.0 > "$FAKE/bun.new"; echo 20.2.0 > "$FAKE/pkg-nodejs.new"; run
[ "$(cat "$T/rc")" = 0 ] && [ "$(last result)" = ok ] && ok "exit 0, result ok" || bad "rc=$(cat "$T/rc") result=$(last result): $(cat "$T/out")"
[ "$(last updated)" = "claude-code claude-mem extra bun nodejs" ] && ok "updated: $(last updated)" || bad "updated=$(last updated)"
grep -qE 'claude-mem +updated +16.0.0 → 16.1.0' "$T/out" && grep -qE 'superpowers +current +7.0.0' "$T/out" && grep -qE 'uv +current +0.13.0' "$T/out" \
    && ok "versions reported (16.0.0 → 16.1.0; superpowers and uv current)" || bad "report: $(cat "$T/out")"
grep -q 'plugin marketplace update' "$FAKE/claude-calls" && ! grep -q 'team@\|builtin' "$FAKE/claude-calls" \
    && ok "marketplaces refreshed first; project-scope and built-in plugins left alone" || bad "claude calls: $(cat "$FAKE/claude-calls")"
grep -q -- '--only-upgrade.* nodejs docker-ce' "$FAKE/apt-calls" && ok "apt upgraded only the named packages" || bad "apt calls: $(cat "$FAKE/apt-calls")"

echo "3. one component failing does not stop the others"
seed; touch "$FAKE/claude-mem-update-fails"; echo 7.1.0 > "$FAKE/superpowers.new"; echo 0.14.0 > "$FAKE/uv.new"; run
[ "$(cat "$T/rc")" = 1 ] && [ "$(last result)" = failed ] && [ "$(last failed)" = claude-mem ] && ok "exit 1, failed=claude-mem" || bad "rc=$(cat "$T/rc") failed=$(last failed)"
[ "$(last updated)" = "superpowers uv" ] && ok "superpowers and uv still updated" || bad "updated=$(last updated)"

echo "4. claude running → system packages wait, everything per-user still updates"
seed; touch "$FAKE/claude-running"; echo 16.1.0 > "$FAKE/claude-mem.new"; echo 20.2.0 > "$FAKE/pkg-nodejs.new"; run
[ "$(last updated)" = claude-mem ] && [ "$(last waiting)" = packages ] && [ "$(cat "$FAKE/pkg-nodejs")" = 20.1.0 ] && [ ! -e "$FAKE/apt-calls" ] \
    && ok "plugin updated; packages waiting, apt never called" || bad "updated=$(last updated) waiting=$(last waiting): $(cat "$T/out")"
run --now
[ "$(cat "$FAKE/pkg-nodejs")" = 20.2.0 ] && ok "--now updates packages with claude running" || bad "--now left nodejs at $(cat "$FAKE/pkg-nodejs")"

echo "5. a container is running → Docker waits, the other packages go ahead"
seed; touch "$FAKE/container-running"; echo 20.2.0 > "$FAKE/pkg-nodejs.new"; echo 27.1 > "$FAKE/pkg-docker-ce.new"; run
[ "$(cat "$FAKE/pkg-nodejs")" = 20.2.0 ] && [ "$(cat "$FAKE/pkg-docker-ce")" = 27.0 ] && [ "$(last waiting)" = docker ] \
    && ok "nodejs updated, docker-ce held" || bad "nodejs=$(cat "$FAKE/pkg-nodejs") docker=$(cat "$FAKE/pkg-docker-ce") waiting=$(last waiting)"

echo "6. sudo wants a password → packages skipped, never prompted, run still ok"
seed; touch "$FAKE/no-sudo"; run
[ "$(last result)" = ok ] && grep -qE 'packages +skipped +sudo needs a password' "$T/out" && ok "skipped with the reason" || bad "$(cat "$T/out")"

echo "7. component-packages adds a layer's or a person's own packages"
seed; echo 2026.1 > "$FAKE/pkg-acme-cli"; echo 2026.2 > "$FAKE/pkg-acme-cli.new"; printf '# ours\nacme-cli\nnot-installed-here\n' > "$CONF/component-packages"; run
[ "$(cat "$FAKE/pkg-acme-cli")" = 2026.2 ] && ! grep -q 'not-installed-here' "$FAKE/apt-calls" && ok "acme-cli updated; a package that is not installed is not asked for" || bad "apt calls: $(cat "$FAKE/apt-calls")"

echo "8. DISABLE_AUTOUPDATER in settings pins Claude Code; plugins still update"
seed; mkdir -p "$HOME/.claude"; echo '{"env":{"DISABLE_AUTOUPDATER":"1"}}' > "$HOME/.claude/settings.json"
echo 2.2.0 > "$FAKE/claude.new"; echo 7.1.0 > "$FAKE/superpowers.new"; run
[ "$(cat "$FAKE/claude")" = 2.1.0 ] && [ "$(last updated)" = superpowers ] && ok "claude left at 2.1.0, superpowers updated" || bad "claude=$(cat "$FAKE/claude") updated=$(last updated)"
rm -f "$HOME/.claude/settings.json"

echo "9. offline: marketplaces cannot refresh → reported, the run carries on"
seed; touch "$FAKE/offline"; run
[ "$(last result)" = failed ] && [ "$(last failed)" = marketplaces ] && grep -qE 'bun +current' "$T/out" && ok "failed=marketplaces, later steps ran" || bad "$(cat "$T/out")"

echo "10. opt-out file → nothing runs; --help works"
seed; touch "$CONF/no-component-update"; echo 16.1.0 > "$FAKE/claude-mem.new"; run
[ "$(last result)" = skipped ] && [ "$(cat "$FAKE/claude-mem")" = 16.0.0 ] && ok "opted out" || bad "result=$(last result)"
bash "$CMP" --help | grep -q 'ait-components --check' && ok "--help" || bad "--help"
bash "$CMP" --nonsense >/dev/null 2>&1; [ $? = 2 ] && ok "unknown option refused" || bad "unknown option accepted"

echo
[ "$rc" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$rc"
