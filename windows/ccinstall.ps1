<#
.SYNOPSIS
    ccinstall: PERMANENT Claude Code install on Windows, set up the way the
    Ubuntu kit sets up a workstation. The deliberate counterpart of cctemp.

.DESCRIPTION
    Run it from a normal (non-elevated is fine) PowerShell, signed in as the
    person who will use Claude Code:

        irm https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/ccinstall.ps1 | iex

    What it sets up (the Windows side of the Ubuntu core modules):
      - git, gh, jq, Node.js LTS, Bun, uv - via winget (00-base-cli, 05-node,
        15-bun, 30-uv). Git for Windows is required: Claude Code uses its Bash.
      - Claude Code from the official native installer (10-claude-code), with
        %USERPROFILE%\.local\bin on the user PATH.
      - `cc` = the workspace launcher (cc-launcher.js): a menu over
        %USERPROFILE%\Projects with recent-session recall, continue / new /
        hand-off / wrap-up, misc and os-changes - then claude
        --dangerously-skip-permissions in the chosen folder. A cc.cmd shim, so
        it works in PowerShell, cmd and Windows Terminal alike, no profile or
        execution-policy change needed. `cc <folder>` skips the menu.
      - The context-fill statusline (cc-statusline.js), wired into
        ~\.claude\settings.json unless you already have a statusLine.
      - claude-mem and superpowers plugins (20-claude-mem, 25-superpowers).
        They need a signed-in Claude Code: the script offers to sign in, and
        if you skip that, the first `cc` after sign-in finishes them
        (27-postlogin-finish does the same from .bashrc on Ubuntu).
      - %USERPROFILE%\Projects (02-home-dirs), plus a "Claude Code" Windows
        Terminal profile and Start-menu/desktop shortcuts (Claude Code mascot
        icon) that open the `cc` menu.

      - Self-update (04-auto-update): a per-user scheduled task,
        ai-terminal-update, checks every 2 hours and at sign-in and applies
        newer kit files (menu, statusline, shim, shortcuts, this script) from
        the ref the box was installed from - only while this user has no
        Claude Code running, else it waits for the next run. Claude Code
        itself auto-updates.

    Idempotent: re-running is safe, and repairs anything the self-update
    cannot (missing tools, sign-in, plugins).

    A box that still has a temporary cctemp install is converted: the cctemp
    dead-man task and marker are removed so the 30-day idle purge can no
    longer delete a permanent install. Binary, sign-in and history are kept.

    Switches go through the scriptblock form (content piped to iex can't take
    parameters - same launcher rationale as windows/get.ps1):

        & ([scriptblock]::Create((irm <same-url>))) -Verify
        & ([scriptblock]::Create((irm <same-url>))) -Uninstall

.PARAMETER Verify
    Read-only PASS/FAIL/SKIP report, like verify.sh.
.PARAMETER Finish
    Only the sign-in-gated plugin installs. Run by cc.cmd from the local copy.
.PARAMETER Update
    What the ai-terminal-update task runs: fetch the kit at the installed ref
    and, if anything changed and Claude Code is not running, apply it. Logged
    to %LOCALAPPDATA%\ai-terminal\update.log; last outcome in update-last.json.
    Add -Now to apply even while Claude Code is running.
.PARAMETER Refresh
    Internal: rewrite the kit files only (no winget, no sign-in, no plugins).
    -Update runs the NEW script with it, so new install logic applies too.
.PARAMETER NoAutoUpdate
    Don't register the self-update task (writes %LOCALAPPDATA%\ai-terminal\no-auto-update;
    delete that file and re-run ccinstall to turn it back on).
.PARAMETER Uninstall
    Remove what this script added (cc, statusline, shortcuts, terminal
    profile, self-update task, marker). Claude Code, your sign-in, history and the winget
    tools stay; cctemp.ps1 -Cleanup purges Claude Code completely.
.PARAMETER NoSignIn
    Don't offer to open Claude Code for sign-in (unattended runs).
.PARAMETER NoShortcuts
    Skip the Start-menu and desktop shortcuts.
.PARAMETER Ref
    Git ref the helper files are fetched from (default: main).

.NOTES
    - Installs for the CURRENT user profile. Refuses to run as SYSTEM (an RMM
      backstage session): the install would land in the SYSTEM profile, which
      is cctemp's job, not this one's.
    - winget may raise a UAC prompt for machine-wide packages (Git, Node).
      Without winget (some Server SKUs) those tools are reported as next
      steps; Bun and uv fall back to their official installers.
    - Not ported (Linux-only): passwordless sudo, update policy, the GNOME
      desktop modules, phonecc (tmux), ccssh (needs OpenSSH ControlMaster,
      which Windows OpenSSH lacks), render-page.
