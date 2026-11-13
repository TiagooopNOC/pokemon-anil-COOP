# Launcher de Pokémon Añil Co-op para Windows x64

## Instalar y jugar

1. Extraé todo `AnilCoop-Launcher-win-x64.zip` y abrí `AnilCoop-Launcher.exe`.
2. Elegí la carpeta de tu Pokémon Añil v4.14 que contiene `Game.exe`.
3. La barra muestra los archivos procesados y el porcentaje de la etapa actual.
   Cuando aparezca **Listo para jugar**, presioná **JUGAR**.
4. Cargá o empezá una partida. Usá **ESC → Online** para crear una sala o unirte
   por LAN o VPN privada. Podés minimizar el launcher mientras jugás.
5. Para un duelo 1v1, elegí **Jugadores conectados**, seleccioná a tu amigo
   y pulsá **Desafiar a combate**. Ambos deben usar la misma versión del mod.

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

## Importar una partida existente

1. Cerrá el juego de origen y completá la instalación de Co-op.
2. En el launcher, pulsá **Importar partida guardada**. Si existe
   `%APPDATA%\Pokemon Anil`, el asistente revisa esa carpeta. También podés
   elegir un archivo o una carpeta, por ejemplo `profile\saves` de otra copia Co-op.
3. Elegí una partida compatible y pulsá **Importar**. Ante un conflicto, podés
   elegir una ranura libre, cancelar o confirmar el reemplazo con respaldo.
4. Pulsá **JUGAR** y elegí la ranura importada en la pantalla de carga.
   Podés recorrer las ranuras con las flechas izquierda y derecha.

Se admiten `Partida N.rxdata`, `Auto 1.rxdata` a `Auto 3.rxdata`,
`BackupNNN.rxdata`, `Game.rxdata` y sus variantes `.bak`, siempre que tengan
una estructura reconocida y las versiones internas de la edición compatible
de Añil v4.14 (Essentials 21.1, versión de guardado 4.1.1). Se copian a una
ranura manual. Se rechazan otros nombres, estructuras, versiones y archivos
mayores de 32 MiB. El importador inspecciona Ruby Marshal sin instanciar sus
objetos. Importá partidas propias. [Formato Ruby Marshal](https://docs-origin.ruby-lang.org/en/master/language/marshal_rdoc.html).

La copia conserva los bytes originales y se verifica antes de publicarla.
Co-op usa la ranura del archivo al cargarlo para que el siguiente guardado
escriba en la ranura elegida. Si confirmás un reemplazo, el archivo anterior se
conserva en `profile\save-import-backups`. Podés recuperar el respaldo
seleccionándolo como archivo en el mismo asistente. El bloqueo del perfil impide
importar mientras esa copia Co-op está abierta. Si aparecen archivos de estado de
intercambio en el perfil, el asistente pausa la importación.

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
