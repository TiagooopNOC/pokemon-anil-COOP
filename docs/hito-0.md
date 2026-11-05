# Operación del entorno Hito 0

## Estructura

```text
anil-coop/
  config/build.json           identidad y hashes críticos admitidos
  src/bootstrap/isolate.rb   aislamiento de guardados de prueba
  tools/h0.py                prepare, verify, doctor, launch, package
  tests/test_h0.py           regresiones de seguridad con fixtures sintéticos
  docs/                     requisitos, decisiones, resultados y dependencias
  packaging/windows/        entradas PowerShell para preparar y lanzar
  local/                    privado e ignorado por Git
    original.json           ruta privada + SHA-256 y tamaño de cada archivo original
    workspace.json          identificadores y overlays esperados
    clients/client01..04/
      game/                 copia física independiente
      profile/saves/        exclusivamente partidas desechables de prueba
      profile/logs/
      profile/appdata/
      profile/localappdata/
      profile/mkxp.original.json
      wine-prefix/          directorio reservado, Wine todavía no inicializado
    reports/                resultados de comandos realmente ejecutados
  dist/                     paquetes de herramientas; ignorado por Git
```

## Preparar y verificar

Desde la raíz de `anil-coop`, Python 3.10+:

```sh
python3 -B tools/h0.py prepare --source "<instalación original>" --clients 4
python3 -B tools/h0.py verify
python3 -B tools/h0.py doctor
python3 -B -m unittest discover -s tests -v
```

No se requiere Ruby del sistema para preparar. El juego usa su DLL Ruby Windows.
La verificación completa lee los hashes del original y de las cuatro copias;
puede tardar, ya que comprueba todos los archivos, no solo el ejecutable.

`prepare` no acepta otro build, carpetas anidadas, enlaces simbólicos/junctions,
scripts de preload inesperados o clientes ya existentes. Copia con `copy2`, nunca
hardlinks. Filtra nombres de guardados y verifica que el original no cambió durante
la copia. Un staging `.prepare-*` interrumpido se conserva y bloquea la repetición;
revisar antes de archivarlo, nunca borrar a ciegas. No existe un comando reset que
pueda borrar saves. Un `original.json` existente se verifica y no se sobrescribe.

El manifiesto y el mkxp de respaldo son evidencia local. El overlay añade dos
archivos en CoopDev y cambia solamente la configuración mkxp de cada copia.
No ejecutar `scripts_extract.rb`, recompilar plugins ni actualizar el juego de
prueba automáticamente. El verificador estricto rechaza modificaciones nuevas del
directorio game; si el runtime crea un log allí, revisarlo antes de aprobarlo como
salida permitida, no renovar la baseline a ciegas.

## Windows x64

En una máquina Windows, copiar **el repositorio de herramientas**, no reutilizar un
workspace con rutas Linux. Proporcionar una instalación propia del mismo build y
preparar de nuevo allí. Se necesita Python 3.10+ con launcher `py`, PowerShell y
el checkout revisado de Co-op Anything para GameSlot. La disponibilidad local no
implica que esos componentes estén instalados en la máquina Windows de destino.

```powershell
py -3 tools/h0.py doctor
py -3 -m unittest discover -s tests -v
./packaging/windows/Prepare.ps1 -Source 'D:/Juegos/Pokemon Anil' -Clients 4
py -3 tools/h0.py verify
./packaging/windows/Launch.ps1 -Clients client01,client02,client03,client04
# La línea anterior solo imprime el plan. Ejecutar realmente, en Windows:
./packaging/windows/Launch.ps1 -Clients client01 -Run -GameSlot 'D:/dev/coop-anything/tools/gameslot/gameslot.py'
```

El lanzador verifica primero la integridad, reserva slots, inicia hijos propios y
registra sus PID. Al terminar requiere exit code cero y evidencia nueva del preload.
Esto solo acredita `BOOTSTRAP_OBSERVED`, **no** guardar/cargar ni cooperativo.
No abrir Game.exe manualmente: el preload exige el identificador del lanzador.
Una evidencia bootstrap anterior bloquea otra prueba hasta archivarla explícitamente.
No cambia la política global de PowerShell ni instala componentes automáticamente.

## Linux Mint / Wine

Wine 9.0 se instaló posteriormente en este Linux Mint. Se inicializaron prefijos
privados de client01 y client02 y se ejecutaron esas copias con
`tools/wine_smoke.py`. Cada ejecución usa el plan de `tools/h0.py`, comprueba la
integridad, adquiere GameSlot y limita la duración. La sandbox de Codex produjo
`Bad system call` con Wine; las ejecuciones exitosas usaron permiso de sandbox
escalado, sin privilegios administrativos ni instalación nueva en esta sesión.
`launch --run` sigue limitado al objetivo Windows nativo; el runner Wine es una
herramienta de prueba separada, con limpieza de su prefijo privado.

```sh
python3 -B tools/wine_smoke.py --client client01 --seconds 120 \
  --gameslot ../coop-anything/tools/gameslot/gameslot.py
```

Ese runner comprueba arranque/preload; crear y recargar una partida requiere
interacción con la interfaz y evidencia separada. Cada nueva ejecución exige
archivar el marcador de preload anterior en el perfil privado.
QEMU instalado no demuestra que exista una VM Windows, imagen o licencia disponible.

No se necesita MinGW ni compilar mkxp para preparar este overlay Ruby. Ruby del
sistema sería útil para lint, pero no sustituye probar la DLL integrada de Windows.
No se hizo instalación global alguna.

## Comprobación de runtime

Antes de dar el aislamiento por validado en ejecución:

1. Arrancar un cliente Windows mediante el lanzador; comprobar nueva evidencia
   `profile/bootstrap-loaded.txt` y que apunta a su `profile/saves`.
2. Instrumentar una comprobación dentro del juego de SaveData::FILE_PATH y
   Multi Save::SAVE_DIR. No basta con que exista el marcador del preload.
3. Crear una partida desechable, guardar, cerrar y volver a cargar. Confirmar
   archivos solo en ese perfil y ninguna modificación en otros perfiles/original.
4. Repetir con cuatro clientes simultáneos y personajes de prueba distintos;
   verificar persistencia independiente y cierres limpios.
5. Mantener automatizables estas comprobaciones mediante el futuro adaptador/bot;
   no declarar pruebas de sincronización antes de implementar sesiones.

Se verificó bajo Wine: preload, guardado, cierre y recarga de client01; creación
de guardado de client02 sin cambiar el hash del primero. El verificador estático
`verify` indica `SEE_SEPARATE_RUNTIME_REPORTS` porque no observa la interfaz del
juego; los resultados de ejecución están en `local/reports/`. Falta repetir en
Windows x64 nativo, probar varios clientes simultáneos y automatizar el flujo de
interfaz. El Hito 1 no comenzó.
