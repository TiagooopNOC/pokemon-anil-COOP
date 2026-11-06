# Prueba local del 2v2

Desde `anil-coop`, usando las copias aisladas ya preparadas `client03` y `client04`.
En una terminal:

```sh
python3 -B src/server/session_server.py --port 17643
```

En otra:

```sh
python3 -B tools/install_presence.py --clients client03 client04
python3 -B tools/wine_smoke.py --clients client03 client04 --seconds 600 \
  --gameslot ../coop-anything/tools/gameslot/gameslot.py \
  --session PRUEBA2 --port 17643 --host-client client03 --qa-trainer --qa-2v2
```

Cargá `Partida 1` en ambos. Hablá con el NPC de prueba de color diferente, junto
al punto de aparición, y marcá ambos como preparados. El iniciador confirma con
los listos; el invitado pulsa «Actualizar». Cada ventana controla su propio
Pokémon. Avanzá los textos como en el juego normal. Comprobá movimientos,
objetivos, sustituciones y regreso al mapa hasta ver moverse al compañero.
El lanzador cierra las copias a los diez minutos; cerralas antes normalmente y
usá Ctrl+C en la terminal del servidor al terminar.

**Alcance:** solo NPC de QA, equipos temporales y experiencia de demostración
por propietario tras la victoria. No se conserva esa experiencia, no se entrega
dinero ni se marca al entrenador de la campaña. Guardar durante el combate está
bloqueado; no uses este escenario como partida de campaña.

Para reproducir la comprobación programada, agregá al comando de lanzamiento
`--qa-battle-bot visual --qa-scenario rewards`. Carga las partidas aisladas sin
escribirlas, elige órdenes mediante el motor, verifica EXP/propiedad/repetición,
y produce un reporte privado en `local/reports/`. No valida la selección humana
de menús. `--qa-scenario disconnect` prueba la salida segura ante desconexión.
Windows nativo y juego entre dos computadoras siguen pendientes de validación.
