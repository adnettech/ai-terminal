# Ai Terminal

Turn a stock **Ubuntu 24.04 LTS Desktop** install into an **AI coding
workstation** — a machine whose main job is running AI coding agents
comfortably. Today that means [Claude Code](https://claude.com/claude-code)
with persistent memory, agent skills, a context-fill statusline and the
quality-of-life fixes that make a (typically Hyper-V) VM pleasant to live in.
More agents (Codex, Gemini, xAI) are on the roadmap as opt-in modules.

Idempotent: re-running is always safe and is also how you pick up updates.
Maintained by [adNET](https://adnet.us); MIT-licensed, use it or fork it.

## Quick start

On a fresh Ubuntu 24.04 Desktop box (regular user with sudo) — if you still
need to *build* that box on a Hyper-V host, see
[Provisioning the VM](#provisioning-the-vm-hyper-v-hosts) first.

**Install `curl` first** — a fresh Ubuntu 24.04 Desktop doesn't have it, and
it's the one thing the bootstrap can't install for you:

```bash
sudo apt-get update && sudo apt-get upgrade
sudo apt install -y curl
```

Then:

```bash
curl -fsSL https://get.adnet.tools | bash
```

`get.adnet.tools` is a redirect to
`https://raw.githubusercontent.com/adnettech/ai-terminal/main/get.sh` — check
it any time with `curl -sI https://get.adnet.tools`. It clones the kit to
`~/ai-terminal`, checks out the **newest release tag** (never a half-finished
`main`) and runs `bootstrap.sh`. Prefer to look first?

```bash
git clone https://github.com/adnettech/ai-terminal ~/ai-terminal
cd ~/ai-terminal && ./bootstrap.sh
```

Then:

1. Run `claude` once and log in.
2. Open a new shell — the first shell after login runs `cct-finish`, which
   installs the two plugin modules (claude-mem, superpowers).
3. `./verify.sh` to confirm everything, and read the printed **NEXT STEPS**.

Extras are flags: `curl -fsSL https://get.adnet.tools | bash -s -- --with-docker --with-xrdp`
(see `./bootstrap.sh --list` for everything). Updating = running the one-liner
again. `AIT_REF=main` tracks development instead of releases; `AIT_REF=<tag>`
pins one.

**Coming from `claude-terminal`?** Run the one-liner. Your old
`~/claude-terminal` checkout is kept as `~/claude-terminal.pre-ai-terminal`
and `~/claude-terminal` becomes a link to `~/ai-terminal`.

## Provisioning the VM (Hyper-V hosts)

From an **elevated PowerShell on the Hyper-V host** (not in the guest):

```powershell
irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/get.ps1 | iex
```

That fetches `windows/New-UbuntuHyperVVM.ps1` and runs it. The script stages
the newest Ubuntu 24.04 Desktop ISO in `C:\VMs\ISOs` — downloading only when a
newer point release has shipped, verified against Canonical's `SHA256SUMS` —
then prompts for name, memory, CPUs and disk, lets you pick the ISO and virtual
switch, and builds a Generation 2 VM with a dynamic VHDX and static memory.
Boot it, install Ubuntu, then run the quick-start one-liner inside the guest.

To pass the script's switches (`-VMRoot`, `-SkipIsoUpdate`, `-SkipHashCheck`),
bind them to the launcher instead of piping — `iex` cannot forward arguments:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/get.ps1))) -SkipIsoUpdate
```

The launcher downloads to `$env:TEMP` and invokes the script as a file, which
keeps its `#Requires -RunAsAdministrator` guard working. It enables TLS 1.2 and
sets a **process-scoped** execution-policy bypass — nothing persists.

## Windows: permanent install (`ccinstall`)

For a Windows PC that should *keep* Claude Code, set up the way the Ubuntu
kit sets up a workstation. From a normal PowerShell, **signed in as the person
who will use it** (not an RMM/SYSTEM session, which it refuses):

```powershell
irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/ccinstall.ps1 | iex
```

[`windows/ccinstall.ps1`](windows/ccinstall.ps1) is user-profile-scoped and
idempotent. Re-running it is how you pick up kit updates, and Claude Code
updates itself. winget may raise a UAC prompt for Git and Node. The script
offers to open Claude Code for sign-in. If you skip that, the first `cc` after
you sign in installs the plugins.