#>

[CmdletBinding()]
param(
    [switch]$Verify,
    [switch]$Finish,
    [switch]$Uninstall,
    [switch]$Update,
    [switch]$Now,
    [switch]$Refresh,
    [switch]$NoSignIn,
    [switch]$NoAutoUpdate,
    [switch]$NoShortcuts,
    [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'

# Guards first: everything below assumes a real user's Windows profile.
if ($env:OS -ne 'Windows_NT') { Write-Host 'ccinstall: Windows only - on Ubuntu use get.adnet.tools.' -ForegroundColor Red; return }
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    Write-Host 'ccinstall: running as SYSTEM - this would install into the SYSTEM profile.' -ForegroundColor Red
    Write-Host '  Run it from the user''s own session. For a quick troubleshooting install as SYSTEM, use cctemp.ps1.'
    return
}

$UserHome  = $env:USERPROFILE
$Bin       = Join-Path $UserHome '.local\bin'
$Projects  = Join-Path $UserHome 'Projects'
$StateDir  = Join-Path $env:LOCALAPPDATA 'ai-terminal'
$Marker    = Join-Path $StateDir 'installed.json'
$LocalCopy = Join-Path $StateDir 'ccinstall.ps1'
$Settings  = Join-Path $UserHome '.claude\settings.json'
$PluginDir = Join-Path $UserHome '.claude\plugins\cache'
# The self-update follows the ref the box was installed from (main unless -Ref said otherwise).
if ($Update -and -not $PSBoundParameters.ContainsKey('Ref') -and (Test-Path $Marker)) {
    try { $r = (Get-Content $Marker -Raw | ConvertFrom-Json).ref; if ($r) { $Ref = $r } } catch { }
}
if ($Ref -notmatch '^[A-Za-z0-9._/-]+$') { $Ref = 'main' }
$Repo      = 'adnettech/ai-terminal'
$RawRoot   = "https://raw.githubusercontent.com/$Repo/$Ref"
$SelfUrl   = "$RawRoot/windows/ccinstall.ps1"
$Icon      = Join-Path $StateDir 'claude-code.ico'
$WtFragDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\ai-terminal'
$WtGuid    = '{c8e929d4-dc38-4e14-bf0e-fb42593945a8}'
$LinkName  = 'Claude Code.lnk'
$StartLink = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$LinkName"
$DeskLink  = Join-Path ([Environment]::GetFolderPath('Desktop')) $LinkName
$TaskName  = 'ai-terminal-update'
$NoUpdate  = Join-Path $StateDir 'no-auto-update'
$UpdLog    = Join-Path $StateDir 'update.log'
$UpdLast   = Join-Path $StateDir 'update-last.json'
$Staging   = Join-Path $StateDir 'staging'
# Repo file -> where it is installed. A changed ccinstall.ps1 stands for everything it
# generates (cc.cmd, the terminal profile, the shortcuts), so these four cover the kit.
$KitFiles  = [ordered]@{
    'windows/ccinstall.ps1'          = $LocalCopy
    'windows/cc-launcher.js'         = (Join-Path $Bin 'cc-launcher.js')
    'windows/cc-statusline.js'       = (Join-Path $Bin 'cc-statusline.js')
    'assets/windows/claude-code.ico' = $Icon
}

$script:Failed = $false
$script:Next   = New-Object System.Collections.Generic.List[string]

function Say($m)  { Write-Host "[ccinstall] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Skip($m) { Write-Host "  SKIP  $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:Failed = $true }
function Next($m) { if (-not $script:Next.Contains($m)) { $script:Next.Add($m) } }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

# Native commands write progress to stderr; under 'Stop' Windows PowerShell 5.1
# turns a redirected stderr line into a terminating error. Run them relaxed and
# hand back exit code + output.
function Invoke-Quiet([scriptblock]$Block) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Block 2>&1 | Out-String } finally { $ErrorActionPreference = $eap }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
    if (($env:Path -split ';') -notcontains $Bin) { $env:Path = "$Bin;$env:Path" }
}

