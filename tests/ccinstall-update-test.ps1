# ccinstall.ps1 -Update, exercised under pwsh (Linux CI or Windows) with the Windows-only and
# network calls mocked: GitHub is served from this checkout, processes and the -Refresh child are
# fakes. Run by tests/ccinstall-update-test.sh, which prepares $Root.
param($Script, $Root, $Checkout)
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
foreach ($f in $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$UserHome = Join-Path $Root 'home'; $Bin = Join-Path $UserHome '.local/bin'
$StateDir = Join-Path $Root 'state'; $LocalCopy = Join-Path $StateDir 'ccinstall.ps1'
$Icon = Join-Path $StateDir 'claude-code.ico'; $Ref = 'main'; $Repo = 'acme/kit'
$NoUpdate = Join-Path $StateDir 'no-auto-update'; $UpdLog = Join-Path $StateDir 'update.log'
$UpdLast = Join-Path $StateDir 'update-last.json'; $Staging = Join-Path $StateDir 'staging'
$KitFiles = [ordered]@{
    'windows/ccinstall.ps1' = $LocalCopy; 'windows/cc-launcher.js' = (Join-Path $Bin 'cc-launcher.js')
    'windows/cc-statusline.js' = (Join-Path $Bin 'cc-statusline.js'); 'assets/windows/claude-code.ico' = $Icon }
$Now = $false
$global:procs = @(); $global:refreshArgs = $null
function Get-CimInstance { $global:procs }
function Invoke-WebRequest($Uri, $OutFile) {
    if ($Uri -match '/commits/') { return [pscustomobject]@{ Content = ('a' * 40) } }
    Copy-Item (Join-Path $Checkout ($Uri -replace '^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[^/]+/', '')) $OutFile
}
function powershell.exe { $global:refreshArgs = $args -join ' '; $global:LASTEXITCODE = 0; 'refreshed' }
function Last { (Get-Content $UpdLast -Raw | ConvertFrom-Json) }
$fail = 0
function Check($name, $cond) { if ($cond) { "  ok   $name" } else { "  BAD  $name"; $script:fail++ } }

Invoke-SelfUpdate 6>$null
Check 'identical -> current' ((Last).result -eq 'current' -and (Last).commit -match '^[0-9a-f]{40}$')
Check 'staging cleaned' (-not (Test-Path $Staging))

Add-Content (Join-Path $Bin 'cc-launcher.js') '// local drift'
$global:procs = @([pscustomobject]@{ Name = 'claude.exe'; ExecutablePath = (Join-Path $UserHome '.local\bin\claude.exe'); CommandLine = '' })
Invoke-SelfUpdate 6>$null
Check 'changed + our claude running -> deferred' ((Last).result -eq 'deferred' -and (Last).detail -match 'cc-launcher')
Check 'nothing refreshed while busy' ($null -eq $global:refreshArgs)

$global:procs = @([pscustomobject]@{ Name = 'claude.exe'; ExecutablePath = 'C:\Users\x\AppData\Local\AnthropicClaude\claude.exe'; CommandLine = '' },
                  [pscustomobject]@{ Name = 'node.exe'; ExecutablePath = ''; CommandLine = $null })
Invoke-SelfUpdate 6>$null
Check 'desktop app / foreign node is not busy -> applied' ((Last).result -eq 'applied')
Check 'runs the staged script with -Refresh -Ref main' ($global:refreshArgs -match 'staging.windows.ccinstall\.ps1 -Refresh -Ref main')

$global:refreshArgs = $null
$global:procs = @([pscustomobject]@{ Name = 'node.exe'; ExecutablePath = ''; CommandLine = "node $Bin\cc-launcher.js" })
Invoke-SelfUpdate 6>$null
Check 'cc menu open -> deferred' ((Last).result -eq 'deferred')
$Now = $true; Invoke-SelfUpdate 6>$null; $Now = $false
Check '-Now applies anyway' ((Last).result -eq 'applied')

Remove-Item (Join-Path $Bin 'cc-statusline.js'); $global:procs = @()
Copy-Item (Join-Path $Checkout 'windows/cc-launcher.js') (Join-Path $Bin 'cc-launcher.js') -Force
Invoke-SelfUpdate 6>$null
Check 'never-installed statusline is not an update' ((Last).result -eq 'current')

New-Item -ItemType File $NoUpdate | Out-Null
Invoke-SelfUpdate 6>$null
Check 'opt-out -> skipped' ((Last).result -eq 'skipped')
Check 'log has one line per run' (@(Get-Content $UpdLog).Count -eq 7)

# ---- plugin updates (Invoke-ComponentUpdate): a fake claude with three plugins -------------
Remove-Item $NoUpdate
$NoCompUpd = Join-Path $StateDir 'no-component-update'; $CompLast = Join-Path $StateDir 'components-last.json'
function Update-SessionPath { }
function Have($c) { $true }
$global:calls = @(); $global:ver = @{ 'claude-mem' = '16.0.0'; 'superpowers' = '7.0.0' }
$global:newer = @{ 'claude-mem' = '16.1.0' }; $global:broken = @()
function claude {
    $global:calls += ($args -join ' '); $global:LASTEXITCODE = 0
    if ("$args" -eq 'plugin list --json') {
        '[{"id":"claude-mem@thedotmack","version":"' + $global:ver['claude-mem'] + '","scope":"user"},' +
        '{"id":"superpowers@superpowers-marketplace","version":"' + $global:ver['superpowers'] + '","scope":"user"},' +
        '{"id":"team@somewhere","version":"1.0.0","scope":"project"},{"id":"cc-plugin-x@builtin","version":"unknown","scope":"user"}]'
    } elseif ($args[0] -eq 'plugin' -and $args[1] -eq 'update') {
        $n = ($args[2] -split '@')[0]
        if ($global:broken -contains $n) { $global:LASTEXITCODE = 1; return 'failed' }
        if ($global:newer[$n]) { $global:ver[$n] = $global:newer[$n]; $global:newer.Remove($n) }
        'Checking for updates'; '{"outcome":"ok","newVersion":"' + $global:ver[$n] + '"}'
    }
}
function CLast { (Get-Content $CompLast -Raw | ConvertFrom-Json) }
Invoke-ComponentUpdate 6>$null
Check 'plugins: the newer claude-mem is reported, superpowers current' ((CLast).result -eq 'ok' -and (CLast).updated -eq 'claude-mem 16.0.0 -> 16.1.0')
Check 'plugins: marketplaces refreshed, then each user plugin' (($global:calls -join '|') -match 'plugin marketplace update\|plugin update claude-mem@thedotmack --json\|plugin update superpowers@superpowers-marketplace --json')
Check 'plugins: project-scope and built-in plugins left alone' (-not (($global:calls -join '|') -match 'team@|builtin'))
$global:calls = @(); Invoke-ComponentUpdate 6>$null
Check 'plugins: at most once a day' ($global:calls.Count -eq 0)
$Now = $true; $global:broken = @('claude-mem'); $global:newer = @{ 'superpowers' = '7.1.0' }; Invoke-ComponentUpdate 6>$null; $Now = $false
Check 'plugins: one failing does not stop the next' ((CLast).result -eq 'failed' -and (CLast).failed -eq 'claude-mem' -and (CLast).updated -eq 'superpowers 7.0.0 -> 7.1.0')
New-Item -ItemType File $NoCompUpd | Out-Null; $global:calls = @(); $Now = $true; Invoke-ComponentUpdate 6>$null; $Now = $false
Check 'plugins: opt-out file -> nothing runs' ($global:calls.Count -eq 0)
exit $fail