| Ubuntu core | On Windows |
|---|---|
| 00-base-cli, 05-node, 15-bun, 30-uv | Git for Windows (required: Claude Code's Bash tool uses it), gh, jq, Node.js LTS, Bun, uv, all via winget (official installers for Bun/uv when winget is missing) |
| 10-claude-code | official native installer; `%USERPROFILE%\.local\bin` on the user PATH; **`cc`** opens the workspace menu (below), then `claude --dangerously-skip-permissions` in the chosen folder. It's a `cc.cmd` shim, so it works in PowerShell, cmd and Windows Terminal without touching execution policy |
| context-fill statusline | `cc-statusline.js` (Node port: PowerShell 5.1 is too slow to start on every redraw, and its output isn't UTF-8), wired into `~\.claude\settings.json` unless you already have a statusLine |
| 20-claude-mem, 25-superpowers | same plugins, same marketplaces |
| 27-postlogin-finish | `cc` finishes the plugin installs on the first launch after sign-in |
| 02-home-dirs | `%USERPROFILE%\Projects` |
| 42-terminal-prefs | a **Claude Code** Windows Terminal profile (a fragment, so your WT settings stay untouched), plus Start-menu and desktop shortcuts with the Claude Code mascot icon that open the `cc` menu |
| not ported | passwordless sudo, update policy, the GNOME desktop modules, `phonecc` (tmux), `ccssh` (Windows OpenSSH has no ControlMaster), `render-page` |

**The `cc` menu** ([`windows/cc-launcher.js`](windows/cc-launcher.js)) lists
the folders under `Projects` plus `os-changes` (this machine) and `misc` (small
research). "↩ Pick up where you left off" shows your recent sessions as cards
(what each was about, how many exchanges, how full its context is), and each
folder offers continue / new / pick an earlier session. When a session's
context runs red, "⚑ Wrap up & hand off" has Claude write `HANDOFF.md`, and the
next visit offers "⇥ New session from hand-off". Arrow keys + Enter, Esc back,
`?` help. `cc <folder>` skips the menu. A short tour runs on the first `cc`.

**On a box that already has `cctemp`:** `ccinstall` converts the install to
permanent. It removes the 30-day auto-cleanup task and the temporary marker,
and keeps the binary, your sign-in and your history.
It leaves its own marker, `%LOCALAPPDATA%\ai-terminal\installed.json`,
recording when and by whom the install was made.

```powershell
# read-only PASS/FAIL report (like verify.sh)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/ccinstall.ps1))) -Verify
# remove what ccinstall added (cc, statusline, profile, shortcuts); Claude Code stays.
# cctemp.ps1 -Cleanup purges Claude Code itself.
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/ccinstall.ps1))) -Uninstall
```

Other switches: `-NoSignIn` (unattended), `-NoShortcuts`, `-Ref <tag>`.

## Windows: temporary troubleshooting install (`cctemp`)

Not a workstation build: [`windows/cctemp.ps1`](windows/cctemp.ps1) puts
Claude Code on a Windows box **for the duration of a troubleshooting
engagement only** — user-profile-scoped, no admin, no services — and removes it
completely when you're done. It leaves an intent marker
(`%LOCALAPPDATA%\cctemp\installed.json`) so anyone finding it later can tell it
apart from a deliberate install.

```powershell
irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/cctemp.ps1 | iex
```

A dead-man switch is armed by default: a daily task purges everything after
**30 days of no use**. Tune with `-AutoCleanupDays N` (0 disables). Remove
immediately:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/cctemp.ps1))) -Cleanup
```

## What the core installs

| Module | Purpose |
|---|---|
| 00-base-cli | git, gh, tmux, curl, wget, jq, unzip, lynx, xvfb, openssh-server, ca-certificates, gnupg |
| 01-sudo-nopasswd | passwordless sudo for the installing user — password asked once at first setup, never again |
| 02-home-dirs | creates the `~/Projects` workspace folder |
| 03-updates-policy | never offers a release upgrade (no "Ubuntu 26.04 Upgrade Available" dialog); ordinary updates apply unattended, no automatic reboot, no Software Updater window — the only prompt left is "restart required" |
| 05-node | Node.js 20 (NodeSource) + user-owned npm prefix `~/.npm-global` |
| 10-claude-code | Claude Code native install, `cc` / `phonecc` aliases, `cc-statusline` (live context-fill readout in every session), and **`ccssh`** — Claude Code wired to a remote server for one session (below) |
| 15-bun | Bun runtime (claude-mem's worker needs it) |
| 20-claude-mem | [claude-mem](https://github.com/thedotmack/claude-mem) persistent memory (plugin, latest release) |
| 25-superpowers | [superpowers](https://github.com/obra/superpowers) skills plugin |
| 27-postlogin-finish | `cct-finish` + a `.bashrc` hook: the first shell after `claude` login finishes the plugin installs automatically |
| 30-uv | uv/uvx — also **the kit's standard for tool venvs** (`uv venv ~/.venvs/<tool>`); `python3-venv` is deliberately not installed |
| 31-render-page | `render-page <url> [--click <text>]... [--json]` — reads a JavaScript-only page in the box's Chrome (Playwright, headless, own venv) and prints its text; `--json` lists the page's JSON/XHR calls |
| 38-x11-session | forces X11 (Wayland off at GDM) — RustDesk/Splashtop can't inject input on Wayland (skipped on DCV hosts, which own session config) |
| 40-gnome-qol | screen lock off, idle blanking off; dock = Firefox, Files, Terminal — on DCV hosts the dock is host-managed and left alone |
| 41-splashtop-cursorfix | works around a Splashtop ≤3.8.0.0 crash: static cursors, no Firefox launch spinner, LD_PRELOAD shim on the streamer (only where Splashtop is installed) |
| 42-terminal-prefs | seeds GNOME Terminal prefs (Ctrl+C/V copy-paste, 200×50 window) on fresh boxes — never overwrites later tweaks |
| 45-hyperv-qol | fixes over-fast wheel scrolling on Hyper-V/remote mice; adds user to `video` group (Hyper-V only) |
| 46-switcher | Switcher window picker on Alt+\` — fuzzy, matches window **titles**, so you can pick between many terminals |
| 50-okular-md | double-clicking a `.md` file opens it rendered (Okular) |

The aliases the core adds (they're the point of the box — remove them from
`~/.bashrc` if they're not your style):

```bash
alias cc='claude --dangerously-skip-permissions'
alias phonecc='tmux new-session -A -s claude claude --dangerously-skip-permissions'
```

In the same spirit the core sets up **passwordless sudo** for the installing
user (`01-sudo-nopasswd`) — a deliberate posture for a single-user workstation
VM. If you fork this and don't want it, delete that module.

### `ccssh` — Claude Code on a remote server, without storing the password

```bash
ccssh                                   # prompts: host (a URL is fine), user, port, password
ccssh --host srv.example.com --user admin
ccssh --test-connection                 # prove the login works, then tear down
```

Paste the password once from your password manager. `ccssh` opens an SSH ControlMaster
connection, hands the password to ssh through a one-shot FIFO (never on disk, never in the
process list, never left in any process's environment), wipes it, and launches Claude Code
with the server reachable through `rssh '<command>'`. **Durable for the whole session:**
keepalives notice a dead link within about a minute and a keeper re-opens it automatically
(network blip, server reboot, idle timeout) — `rssh` waits for the reconnect instead of
failing; the keeper holds the password in its own memory only and dies with the session.
When Claude Code exits the connection closes and every ephemeral file is gone; only
`known_hosts` fingerprints remain. Needs OpenSSH ≥ 8.4.

## Extras

| Flag | What you get |
|---|---|
| `--with-docker` | Docker CE + buildx + compose from docker.com, user in `docker` group |
| `--with-xrdp` | RDP access (xrdp) + XFCE session; RDP logins source your `~/.profile` |
| `--with-tailscale` | Tailscale installed + enabled (you still run `sudo tailscale up`) |
| `--with-printing-direct` | disables flaky `cups-browsed` auto-queues; add printers with `tools/add-printer.sh` |
| `--with-buildtools` | build-essential, maven, JDK, msitools/wixl, osslsigncode, mdbtools |
| `--with-usagemeter` | Claude subscription usage meter (tray icon + `localhost:7777`) |
| `--with-weak-passwords` | lab-VM password policy (anything goes). Deliberately **not** in `--all-extras` |
| `--with-splashtop` | Splashtop Streamer for remote access — asks for your deployment code |

`--all-extras` = every extra except `weak-passwords` and `splashtop`.

### Printers (direct IPP, no auto-queue roulette)

`cups-browsed` auto-creates stub queues, then re-registers them under new names
over time, orphaning the old ones — jobs silently die. The `printing-direct`
extra disables it; then add each printer once:

```bash
./tools/add-printer.sh Office_Printer ipp://printer-hostname.local/ipp/print
```

### Splashtop

`./bootstrap.sh --with-splashtop`, type your 12-digit deployment code when it
asks; the machine shows up in your Splashtop console.

## Verifying and auditing

- `./verify.sh` — read-only PASS/FAIL/SKIP report of the expected state.
- `./audit/system-audit.sh` — full read-only system snapshot (packages,
  services, desktop settings, …) into sorted text files + a tarball, built for
  diffing two machines. **Snapshots contain hostnames — don't commit or share
  them.**

## What this repo will never do

Install SSH keys, VPN credentials, printer addresses, or any other
machine-specific secret or identifier. Modules that need that kind of input
take it as an argument (`add-printer.sh`) or leave you a NEXT STEPS line.

## Building on it (layers)

A fleet platform can ship this kit inside its own release and add to it
without forking: its files are layered onto the kit tree at release time —
extra `modules/`, `lib/common.d/*.sh` helpers (sourced after `lib/common.sh`),
`verify.d/*.sh` checks (sourced by `verify.sh`), and an optional
`templates/cc-launcher.sh` that `cc` opens instead of plain Claude Code. A file
that would overwrite a kit file is an error, never a silent override. The public
kit ships none of these. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

MIT — see [LICENSE](LICENSE).
