# Duelo amistoso en Windows x64

El PvP experimental se activa por proceso con `ANIL_COOP_PVP=1`. Para
probarlo manualmente, ambos jugadores necesitan el mismo checkout y el build
compatible de Pokémon Añil. Usá dos perfiles aislados de prueba.

Desde PowerShell, en la raíz del checkout de cada equipo:

```powershell
$env:ANIL_COOP_PVP = '1'
py -3 -B tools/launch_menu.py
```

1. Cargá una partida y entrá al mapa. Creá una sala en **ESC → Online**
   con una IP privada de LAN o VPN. El invitado se une con esa IP y el código.
2. Seleccioná a tu compañero en **Jugadores conectados** y elegí
   **Desafiar a combate**. El invitado elige **Aceptar** o **Rechazar**.
3. Ambos agregan de uno a seis Pokémon aptos, ordenan la selección y
   confirman con **Confirmar** para quedar listos. El primer seleccionado sale primero. **Datos**
   abre el resumen nativo.
4. Elegí los ataques y cambios desde el menú de combate. El otro jugador
   elige las órdenes de su lado. **Rendirse** pide confirmación.
5. Tras el resultado, ambos vuelven al mapa. El duelo usa copias temporales
   y no concede recompensas. Guardá desde el mapa si querés continuar.

Para probar en una sola PC, prepará dos clientes con
`py -3 -B tools/h0.py prepare --source "<Añil original>" --clients 2` en un
checkout de prueba sin un perfil preparado. Iniciá dos veces el script con
`--client client01` y `--client client02`, respectivamente. El anfitrión
usa `127.0.0.1` como dirección de la sala.

## QA nativo reproducible

```powershell
py -3 -B -m unittest tests.test_pvp tests.test_coop_battle
py -3 -B -m tools.pvp_windows_qa --source "<Añil original>" --scenario host
```

El runner crea dos copias nuevas bajo `local/pvp-qa-…` con perfiles y
guardados desechables. Para repetir un caso, reemplazá `--source` por
`--qa-workspace "<ruta QA que imprimió el runner>"`. Usá ese directorio para
una sola corrida a la vez. Cada caso vuelve a crear las partidas de prueba.

Las órdenes se programan dentro del motor. Se arranca un proceso por perfil
para crear y guardar, otro para cargar y disputar el duelo, y otro para
recargar el guardado posterior. Los perfiles QA guardan el informe JSON,
logs y capturas del combate y del selector. El servidor comprueba el estado
de ambos motores al final de cada ronda y en el resultado.

| Prueba | Escenarios |
| --- | --- |
| Victoria, rechazo, cambios y desconexión | `host`, `guest`, `decline`, `switch`, `both_switch`, `disconnect` |
| Mecánicas | `weather`, `status`, `freeze`, `priority`, `ability`, `ability_out`, `form`, `draw` |
| Partidas y guardados | `restart`, `random`, `random_both`, `nuzlocke`, `randomlocke` |
| Red y espera | `wait`, `silent`, `selection_disconnect`, `animation_disconnect`, `exit` |
| Regresión de historia cooperativa | `brock` |

Las pruebas dirigidas se ejecutaron con dos instancias nativas de Añil v4.14
en Windows x64 y un servidor local:

- Lluvia, sol, arena y nieve, junto con parálisis, quemadura, veneno, sueño
  y daño residual de `FROSTBITE`, la variante de congelación de esta versión.
- Ataque Rápido, Protección, Vuelo, Gruñido, cambios simultáneos y
  sustitución obligatoria con el menú nativo. Baya Aranja, Llovizna y Sequía
  al entrar, Regeneración al salir, Rotom Calor y empate por Canto Mortal.
- Normal contra Normal, Randomizer o Nuzlocke, Randomizer contra Randomizer
  y Randomlocke contra Normal. Las partidas de Randomizer usaron tipos,
  habilidades, movimientos y objetos distintos a los del equipo Normal.
- Espera de 125 segundos con ambos clientes conectados. Cancelación ante
  pérdida de conexión en el selector o durante una animación, y ante un
  servidor que dejó de responder a los latidos.
- Brock 2v2 con el evento original. Ambos perfiles recibieron la medalla,
  el progreso y los objetos del evento y los conservaron tras recargar.

La comparación de partidas verifica equipo, dinero, medallas, inventario,
flags de historia y datos de desafío. También comprueba que el archivo
previo al duelo conserve el mismo hash.

## Alcance experimental

El duelo usa una arena inicial neutra, el orden espejado de Cable Club y
semillas acordadas por el servidor. Los estados divergentes cancelan el
duelo. La bolsa y las transformaciones de combate quedan deshabilitadas.
Los Pokémon cuyo snapshot no reproduce sus atributos se rechazan antes de
empezar. Las pruebas dirigidas cubren casos representativos. Quedan por
probar otras formas, habilidades y movimientos de varios turnos, y una
sesión humana por LAN o VPN, incluida la interacción con
menús, mensajes y controles de combate. La recarga automatizada usa el
backend del launcher para abrir procesos nuevos de juego.

Al integrar intercambios, revisar `src/game/coop.rb`, donde ambos flujos
comparten la recepción de eventos de red, y `src/game/coop_pvp.rb`, que
consume snapshots de equipos y verifica transacciones pendientes antes del
duelo. Esta ronda de estabilización no cambió el servidor, los snapshots
compartidos ni el menú Online.
