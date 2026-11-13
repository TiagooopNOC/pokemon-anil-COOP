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
guardados desechables. Las órdenes de prueba son programadas dentro del
motor. Los otros escenarios son `guest`, `decline`, `switch` y
`disconnect`. Cada corrida deja sus logs y resultados en los perfiles QA.

## Alcance experimental

El duelo usa una arena inicial neutra, el orden espejado de Cable Club y
semillas acordadas por el servidor. Los estados divergentes cancelan el
duelo. La bolsa y las transformaciones de combate quedan deshabilitadas.
Los Pokémon cuyo snapshot no reproduce sus atributos se rechazan. La
validación de la matriz completa de movimientos, climas, formas especiales
y partidas con Randomizer o Randomlocke sigue pendiente. El guardado y los
efectos persistentes del juego permanecen fuera de la sincronización.
