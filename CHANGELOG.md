# Changelog

## 2026-10-21 — Windows `cc` menu: "Pick up where you left off" finds every session

The recall row only looked in folders under `Projects`, so sessions from before the menu (run in
`Projects` itself or the home folder) never showed and the menu opened on the bare project list.
Recall now scans all of `~\.claude\projects`, takes each session's folder from the `cwd` its
transcript records (the session folder's name can't be turned back into a path), and resumes it
there. Skipped: folders that no longer exist and any under a dot-folder (claude-mem's background
sessions in `~\.claude-mem`). With nothing in the last `CC_RECALL_DAYS` (5) days it shows the
newest sessions of any age instead of hiding the row. Cards name the folder as `misc\topic`,
`Projects` or `~\somewhere`. Smoke test covers it.

## 2026-10-21 — Windows: `ccinstall` keeps itself current

A Windows box only got kit changes when someone re-ran `ccinstall`, so one installed before the
`cc` menu (2026-10-08) still dropped straight into Claude Code. `ccinstall` now registers a
per-user scheduled task, **`ai-terminal-update`** (every 2 h and at sign-in, no admin, run through
`conhost --headless` so no window flashes). It runs the local copy with `-Update`, which resolves
the installed ref (`installed.json`'s `ref`, `main` by default) to one commit, stages
`ccinstall.ps1`, `cc-launcher.js`, `cc-statusline.js` and the icon, and compares them with what
is installed. If anything changed and this user has no Claude Code (or `cc` menu) running, it runs
the **new** script with `-Refresh`: kit files, `cc.cmd`, terminal profile, shortcuts, task and
marker, with no winget, sign-in or plugins. Otherwise it defers to the next run. The Claude desktop
app's `claude.exe` doesn't count as busy. A refresh leaves out a desktop shortcut that was
deleted. Outcome in `%LOCALAPPDATA%\ai-terminal\update-last.json`, log in `update.log`; `-Update -Now`
applies while busy; `-NoAutoUpdate` opts out. `-Verify` now also fails a terminal profile that
skips the menu (an old install), and reports the shortcuts, the task and the last update.
`-Uninstall` removes the task. The shortcuts open Windows Terminal with `-w new`, so every click is a separate window (several Claude Code sessions side by side) even when WT is set to reuse its window. `tests/ccinstall-update-test.sh` (pwsh, GitHub and processes
mocked) runs in CI.

## 2026-10-19 — the kit updates itself (04-auto-update, `ait-update`)

Claude Code updates itself; the kit around it only moved when someone remembered the
one-liner, so plain boxes drifted (2026-10: the client gained idle compaction and no public-kit
box could follow without a hand). New core module **04-auto-update** installs
`tools/ait-update.sh` as `~/.local/bin/ait-update` and a user timer
(`ai-terminal-update.timer`, every ~2 h, persistent) that fetches the release tags and applies
a newer one Windows-Update-style — only when the box is free: no `claude` process for the user,
no active unlocked desktop session, no local changes in the checkout, and passwordless sudo in
place (else it defers and the timer retries). It re-runs `bootstrap.sh` with the extras the box
opted into: `bootstrap.sh` now records the union of every `--with-<extra>` in
`~/.config/ai-terminal/extras`. `get.sh` records `AIT_REF` in `~/.config/ai-terminal/ref`
(absent = newest tag, `main` = track main, a tag = stay pinned) and the updater follows it.
Outcome in `~/.local/state/ai-terminal/update-last`, log beside it; a failed bootstrap is
retried on the next tick; `ait-update --check` / `--now`; opt out with
`~/.config/ai-terminal/no-auto-update`. The timer is enabled by symlink so headless provisioning
(no user systemd instance) still leaves it armed for the next login. Fleet terminals skip it:
their platform ships the kit inside its release. `verify.sh` reports the timer and the last
outcome (a deferral past ~3 days is a FAIL with the `--now` hint). `tests/auto-update-test.sh`
(fake sudo/pgrep/loginctl, local git origin, 12 cases) runs in CI.
## 2026-10-08 — Windows: the `cc` workspace menu and the Claude Code icon

`cc` on Windows opens a workspace menu (`windows/cc-launcher.js`, Node), the generic half of
the fleet launcher: folders under `Projects`, `os-changes`, `misc`, "Pick up where you left off"
session cards with context fill, continue / new / hand-off / wrap-up, new project, a first-run
tour and `?` help. `cc <folder>` skips it. The statusline caches each model's context window
again so the cards can show context fill. Shortcuts and the Windows Terminal profile carry
the Claude Code mascot (`assets/windows/claude-code.ico`, rendered from Claude Code's own
startup banner by `make-claude-code-ico.py`) and run the menu straight from PowerShell, so a
Ctrl+C in a session never leaves cmd asking "Terminate batch job?". Re-run `ccinstall` to
pick it up.

## 2026-10-08 — Windows: permanent install (`ccinstall`)

New `windows/ccinstall.ps1`, the deliberate counterpart of `cctemp`. It sets up Claude Code on
Windows the way the Ubuntu core sets up a workstation: Git/gh/jq/Node/Bun/uv via winget, the
native installer, `cc` = `claude --dangerously-skip-permissions` (a `cc.cmd` shim, no profile or
execution-policy change), the context-fill statusline ported to Node (`windows/cc-statusline.js`),
the claude-mem and superpowers plugins (the first `cc` after sign-in finishes them, like
`27-postlogin-finish`), `%USERPROFILE%\Projects`, a Windows Terminal profile fragment and
shortcuts. Idempotent, with `-Verify` and `-Uninstall` modes. It refuses to run as SYSTEM, and it
converts a `cctemp` box by removing its 30-day dead-man task so that task can never purge a
permanent install. `tests/smoke.sh` keeps the script ASCII-only (Windows PowerShell 5.1 reads a
BOM-less `-File` script as ANSI) and runs the statusline port.

## 2026-10-01 — `ccssh` stays connected for the whole session (v2026.10.01-6)

Keepalives (`ServerAliveInterval` 15 s × 4) notice a dead link; a keeper process re-opens the
ControlMaster when it drops — network blip, server reboot, idle timeout — feeding the password
through the same one-shot FIFO from its own memory (no file, no environment, no argv), backing
off 5 → 60 s while the server is unreachable, and giving up only if the password is refused.
`rssh` waits (up to `CCSSH_RSSH_WAIT`, default 120 s) and says so, instead of failing. The
keeper is killed first on exit. `tests/ccssh-test.sh` adds a full session whose connection
drops between two commands.

## 2026-10-01 — `ccssh`: Claude Code on a remote server, password never stored (v2026.10.01-5)

New `tools/ccssh.sh`, installed as `~/.local/bin/ccssh` by `10-claude-code` (verify checks it).
Paste host/user/password once; Claude Code gets the server through `rssh`. The password reaches
ssh's ask-pass helper through a one-shot FIFO — the earlier in-house version exported it to the
helper's environment, and the backgrounded ControlMaster (`ssh -f`) kept it in
`/proc/<pid>/environ` for the whole session, readable by anything running as the user.
`tests/ccssh-test.sh` (fake ssh, no network) proves delivery, the clean master environment,
retry and give-up; CI runs it.

## 2026-10-01 — verify: Switcher's enabled state read from settings, not the live shell (v2026.10.01-4)

`gnome-extensions list --enabled` asks the running shell; with nobody logged in (a headless or
SSM run) it returned nothing and FAILed a correctly-enabled box. `verify.sh` now reads
`org.gnome.shell enabled-extensions` (a settings read, no bus) and asks the shell for the
runtime state only when one is running. Reported by both the on-prem fleet and an AWS terminal.

## 2026-10-01 — apt waits for the package lock (v2026.10.01-3)

`apt_update_once` / `apt_install` pass `-o DPkg::Lock::Timeout=600`. A box booting after weeks
off runs unattended-upgrades first; a module installing a package then hit the dpkg lock and
FAILED instead of waiting (seen on a fleet terminal waking after a month).

## 2026-10-01 — Switcher's re-patch watcher is enabled on headless provisions (v2026.10.01-2)

`46-switcher` enabled `switcher-patches.path` with `systemctl --user enable --now … || true`.
During a headless provision the user has no systemd manager yet, so the enable failed
silently and the watcher never existed — the first extension update then reverted the three
patches for good. The module now writes the `default.target.wants` link itself (what `enable`
writes) and only *starts* the unit when a user manager is running; `verify.sh` accepts the
link as enabled when the unit isn't running in the current shell. Reported from the adNET
on-prem fleet (present on existing desktops too).

## 2026-10-01 — Ai Terminal: the public kit, on its own (v2026.10.01)

`claude-terminal` split in two. This repo is the public half — the Ubuntu 24.04
workstation kit — under adNET's GitHub organisation; the fleet platform that ran in
`aws/`, the engagement methodology in `templates/`, the medical profile and the
DCV-builder modules moved to a private repo that consumes this kit by tag.

- **Rebrand:** Ai Terminal; one-liner `curl -fsSL https://get.adnet.tools | bash`;
  checkout `~/ai-terminal` (an old `~/claude-terminal` checkout is set aside as
  `~/claude-terminal.pre-ai-terminal` and the old path becomes a link).
- **Releases, not main:** `get.sh` installs the newest tag (`AIT_REF=main|<tag>`
  overrides) and refuses on a fleet-managed box, whose kit arrives with its platform's
  release.
- **Layers:** `lib/common.d/*.sh` and `verify.d/*.sh` hooks, an optional
  `templates/cc-launcher.sh`, and a no-overrides rule — how a platform builds on the kit
  without forking it (docs/DEVELOPMENT.md).
- **Moved out (platform):** modules 06-cloudflared, 07-warp, 08-medical-bedrock,
  09-managed-settings, 11-git-identity, 12-ssh-docker01, 13-broker-tools,
  21-medical-claude-mem, 43-medical-cues; doctl (was in 00-base-cli); the `asp-*` tools;
  `--medical`; `cc-launcher`. Plain `cc` is Claude Code with permission prompts off.
- **Kept on the kit:** `cc-statusline` moved to `tools/`.
- pii-guard only ever fails (no history rewrite); CI runs shellcheck + a smoke test.

History before this split lives with the platform repo (2026-07-21 → 2026-09-30).
