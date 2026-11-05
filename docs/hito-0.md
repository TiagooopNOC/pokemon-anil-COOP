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

Wine, wine64 y winepath no estaban disponibles al preparar Hito 0. Por eso no se
inicializaron prefijos ni se ejecutó Game.exe. Hay cuatro directorios reservados,
plan de comando, cwd, variables y rutas independientes. `launch --run` está limitado
al objetivo Windows nativo: antes de habilitarlo en Wine hay que instalar/configurar
Wine con autorización y validar el manejo de slots/PID y conversión de rutas.
QEMU instalado no demuestra que exista una VM Windows, imagen o licencia disponible.

No se necesita MinGW ni compilar mkxp para preparar este overlay Ruby. Ruby del
sistema sería útil para lint, pero no sustituye probar la DLL integrada de Windows.
No se hizo instalación global alguna.

## Comprobación de runtime pendiente

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

Estas pruebas aún no se ejecutaron. El Hito 1 no comenzó. La infraestructura y
los contratos están listos para continuarlo una vez atendido el control de runtime.
