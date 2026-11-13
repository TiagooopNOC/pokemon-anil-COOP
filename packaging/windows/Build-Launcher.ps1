param(
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$dist = Join-Path $repo 'dist/windows'
$bundle = Join-Path $dist 'AnilCoop-Launcher'
$zip = Join-Path $dist 'AnilCoop-Launcher-win-x64.zip'

& $Python -c "import platform, struct, sys, tkinter; assert sys.platform == 'win32' and platform.machine().lower() in ('amd64', 'x86_64') and struct.calcsize('P') == 8, 'Use CPython Windows x64'; root = tkinter.Tk(); root.withdraw(); root.destroy()"
if ($LASTEXITCODE -ne 0) { throw 'Se necesita CPython Windows x64 con Tcl/Tk.' }

& $Python -m PyInstaller --clean --noconfirm --distpath $dist --workpath (Join-Path $dist 'build') (Join-Path $PSScriptRoot 'AnilCoop-Launcher.spec')
if ($LASTEXITCODE -ne 0) { throw 'Falló la compilación del launcher.' }

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LEEME.txt') -Destination $bundle
Compress-Archive -LiteralPath $bundle -DestinationPath $zip -Force
Get-FileHash -LiteralPath $zip -Algorithm SHA256
