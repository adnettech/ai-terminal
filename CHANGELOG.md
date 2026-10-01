# Changelog

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
