param(
    [string[]]$Clients = @('client01'),
    [string]$GameSlot,
    [string]$ServerHost,
    [int]$Port = 17641,
    [string]$Session,
    [ValidateSet('create','join')][string]$Mode = 'join',
    [switch]$Qa2v2,
    [switch]$PersonalTeam,
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$LaunchArgs = @("$Root/tools/h0.py", 'launch', '--clients') + $Clients
if ($Run) {
    if (-not $GameSlot) { throw 'Run requires -GameSlot pointing to the reviewed gameslot.py' }
    if ($ServerHost) {
        if (-not $Session -or $Clients.Count -ne 1) { throw 'Network run requires -Session and exactly one -Clients entry' }
        $CoopArgs = @()
        if ($Qa2v2) { $CoopArgs += "--qa-2v2" }
        if ($PersonalTeam) { $CoopArgs += "--personal-team" }
        & py -3 "$Root/tools/windows_network.py" --client $Clients[0] --server-host $ServerHost --port $Port --session $Session --mode $Mode --gameslot $GameSlot @CoopArgs
        exit $LASTEXITCODE
    }
    $LaunchArgs += @('--run', '--gameslot', $GameSlot)
}
& py -3 @LaunchArgs
exit $LASTEXITCODE