function Write-Utf8NoBom($Path, $Text) {
    # Set-Content -Encoding UTF8 on 5.1 writes a BOM, which JSON.parse rejects.
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Get-KitFile($RepoPath, $Dest) {
    # $RepoPath is relative to the repo root. From the checkout when run as a file
    # (windows\ccinstall.ps1), else from GitHub (irm | iex).
    $local = if ($PSScriptRoot) { Join-Path (Split-Path $PSScriptRoot) $RepoPath } else { $null }
    New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null
    if ($local -and (Test-Path $local)) {
        if ($local -ne $Dest) { Copy-Item $local $Dest -Force }
    } else {
        Invoke-WebRequest -Uri "$RawRoot/$RepoPath" -OutFile $Dest -UseBasicParsing
    }
}

function Test-SignedIn { Test-Path (Join-Path $UserHome '.claude\.credentials.json') }

function Test-Plugins {
    (Test-Path (Join-Path $PluginDir 'thedotmack')) -and (Test-Path (Join-Path $PluginDir 'superpowers-marketplace'))
}

function Get-StatuslineCmd { 'node "' + ((Join-Path $Bin 'cc-statusline.js') -replace '\\', '/') + '"' }

# settings.json edits go through node (installed above, and required by the
# statusline anyway): it round-trips the user's JSON untouched, where 5.1's
# ConvertTo-Json would re-escape and reflow it.
function Set-StatusLine([ValidateSet('add', 'remove')]$Mode) {
    $js = Join-Path $env:TEMP 'ait-statusline-merge.js'
    Write-Utf8NoBom $js @'
const fs = require('fs'), path = require('path');
const [, , mode, file, cmd] = process.argv;
let cfg = {};
if (fs.existsSync(file)) {
    try { cfg = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }
    catch (e) { console.log('unparsable'); process.exit(2); }
}
if (mode === 'add') {
    if (cfg.statusLine) { console.log(String(cfg.statusLine.command || '').includes('cc-statusline') ? 'ours' : 'theirs'); process.exit(0); }
    cfg.statusLine = { type: 'command', command: cmd };
} else {
    if (!cfg.statusLine || !String(cfg.statusLine.command || '').includes('cc-statusline')) { console.log('none'); process.exit(0); }
    delete cfg.statusLine;
}
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n');
console.log('written');
'@
    $cmd = Get-StatuslineCmd
    $r = Invoke-Quiet { node $js $Mode $Settings $cmd }
    Remove-Item $js -Force -ErrorAction SilentlyContinue
    if ($r.Code -ne 0) { return 'unparsable' }
    return $r.Out.Trim()
}

function Add-UserPath($Dir) {
    # Read and write the raw REG_EXPAND_SZ value: [Environment]::SetEnvironmentVariable
    # would save it expanded, as REG_SZ, breaking any %VAR% entries already there.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $raw = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $parts = $raw -split ';' | Where-Object { $_ }
        if ($parts -contains $Dir) { return $false }
        $key.SetValue('Path', ((@($Dir) + $parts) -join ';'), 'ExpandString')
    } finally { $key.Close() }
    # Tell Explorer, so terminals opened from the Start menu see it without a re-login.
    if (-not ('AiTerminal.Env' -as [type])) {
        Add-Type -Namespace AiTerminal -Name Env -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    }
    $res = [UIntPtr]::Zero
    [void][AiTerminal.Env]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$res)
    return $true
}

function Install-Tool($Name, $Cmd, $WingetId, [scriptblock]$Fallback, [switch]$Required) {
    if (Have $Cmd) { Ok "$Name present"; return }
    if (Have winget) {
        Say "installing $Name (winget $WingetId) - approve the UAC prompt if one appears..."
        $r = Invoke-Quiet { winget install --id $WingetId --exact --silent --accept-package-agreements --accept-source-agreements }
        Update-SessionPath
        if (Have $Cmd) { Ok "$Name installed"; return }
        Write-Host ($r.Out.Trim() -split "`n" | Select-Object -Last 3 | Out-String)
    }
    if ($Fallback) {
        Say "installing $Name (official installer)..."
        Invoke-Quiet $Fallback | Out-Null
        Update-SessionPath
        if (Have $Cmd) { Ok "$Name installed"; return }
    }
    $msg = "install $Name (winget install --id $WingetId), then re-run ccinstall"
    if ($Required) { Bad "$Name missing"; Next $msg } else { Skip "$Name missing"; Next $msg }
}

