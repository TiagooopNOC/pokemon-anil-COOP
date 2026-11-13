# Launcher de Pokémon Añil Co-op para Windows x64

## Instalar y jugar

1. Extraé todo `AnilCoop-Launcher-win-x64.zip` y abrí `AnilCoop-Launcher.exe`.
2. Elegí la carpeta de tu Pokémon Añil v4.14 que contiene `Game.exe`.
3. La barra muestra los archivos procesados y el porcentaje de la etapa actual.
   Cuando aparezca **Listo para jugar**, presioná **JUGAR**.
4. Cargá o empezá una partida. Usá **ESC → Online** para crear una sala o unirte
   por LAN o VPN privada. Podés minimizar el launcher mientras jugás.

El ZIP incluye el runtime de Python, Tcl/Tk y el mod. Cada jugador aporta su propia
instalación original. Podés crear un acceso directo desde el menú contextual del
EXE con **Enviar a → Escritorio (crear acceso directo)**.

La copia privada se guarda en `%LOCALAPPDATA%\AnilCoop\local` y la partida en
`clients\client01\profile\saves` dentro de esa carpeta. Para actualizar el launcher,
extraé el ZIP nuevo completo. Al iniciar el juego se comprueba y aplica el overlay
del paquete. Los perfiles del asistente de desarrollo `Jugar-Coop.cmd` viven en el
`local/` del repositorio, separado del perfil del launcher.

Si se interrumpe la preparación, volvé a abrir el launcher y elegí el original.
El instalador vuelve a preparar la copia temporal y conserva los perfiles
publicados. Si detecta partidas en una preparación interrumpida, conserva también
esa carpeta. Los detalles de los errores quedan en
`%LOCALAPPDATA%\AnilCoop\launcher.log`.

## Compilar y distribuir

Desde la raíz del repositorio en Windows x64, con CPython 3.12 x64 y Tcl/Tk
instalados para la compilación:

```powershell
py -3.12 -m venv .venv
./.venv/Scripts/python.exe -m pip install -r packaging/windows/launcher-requirements.txt
./packaging/windows/Build-Launcher.ps1 -Python ./.venv/Scripts/python.exe
```

Distribuí `dist/windows/AnilCoop-Launcher-win-x64.zip` completo. Es un paquete
PyInstaller de carpeta única y subsistema gráfico. El EXE carga el runtime y
los archivos del mod desde `_internal`. El script imprime el SHA-256 del ZIP.
El paquete se compila desde una lista explícita de recursos del mod.
[Documentación de PyInstaller](https://pyinstaller.org/en/stable/usage.html).

## Arte del launcher

El menú clásico combina una cabecera azul, un paisaje diurno en pixel art
y un panel de comandos. La escena mantiene su proporción al cambiar el tamaño
de la ventana. El logo proporcionado para el proyecto se incluye como
`assets/windows-launcher/anil-coop.ico` y se usa en la ventana y el ejecutable.

## Integración

- `tools/h0.py` sigue siendo responsable del manifiesto, las copias físicas, la
  verificación, el perfil privado y el bloqueo por perfil durante el juego. El
  launcher agrega callbacks de progreso y usa el mismo formato de `workspace.json`.
- `tools/install_presence.py` actualiza y verifica el overlay bajo el bloqueo
  del perfil al jugar. Los archivos se reemplazan individualmente de forma atómica.
- `tools/menu_control.py` mantiene el auxiliar durante la vida del juego. En el
  paquete el servidor de sala arranca en modo interno del mismo EXE. Al salir se
  cierran la interfaz de control, el puente y el proceso del servidor.
- La preparación se hace en `setup-pending` bajo un bloqueo de Windows. Se publica
  el árbol privado completo con un renombrado en el mismo volumen, después de
  verificar la copia y el overlay. El arranque posterior revisa los archivos
  críticos y el aislamiento del perfil sin volver a copiar.
