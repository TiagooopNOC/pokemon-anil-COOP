param(
    [Parameter(Mandatory=$true)][string]$Source,
    [ValidateRange(1,4)][int]$Clients = 4
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& py -3 "$Root/tools/h0.py" prepare --source $Source --clients $Clients
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$Selected = 1..$Clients | ForEach-Object { 'client{0:D2}' -f $_ }
& py -3 "$Root/tools/install_presence.py" --clients @Selected
exit $LASTEXITCODE