function Install-Plugin($Name, $Market, $MarketRepo) {
    if ((Invoke-Quiet { claude plugin list }).Out -match [regex]::Escape($Name)) { Ok "$Name plugin present"; return }
    if ((Invoke-Quiet { claude plugin marketplace list }).Out -notmatch [regex]::Escape($Market)) {
        $r = Invoke-Quiet { claude plugin marketplace add $MarketRepo }
        if ($r.Code -ne 0) {
            Bad "$Name marketplace add failed"
            Next "inside claude, run: /plugin marketplace add $MarketRepo"
            return
        }
    }
    $r = Invoke-Quiet { claude plugin install "$Name@$Market" }
    if ($r.Code -ne 0) {
        Bad "$Name plugin install failed"
        Next "inside claude, run: /plugin install $Name@$Market"
        return
    }
    Ok "installed $Name@$Market"
    Next 'plugins installed - restart any open claude session to activate them.'
}

function Install-Plugins {
    if (-not (Have claude)) { Skip 'plugins: Claude Code not installed'; return }
    if (-not (Test-SignedIn)) { Skip 'plugins: Claude Code not signed in yet'; Next 'run cc and sign in - the next cc launch finishes the plugins (claude-mem, superpowers)'; return }
    Install-Plugin 'claude-mem' 'thedotmack' 'thedotmack/claude-mem'
    Install-Plugin 'superpowers' 'superpowers-marketplace' 'obra/superpowers-marketplace'
}

function Remove-CCTempSwitch {
    # A permanent install must never be purged by a leftover temporary one's dead-man task.
    $ctDir = Join-Path $env:LOCALAPPDATA 'cctemp'
    $task = (Invoke-Quiet { schtasks /Query /TN 'cctemp-autocleanup' }).Code -eq 0
    $dir = Test-Path $ctDir
    if (-not ($task -or $dir)) { return }
    if ($task) { Invoke-Quiet { schtasks /Delete /TN 'cctemp-autocleanup' /F } | Out-Null }
    if ($dir) { Remove-Item $ctDir -Recurse -Force -ErrorAction SilentlyContinue }
    Ok 'converted the temporary cctemp install to permanent (auto-cleanup task and marker removed)'
}

function Write-Shim {
    $shim = @'
@echo off
rem ai-terminal: cc = the workspace menu, then Claude Code with permission prompts off.
rem Written by windows/ccinstall.ps1; re-running ccinstall rewrites it. The menu (Node) also
rem finishes the plugin installs on the first launch after sign-in; without Node, this does.
where node >nul 2>nul || goto plain
if not exist "%~dp0cc-launcher.js" goto plain
node "%~dp0cc-launcher.js" %*
goto :eof
:plain
if not exist "%USERPROFILE%\.claude\.credentials.json" goto run
if not exist "%USERPROFILE%\.claude\plugins\cache\thedotmack\" goto finish
if not exist "%USERPROFILE%\.claude\plugins\cache\superpowers-marketplace\" goto finish
goto run
:finish
if not exist "%LOCALAPPDATA%\ai-terminal\ccinstall.ps1" goto run
echo ai-terminal: claude is ready - finishing plugin setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\ai-terminal\ccinstall.ps1" -Finish
:run
if not exist "%~dp0claude.exe" goto onpath
"%~dp0claude.exe" --dangerously-skip-permissions %*
goto :eof
:onpath
claude --dangerously-skip-permissions %*
'@
    New-Item -ItemType Directory -Path $Bin -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Bin 'cc.cmd'), ($shim -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)
    Ok 'cc -> workspace menu -> claude --dangerously-skip-permissions (cc.cmd)'
}

