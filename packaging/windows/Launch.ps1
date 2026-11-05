param(
    [string[]]$Clients = @('client01'),
    [string]$GameSlot,
    [string]$ServerHost,
    [int]$Port = 17641,
    [string]$Session,
    [ValidateSet('create','join')][string]$Mode = 'join',
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$LaunchArgs = @("$Root/tools/h0.py", 'launch', '--clients') + $Clients
if ($Run) {
    if (-not $GameSlot) { throw 'Run requires -GameSlot pointing to the reviewed gameslot.py' }
    if ($ServerHost) {
        if (-not $Session -or $Clients.Count -ne 1) { throw 'Network run requires -Session and exactly one -Clients entry' }
        & py -3 "$Root/tools/windows_network.py" --client $Clients[0] --server-host $ServerHost --port $Port --session $Session --mode $Mode --gameslot $GameSlot
        exit $LASTEXITCODE
    }
    $LaunchArgs += @('--run', '--gameslot', $GameSlot)
}
& py -3 @LaunchArgs
exit $LASTEXITCODE
