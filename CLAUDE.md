# ai-terminal — read this first

The **public** Ubuntu 24.04 workstation kit (MIT). Everything here must be generic: useful
on anyone's box, with no client, company-internal or infrastructure specifics. Fleet and
client features live in a private platform that consumes this kit by tag.

- Guide: `docs/DEVELOPMENT.md` — module contract, the **layer contract** (`lib/common.d/`,
  `verify.d/`, optional `templates/cc-launcher.sh`, no overrides), adding a feature, releases.
- Rules: no secrets or identifiers anywhere (code, comments, fixtures, commits, issues) —
  `acme` / `example.com` placeholders; idempotent modules; degrade to SKIP, never block;
  names already written on boxes (`claude-terminal …` markers/paths) keep their spelling.
- Test: `bash tests/smoke.sh`, `bash tests/ccssh-test.sh`, `shellcheck -x $(git ls-files '*.sh')`.
- Release: tag `vYYYY.MM.DD[-n]` on main once validated; `get.sh` installs the newest tag.