function Get-CcCommandLine {
    # Shortcuts and the terminal profile run the menu straight from PowerShell, not through
    # cc.cmd: Ctrl+C inside Claude Code would otherwise leave cmd asking "Terminate batch
    # job (Y/N)?" when the session ends. -NoExit leaves a shell in the folder afterwards.
    $launcher = Join-Path $Bin 'cc-launcher.js'
    if ((Have node) -and (Test-Path $launcher)) {
        $l = $launcher -replace "'", "''"
        return "powershell.exe -NoLogo -NoExit -Command `"& node '$l'`""
    }
    $cc = (Join-Path $Bin 'cc.cmd') -replace "'", "''"
    "powershell.exe -NoLogo -NoExit -Command `"& '$cc'`""
}

function Write-Launchers {
    # Windows Terminal picks up fragments without touching its settings.json.
    $frag = @{ profiles = @(@{
        guid              = $WtGuid
        name              = 'Claude Code'
        commandline       = (Get-CcCommandLine)
        startingDirectory = $Projects
        icon              = $Icon
    }) } | ConvertTo-Json -Depth 5
    Write-Utf8NoBom (Join-Path $WtFragDir 'claude-code.json') $frag
    Ok 'Windows Terminal profile "Claude Code"'

    if ($NoShortcuts) { Skip 'shortcuts (-NoShortcuts)'; return }
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    $ws = New-Object -ComObject WScript.Shell
    foreach ($path in @($StartLink, $DeskLink)) {
        # A self-update doesn't bring back a desktop shortcut someone deleted.
        if ($Refresh -and $path -eq $DeskLink -and -not (Test-Path $path)) { continue }
        $lnk = $ws.CreateShortcut($path)
        if ($wt) {
            $lnk.TargetPath = $wt.Source
            $lnk.Arguments  = '-p "Claude Code"'
        } else {
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $lnk.Arguments  = (Get-CcCommandLine) -replace '^powershell\.exe ', ''
        }
        $lnk.WorkingDirectory = $Projects
        $lnk.Description = 'Claude Code (cc)'
        if (Test-Path $Icon) { $lnk.IconLocation = "$Icon,0" }
        $lnk.Save()
    }
    Ok 'Start-menu and desktop shortcuts "Claude Code"'
}

function Register-UpdateTask {
    if (Test-Path $NoUpdate) { Unregister-UpdateTask; Skip "self-update off ($NoUpdate)"; return }
    # conhost --headless: powershell's -WindowStyle Hidden still flashes a window, and on
    # Windows 11 a Windows Terminal one, every time the task runs.
    $ps  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = "--headless `"$ps`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$LocalCopy`" -Update"
    $me  = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\conhost.exe') -Argument $arg
        $every  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Hours 2)
        $logon  = New-ScheduledTaskTrigger -AtLogOn -User $me
        $logon.Delay = 'PT5M'
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        $who = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
        $desc = 'ai-terminal: keeps the Claude Code kit (cc menu, statusline, shortcuts) current. Remove with ccinstall -Uninstall.'
        try {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($every, $logon) -Settings $set -Principal $who -Description $desc -Force | Out-Null
            Ok "self-update: task $TaskName (every 2 h and at sign-in, never while Claude Code runs)"
        } catch {
            # some builds want admin for a logon trigger; the 2-hourly one alone still does the job
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $every -Settings $set -Principal $who -Description $desc -Force | Out-Null
            Ok "self-update: task $TaskName (every 2 h, never while Claude Code runs)"
        }
    } catch {
        Skip "self-update task not registered ($($_.Exception.Message))"
        Next 're-run ccinstall to retry the self-update task'
    }
}

function Unregister-UpdateTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        return $true
    }
    $false
}

function Write-UpdateResult($Result, $Detail, $Commit) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $msg = if ($Detail) { "$($Result): $Detail" } else { $Result }
    Say "update $msg"
    $log = @(if (Test-Path $UpdLog) { Get-Content $UpdLog | Select-Object -Last 199 })
    $log += "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [$Ref] $msg"
    Write-Utf8NoBom $UpdLog (($log -join "`r`n") + "`r`n")
    @{ result = $Result; detail = "$Detail"; at = (Get-Date).ToString('o'); ref = $Ref; commit = "$Commit" } |
        ConvertTo-Json | ForEach-Object { Write-Utf8NoBom $UpdLast $_ }
}

function Get-KitCommit {
    # Resolve the ref to one commit so the files fetched together are one snapshot
    # (raw.githubusercontent.com at a branch name can straddle a push). Falls back to the ref.
    try {
        $r = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/commits/$Ref" -UseBasicParsing -TimeoutSec 30 `
            -Headers @{ Accept = 'application/vnd.github.sha' }
        $c = $r.Content
        if ($c -is [byte[]]) { $c = [Text.Encoding]::ASCII.GetString($c) }
        if ("$c".Trim() -match '^[0-9a-f]{40}$') { return "$c".Trim() }
    } catch { }
    $null
}

