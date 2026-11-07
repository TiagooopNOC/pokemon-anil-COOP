# Pokémon Añil Co-op — alfa experimental para dos amigos

Exploración compartida, salvajes individuales y combate 2v2 contra entrenadores
ordinarios, con 1–3 Pokémon propios por jugador. La historia, los guardados y las
recompensas de cada participante permanecen individuales. Probado con motores
reales bajo Wine y órdenes programadas; faltan controles humanos de punta a punta,
dos computadoras físicas y Windows nativo.

**Empezar:** `Jugar-Coop.cmd` en Windows x64 o `./jugar-coop.sh` en Linux Mint.
El asistente prepara una copia y permite crear/unirse por LAN o VPN privada.
Requisitos, pasos y límites: [guía breve de la alfa](docs/alpha.md).
Para generar el ZIP sin juego ni guardados: `python3 -B tools/h0.py package --alpha`.
La exploración admite hasta cuatro clientes; los combates cooperativos solo dos.

## Probar en Linux Mint

Usá las copias aisladas ya preparadas. Desde la raíz de `anil-coop`, instalá o
actualizá el overlay propio en ellas (no toca el original):

```sh
python3 -B tools/install_presence.py --clients client01 client02 client03 client04
```

Abrí dos terminales. En la primera iniciá el servidor local; dejalo abierto:

```sh
python3 -B src/server/session_server.py --port 17641
```

En la segunda lanzá los clientes deseados. Para dos jugadores:

```sh
python3 -B tools/wine_smoke.py --clients client01 client02 --seconds 600 \
  --gameslot ../coop-anything/tools/gameslot/gameslot.py \
  --session ANIL01 --port 17641 --host-client client01
```

Para tres o cuatro, agregá `client03` y `client04` a `--clients`. Entrá primero
al mapa con `client01` para crear la sesión; después cargá o creá las demás
partidas. Los clientes se conectan desde el juego cuando llegan al mapa. Hacé
clic en cada ventana para controlarla. El lanzador cierra sus procesos al terminar
`--seconds` o cuando se cierran las ventanas; detené el servidor con Ctrl+C.
Si repetís la sesión sin reiniciar el servidor, elegí otro código `--session`.
Los guardados, logs y capturas de prueba permanecen en `local/`.

## Entorno y preparación

Infraestructura de desarrollo para Windows x64 desde Linux Mint. Se preparan de
uno a cuatro clientes independientes, un preload de aislamiento de guardados,
verificaciones de integridad y herramientas portables.

El repositorio contiene el mod, herramientas y GameSlot bajo licencia MIT. El juego,
sus plugins, las copias de prueba, los guardados y los informes privados quedan
fuera de Git, dentro de `local/`. No se distribuye el juego ni VMS.

## Uso

Requiere Python 3.10 o posterior, sin dependencias de pip. Ejecutar desde este
repositorio; utilizar una instalación propia del build identificado en
`config/build.json`. No ejecutar el juego original para probar el mod.

```sh
python3 -B tools/h0.py doctor
python3 -B -m unittest discover -s tests -v
python3 -B tools/h0.py prepare --source "<carpeta original del juego>" --clients 4
python3 -B tools/h0.py verify
python3 -B tools/h0.py launch --clients client01 client02 client03 client04
python3 -B tools/h0.py package
```

`prepare` se ejecuta una sola vez: rechaza sobrescribir clientes existentes.
`launch` sin `--run` **solo muestra un plan**. No abre el juego ni sockets.
`package` crea un ZIP de herramientas propias. El prototipo requiere una copia
local del juego por computadora y un servidor en una IP privada de LAN/VPN.

En Windows usar `py -3` en lugar de `python3`. GameSlot revisado está incluido en
`vendor/gameslot/`. Los comandos de arriba son herramientas de desarrollo;
para jugar usar el asistente y la guía de la alfa.

## Estado y documentos

- [Resultados reales y bloqueos](docs/validation.md).
- [Reglas funcionales, incluidos duplicados enemigos](docs/requirements.md).
- [Arquitectura y contratos para los próximos hitos](docs/architecture.md).
- [Procedimiento de preparación, Windows y guardados](docs/hito-0.md).
- [Dependencias, licencias y evaluación de VMS](docs/third-party.md).

El arranque del preload y el ciclo guardar/cerrar/cargar se comprobaron bajo Wine.
Dos copias crearon guardados privados distintos. La integración visual de hasta
cuatro clientes se comprobó bajo Wine. La conexión por IP privada se comprobó
con dos juegos en una computadora; faltan las pruebas entre dos computadoras y
en Windows x64 nativo.
