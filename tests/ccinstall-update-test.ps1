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
exit $fail
