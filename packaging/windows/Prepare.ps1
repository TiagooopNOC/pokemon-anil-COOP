param(
    [Parameter(Mandatory=$true)][string]$Source,
    [ValidateRange(1,4)][int]$Clients = 4
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& py -3 "$Root/tools/h0.py" prepare --source $Source --clients $Clients
exit $LASTEXITCODE
