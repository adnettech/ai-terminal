# Development Guide

For anyone (human or agent) changing this repo. The README covers *using* the
kit; this covers *maintaining* it.

## What this repo is

The public half of adNET's Ai Terminal: everything needed to turn a stock
Ubuntu 24.04 Desktop into an AI coding workstation, and nothing that belongs to
a particular fleet, client or engagement. It began as the `claude-terminal`
kit (2026-07), distilled from a file-by-file audit of two long-lived machines
(`audit/system-audit.sh` produced the core/extras split). In 2026-10 the fleet
platform (cloud/DCV terminals, the portal, the engagement methodology, the
medical profile) moved to a private repo that **consumes this kit by release
tag** and layers its own files on top (see *Layers*).

## Repo map

| Path | Role |
|---|---|
| `get.sh` | curl-able entrypoint (`get.adnet.tools`): clone/update `~/ai-terminal`, check out the newest tag, exec bootstrap |
| `bootstrap.sh` | arg parsing, module dispatch, summary + NEXT STEPS output |
| `lib/common.sh` | helpers every module can use (contract below); sources `lib/common.d/*.sh` if a layer supplies any |
| `modules/core/NN-*.sh` | always run, lexical order |
| `modules/extra/<flag>.sh` | run when `--with-<flag>` given |
| `assets/` | data files modules load |
| `tools/` | standalone helpers installed to `~/.local/bin` by modules (`cct-finish`, `cc-statusline`, `render-page`, …) |
| `verify.sh` | read-only PASS/FAIL/SKIP state check; sources `verify.d/*.sh` if a layer supplies any |
| `windows/` | runs on a Windows host, not on the box: Hyper-V VM builder + `cctemp` |
| `audit/system-audit.sh` | full machine snapshot for diffing two boxes |

## Module contract

Modules are **sourced inside a subshell** by `bootstrap.sh`. Rules:

1. First lines: `# shellcheck shell=bash` and `# ct-desc: <one-liner>`
   (the ct-desc line is what `--list` prints). An extra may also carry
   `# ct-suggest: <command>|<hint>`: bootstrap prints `<hint>` under NEXT STEPS
   when that extra didn't run *and* `<command>` isn't on PATH. That's how an
   opt-in product advertises itself without the dispatcher knowing it exists.
2. Terminate through exactly one of `ok "msg"` / `skip "why"` / `fail "why"`.
   These `exit` the subshell — code after them does not run. A module that
   falls off the end counts as OK.
3. Queue user-visible follow-ups with `next_step "…"` (deduped, printed once
   at the end of the run). Don't print the same instruction the dispatcher
   already adds (e.g. the claude-login reminder).
4. Available helpers: `have`, `pkg_installed`, `apt_install` (auto
   `apt-get update` once per run), `append_block FILE MARKER <<'EOF'`
   (idempotent marker-delimited config blocks; `sudo_append_block` is the
   same for root-owned files), `claude_ready` (installed *and* logged in —
   or pinned to Bedrock: `claude_bedrock_ready`), `is_dcv_terminal`, `log`/`warn`. After adding an apt repo,
   `rm -f "$CT_TMP/apt-updated"` to force a re-update.
   **gsettings/dconf writes go through `gui_conf`** (gate with
   `gui_conf_ready || skip`): it uses the live user bus when one exists and
   falls back to a private one-shot bus (`dbus-run-session`) so headless
   provisioning works — a busless `gsettings set` otherwise exits 0 while
   writing nothing. Reads (`gsettings get`, `dconf dump`) hit the database
   file directly and need no bus or wrapper. (`ensure_user_dbus` remains the
   lower-level SSH-session helper `gui_conf` builds on.)
   **Host gates:** `is_dcv_terminal` is true on DCV/cloud fleet boxes
   (a platform's `/etc/asp-terminal.env` or the DCV server package) — gate anything
   GDM/lock/login-shaped behind it; the host owns session config there.
   Hyper-V stays `systemd-detect-virt` = `microsoft`, Splashtop stays
   `pkg_installed splashtop-streamer`.
5. **Idempotency is non-negotiable.** Re-running bootstrap is the upgrade
   path. Guard every mutation (`grep -q` before sed-insert, `pkg_installed`
   before apt, compare-before-set for gsettings).
6. Pick the right convergence mode:
   - **Converge** (enforce on every run): system packages, services,
     gsettings the machines should agree on (e.g. dock favorites).
   - **Seed** (apply once, never overwrite): anything a user will personalize
     later (e.g. `42-terminal-prefs` loads its dconf only when the target
     tree is empty).
7. Anything needing interaction (logins, `tailscale up`, printer addresses)
   is a `next_step`, never a prompt. **One exception:** an extra the user
   explicitly asked for by its own `--with-` flag may prompt for input that is
   inherently per-machine and secret — a Splashtop deployment code, say. Such a
   module must read from `/dev/tty` and must `skip` when it can't, so unattended
   runs never block. Two traps: under `curl | bash` stdin is the *pipe*, so a
   bare `read` silently consumes the script's own next line instead of asking;
   and `[ -t 0 ]` is false there even in a real console, so gate on
   `( : </dev/tty ) 2>/dev/null` instead. Core modules get no exception.

Numbering: core runs in lexical order — pick a number that respects
dependencies (base-cli → runtimes → claude stack → desktop). Extras are named
exactly like their flag.

**`# ct-after-extras`** (core modules only) defers a module to the very end of
the run, after the extras pass, instead of running it in lexical position. Use
it when a core module acts on something an *extra* installs — the only case
today is `41-splashtop-cursorfix`, which is gated on `splashtop-streamer` and
would otherwise skip on the very run that `--with-splashtop` installed it, so
the fix would land only on the next bootstrap. Note the consequence: such a
module's number no longer reflects when it runs, so keep the list short and say
why in the module header.

## Layers (how a platform builds on the kit without forking it)

A platform ships the kit inside its own release: at release time it takes this
repo **at a tag** and copies its own tree on top. The contract that makes that
safe:

- **No overrides.** A layer file that would land on an existing kit path is a
  build error. Layers *add* files; they never replace kit files.
- **Modules** a layer adds are plain `modules/core/NN-*.sh` / `modules/extra/*.sh`
  files with the same contract — so they sort into the kit's numeric order (a
  layer module that must run before `10-claude-code` is simply `08-…`).
