# Changelog

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