function Test-ClaudeBusy {
    # This user's Claude Code, or the cc menu about to start it. Not just any claude.exe: the
    # Claude desktop app is one too. Another user's processes show no path or command line.
    # Busy matters because cmd.exe re-reads cc.cmd while running it, so rewriting it then breaks that window.
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='claude.exe' OR Name='node.exe'" -ErrorAction SilentlyContinue)) {
        $exe = "$($p.ExecutablePath)"; $cmd = "$($p.CommandLine)"
        if ($p.Name -eq 'claude.exe' -and $exe.StartsWith((Join-Path $UserHome '.local\'), 'OrdinalIgnoreCase')) { return $true }
        if ($p.Name -eq 'node.exe' -and $cmd -match 'cc-launcher|claude-code' -and $cmd.IndexOf($UserHome, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    $false
}

function Get-Sha256($Path) { if (Test-Path $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash } }

function Invoke-SelfUpdate {
    if (Test-Path $NoUpdate) { Write-UpdateResult 'skipped' "self-update is off ($NoUpdate)"; return }
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $ProgressPreference = 'SilentlyContinue'
    $commit = Get-KitCommit
    $root = "https://raw.githubusercontent.com/$Repo/$(if ($commit) { $commit } else { $Ref })"
    # Staged in the repo's layout, so the new ccinstall.ps1 finds its kit files beside it.
    if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
    try {
        foreach ($f in $KitFiles.Keys) {
            $dest = Join-Path $Staging $f
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Invoke-WebRequest -Uri "$root/$f" -OutFile $dest -UseBasicParsing -TimeoutSec 60
        }
    } catch {
        Write-UpdateResult 'failed' "download: $($_.Exception.Message)" $commit
        return
    }
    # A file this box never installed (the statusline without Node) is not an update.
    $changed = @($KitFiles.Keys | Where-Object { ($_ -eq 'windows/ccinstall.ps1' -or (Test-Path $KitFiles[$_])) -and
        (Get-Sha256 (Join-Path $Staging $_)) -ne (Get-Sha256 $KitFiles[$_]) })
    if (-not $changed.Count) {
        Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
        Write-UpdateResult 'current' '' $commit
        return
    }
    if (-not $Now -and (Test-ClaudeBusy)) {
        Write-UpdateResult 'deferred' "Claude Code is running - next try in 2 h ($($changed -join ', ') changed)" $commit
        return
    }
    $new = Join-Path $Staging 'windows\ccinstall.ps1'
    $r = Invoke-Quiet { powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $new -Refresh -Ref $Ref }
    Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
    if ($r.Code -eq 0) { Write-UpdateResult 'applied' ($changed -join ', ') $commit }
    else { Write-UpdateResult 'failed' ("refresh: " + (($r.Out.Trim() -split "`n" | Select-Object -Last 2) -join ' ')) $commit }
}

function Save-LocalCopy {
    # Local copy: cc.cmd runs -Finish from it, and the self-update task runs -Update from it.
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    if ($PSCommandPath -and $PSCommandPath -ne $LocalCopy) { Copy-Item $PSCommandPath $LocalCopy -Force }
    elseif (-not $PSCommandPath) { Invoke-WebRequest -Uri $SelfUrl -OutFile $LocalCopy -UseBasicParsing }
}

function Install-KitFiles {
    if (Have node) {
        try {
            Get-KitFile 'windows/cc-statusline.js' (Join-Path $Bin 'cc-statusline.js')
            switch (Set-StatusLine add) {
                'written'    { Ok 'statusline wired into settings.json' }
                'ours'       { Ok 'statusline already wired' }
                'theirs'     { Skip 'statusLine already set to your own - left alone' }
                default      { Bad 'settings.json is not valid JSON - statusline not wired'; Next "fix $Settings, then re-run ccinstall" }
            }
        } catch { Bad "statusline: $($_.Exception.Message)" }
    } else { Skip 'statusline needs Node.js' }

    try {
        Get-KitFile 'windows/cc-launcher.js' (Join-Path $Bin 'cc-launcher.js')
        if (Have node) { Ok 'cc workspace menu (cc-launcher.js)' } else { Skip 'cc workspace menu needs Node.js - cc opens plain Claude Code until then' }
    } catch { Bad "cc-launcher.js: $($_.Exception.Message)" }
    try { Get-KitFile 'assets/windows/claude-code.ico' $Icon; Ok 'Claude Code icon' }
    catch { Skip "icon not fetched ($($_.Exception.Message)) - shortcuts keep the default icon" }
}

function Write-Marker {
    $first = $null
    if (Test-Path $Marker) { try { $first = Get-Content $Marker -Raw | ConvertFrom-Json } catch { } }
    @{
        installed_at = if ($first -and $first.installed_at) { $first.installed_at } else { (Get-Date).ToString('o') }
        installed_by = if ($first -and $first.installed_by) { $first.installed_by } else { "$env:USERDOMAIN\$env:USERNAME" }
        updated_at   = (Get-Date).ToString('o')
        host         = $env:COMPUTERNAME
        purpose      = 'PERMANENT Claude Code install (ccinstall, ai-terminal repo)'
        ref          = $Ref
        update       = "irm $SelfUrl | iex"
        uninstall    = "& ([scriptblock]::Create((irm $SelfUrl))) -Uninstall"
    } | ConvertTo-Json | ForEach-Object { Write-Utf8NoBom $Marker $_ }
}

function Show-Next {
    if ($script:Next.Count) {
        Write-Host "`nNEXT STEPS" -ForegroundColor Yellow
        $script:Next | ForEach-Object { Write-Host "  - $_" }
    }
}

# ---- modes -------------------------------------------------------------------

function Invoke-Verify {
    Update-SessionPath
    function P($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
    function F($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:Failed = $true }
    function S($m) { Write-Host "  SKIP  $m" -ForegroundColor Yellow }
    Say 'verify (read-only)'
    if (Have claude) { P "claude $((Invoke-Quiet { claude --version }).Out.Trim())" } else { F 'claude not on PATH' }
    foreach ($t in 'git', 'node', 'bun', 'uv') { if (Have $t) { P "$t" } else { F "$t missing" } }
    foreach ($t in 'gh', 'jq') { if (Have $t) { P "$t" } else { S "$t missing (optional)" } }
    $raw = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    if (($raw -split ';') -contains $Bin) { P "user PATH has $Bin" } else { F "user PATH lacks $Bin" }
    if (Test-Path (Join-Path $Bin 'cc.cmd')) { P 'cc shim' } else { F 'cc shim missing' }
    if (Test-Path (Join-Path $Bin 'cc-launcher.js')) { P 'cc workspace menu' } else { F 'cc-launcher.js missing' }
    if (Test-Path $Icon) { P 'Claude Code icon' } else { F 'icon missing' }
    if (Test-Path $Projects) { P "$Projects" } else { F "$Projects missing" }
    if ((Test-Path $Settings) -and ((Get-Content $Settings -Raw) -match 'cc-statusline')) { P 'statusline wired' }
    elseif ((Test-Path $Settings) -and ((Get-Content $Settings -Raw) -match '"statusLine"')) { S 'statusLine is your own (left alone)' }
    else { F 'statusline not wired' }
    $frag = Join-Path $WtFragDir 'claude-code.json'
    if (-not (Test-Path $frag)) { F 'Windows Terminal profile missing' }
    elseif ((Get-Content $frag -Raw) -match 'cc-launcher') { P 'Windows Terminal profile opens the cc menu' }
    else { F 'Windows Terminal profile starts Claude Code without the menu (old install) - re-run ccinstall' }
    if (Test-Path $StartLink) { P 'Start-menu shortcut' } else { F 'Start-menu shortcut missing' }
    if (Test-Path $DeskLink) { P 'desktop shortcut' } else { S 'no desktop shortcut' }
    if (Test-Path $NoUpdate) { S "self-update off ($NoUpdate)" }
    elseif (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { P "self-update task $TaskName" }
    else { F "self-update task $TaskName missing - re-run ccinstall" }
    if (Test-Path $UpdLast) {
        try {
            $u = Get-Content $UpdLast -Raw | ConvertFrom-Json
            $line = "last self-update check: $($u.result) $($u.at)$(if ($u.detail) { " - $($u.detail)" })"
            if ($u.result -eq 'failed') { S $line } else { P $line }
        } catch { S 'update-last.json unreadable' }
    } elseif (-not (Test-Path $NoUpdate)) { S 'self-update has not run yet' }
    if (Test-SignedIn) {
        P 'signed in'
        $pl = (Invoke-Quiet { claude plugin list }).Out
        foreach ($p in 'claude-mem', 'superpowers') { if ($pl -match $p) { P "$p plugin" } else { F "$p plugin missing (run cc)" } }
    } else { S 'not signed in yet - plugins not checked (run cc)' }
    if ((Invoke-Quiet { schtasks /Query /TN 'cctemp-autocleanup' }).Code -eq 0) { F 'cctemp auto-cleanup task still armed - re-run ccinstall' }
    else { P 'no cctemp dead-man switch' }
    if (Test-Path $Marker) { P 'install marker' } else { F 'install marker missing' }
}

function Invoke-Uninstall {
    Say 'removing what ccinstall added (Claude Code, your sign-in and history stay)'
    if (Unregister-UpdateTask) { Write-Host "  removed scheduled task $TaskName" }
    foreach ($f in @((Join-Path $Bin 'cc.cmd'), (Join-Path $Bin 'cc-statusline.js'), (Join-Path $Bin 'cc-launcher.js'), $StartLink, $DeskLink, $WtFragDir)) {
        if (Test-Path $f) { Remove-Item $f -Recurse -Force; Write-Host "  removed $f" }
    }
    if ((Have node) -and (Set-StatusLine remove) -eq 'written') { Write-Host '  removed statusLine from settings.json' }
    if (Test-Path $StateDir) { Remove-Item $StateDir -Recurse -Force; Write-Host "  removed $StateDir" }
    Say 'done. To purge Claude Code itself (binary, ~\.claude, sign-in):'
    Write-Host "  & ([scriptblock]::Create((irm $($RawRoot)/windows/cctemp.ps1))) -Cleanup"
}

function Invoke-Install {
    Say "PERMANENT Claude Code install for $env:USERDOMAIN\$env:USERNAME ($UserHome)"
    Remove-CCTempSwitch

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $ProgressPreference = 'SilentlyContinue'
    Update-SessionPath

    if (-not (Have winget)) { Skip 'winget not found - tools it would install are listed under NEXT STEPS' }
    Install-Tool 'Git for Windows' git  'Git.Git' -Required
    Install-Tool 'GitHub CLI'      gh   'GitHub.cli'
    Install-Tool 'jq'              jq   'jqlang.jq'
    Install-Tool 'Node.js LTS'     node 'OpenJS.NodeJS.LTS' -Required
    Install-Tool 'Bun'             bun  'Oven-sh.Bun' -Required -Fallback {
        powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://bun.sh/install.ps1 | iex' }
    Install-Tool 'uv'              uv   'astral-sh.uv' -Fallback {
        powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://astral.sh/uv/install.ps1 | iex' }

    if (Have claude) {
        Ok "Claude Code present ($((Invoke-Quiet { claude --version }).Out.Trim())) - it updates itself"
    } else {
        Say 'installing Claude Code (official native installer)...'
        $inst = Join-Path $env:TEMP 'claude-install.ps1'
        Invoke-WebRequest -Uri 'https://claude.ai/install.ps1' -OutFile $inst -UseBasicParsing
        Unblock-File -Path $inst -ErrorAction SilentlyContinue
        & $inst
        Update-SessionPath
        if (Have claude) { Ok 'Claude Code installed' } else { Bad 'claude not found after install'; Next 'open a new terminal and re-run ccinstall' }
    }
    if (Add-UserPath $Bin) { Ok "added $Bin to user PATH" } else { Ok "user PATH has $Bin" }

    New-Item -ItemType Directory -Path $Projects -Force | Out-Null
    Ok "$Projects"

    Save-LocalCopy
    Write-Shim
    Install-KitFiles
    Write-Launchers
    if ($NoAutoUpdate) { New-Item -ItemType File -Path $NoUpdate -Force | Out-Null }
    Register-UpdateTask

    if (-not (Test-SignedIn) -and (Have claude) -and -not $NoSignIn) {
        try {
            $a = Read-Host "`nSign in to Claude Code now? It opens here - sign in, then type /exit to finish setup [Y/n]"
            if ($a -notmatch '^[nN]') { & claude }
        } catch { }   # non-interactive host: the cc shim finishes later
    }
    Install-Plugins
    Write-Marker

    Show-Next
    Write-Host ''
    if ($script:Failed) { Say 'finished with failures - see above.' } else { Say 'done.' }
    Write-Host '  Open a NEW terminal (PATH changed), or the "Claude Code" profile/shortcut, and run:  cc' -ForegroundColor Green
}

function Invoke-Refresh {
    # Run by -Update from the freshly fetched script: the kit files only, nothing that
    # needs a person (winget UAC, sign-in) or the network beyond what -Update staged.
    Say "refreshing the kit files from $Ref"
    Update-SessionPath
    Save-LocalCopy
    Write-Shim
    Install-KitFiles
    Write-Launchers
    Register-UpdateTask
    Write-Marker
    if ($script:Failed) { exit 1 }
}

# ---- entry -------------------------------------------------------------------

if ($Verify)        { Invoke-Verify }
elseif ($Uninstall) { Invoke-Uninstall }
elseif ($Finish)    { Update-SessionPath; Say 'finishing plugin setup'; Install-Plugins; Show-Next }
elseif ($Update)    { Invoke-SelfUpdate }
elseif ($Refresh)   { Invoke-Refresh }
else                { Invoke-Install }