- **Helpers**: `lib/common.d/*.sh`, sourced at the end of `lib/common.sh`.
- **Checks**: `verify.d/*.sh`, sourced near the end of `verify.sh` with `p`/`f`/`s`
  and every helper in scope.
- **Launcher**: if `templates/cc-launcher.sh` exists, `10-claude-code` installs it
  and points `cc` at it; otherwise `cc` is plain Claude Code.
- **VERSION**: a release package carries a `VERSION` file; `verify.sh` reports it
  instead of git state.
- Fleet boxes never run `get.sh` (it refuses on a managed box): their kit only
  ever arrives inside the platform's release.

Anything a layer needs that this contract doesn't offer is a change **here**,
generic and behind a hook — never a patched copy downstream.

## Adding a feature — checklist

1. Write the module (contract above). Core if every workstation wants it;
   extra if it's situational; `--all-extras` excludes anything consequential
   enough to require explicit intent (see `SAFE_EXTRAS` in `bootstrap.sh`).
2. Add a check to `verify.sh` (PASS/FAIL for core state, SKIP when the feature
   legitimately isn't there yet).
3. Add the README table row and a `CHANGELOG.md` entry.
4. Lint: `bash -n` every touched script, then
   `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x $(git ls-files '*.sh')`
   — keep it finding-free. CI runs the same plus a smoke test in `ubuntu:24.04`.
5. Validate on a real box; `./verify.sh` is the scorecard.

## Releases

`main` is development; boxes install **tags**. Tag `vYYYY.MM.DD` (`-1`, `-2` for
more than one a day) once a change is validated, and push the tag. `get.sh`
installs the newest tag; the fleet platform pins a tag in its `kit.lock`.

## Python tool venvs: `uv venv`, not `python3-venv`

A tool that needs its own Python environment builds it with
`uv venv ~/.venvs/<tool>` + `uv pip install --python …` (uv ships in the core,
module 30). `python3-venv` is **not** installed — `python3 -m venv` failing on a
box is expected. Model: `tools/render-page.py`, which builds its venv on first
run and re-execs itself inside it.

## Hard rules

- **No secrets or identifiers, ever** — no hostnames, IPs, client names or codes,
  emails, account IDs, keys — in code, comments, test fixtures, commit messages,
  branch names or issues. Use `acme` / `example.com` placeholders. CI's pii-guard
  fails on a denylist hit; it never rewrites history.
- Bootstrap must keep working via `curl | bash` on a stock install — no new
  runtime assumptions (bash + apt + sudo only until a module installs more).
- Modules degrade to SKIP with a manual fallback rather than block.
- Names already written on boxes (`append_block` markers such as
  `claude-terminal aliases`, `/etc/apt/apt.conf.d/52claude-terminal-updates`,
  `~/.local/share/claude-terminal/`) keep their historical spelling: renaming
  one would leave a duplicate on every existing box.

## Roadmap

- **More agents** as opt-in modules (Codex, Gemini, xAI CLIs): an agent module
  installs the CLI, says how to sign in (NEXT STEPS), and adds its own alias. A
  platform can refuse one on a restricted box from its layer.
- **RustDesk extra** — `modules/extra/rustdesk.sh` with its own `ct-suggest:`
  line, following `splashtop.sh`.
- MFA extra (`libpam-google-authenticator` + `oathtool`).
