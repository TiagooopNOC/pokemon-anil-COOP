param(
    [string[]]$Clients = @('client01'),
    [string]$GameSlot,
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$LaunchArgs = @("$Root/tools/h0.py", 'launch', '--clients') + $Clients
if ($Run) {
    if (-not $GameSlot) { throw 'Run requires -GameSlot pointing to the reviewed gameslot.py' }
    $LaunchArgs += @('--run', '--gameslot', $GameSlot)
}
& py -3 @LaunchArgs
exit $LASTEXITCODE
