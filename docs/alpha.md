# Alfa experimental para dos amigos

Cada uno conserva historia, equipo, bolsa y guardado. Exploración compartida,
salvajes independientes y 2v2 contra un único entrenador ordinario, con hasta
3 Pokémon elegidos por persona. Solo los seleccionados reciben EXP/efectos;
la victoria y el dinero corresponden a quienes participaron.

## Iniciar

1. Cada PC necesita su propia instalación del mismo Pokémon Añil v4.14 (motor
   Essentials 21.1), Python 3.10+ y esta carpeta del mod. El juego no está incluido.
2. Windows x64: abrir `Jugar-Coop.cmd`. Linux Mint: `./jugar-coop.sh` (Wine instalado).
3. La primera vez, elegir la carpeta original en la ventana del sistema; el lanzador
   crea una copia aislada. No hace falta usar la terminal.
4. En la pantalla principal del juego elegir **Multijugador → Crear partida**.
   Elegir la IP privada si aparecen varias; compartir la IP y el código de 12 caracteres.
5. El amigo elige **Multijugador → Unirse a un amigo** e ingresa IP y código.
   Permitir TCP 17641 en el firewall
   solo para esa red privada. No abrir puertos del router ni usar una IP pública.
6. Ambos vuelven al menú principal y eligen **Continuar** o **Partida Nueva**.
   Pueden revisar estado/jugadores desde Multijugador antes de cargar. Guardar
   normalmente antes de cerrar; el lanzador nunca adopta la partida del amigo.

## Combatir

Hablar con el mismo entrenador pendiente en ambas aventuras. Elegir 1–3 Pokémon
en orden, confirmar la selección y marcarse listo. El iniciador confirma los
listos. El invitado entra automáticamente. Cada ventana usa los controles normales
para su Pokémon, objetivos y reservas propias. «Combatir solo» mantiene el flujo
individual original. Los demás jugadores pueden seguir explorando.

## Alcance que falta comprobar

Se probaron motores reales bajo Wine con decisiones programadas. Falta una partida
completa controlada por dos humanos, dos computadoras físicas y Windows nativo.
El menú multijugador y su auxiliar local también requieren esa prueba manual.
No se garantiza cualquier evento de historia/gimnasio: el adaptador cubre NPC
ordinarios `trainer(n)`, un entrenador y hasta seis enemigos. Entrenadores con
objetos de bolsa y encuentros especiales requieren combatir individualmente.
La bolsa y las mecánicas especiales del combate cooperativo están limitadas;
la evolución cooperativa todavía no está habilitada. No hay 3v3 ni combates de
cuatro jugadores. Una desconexión antes del resultado aborta sin aplicar victoria;
la recuperación tras caída del servidor durante la confirmación final sigue pendiente.
Usar partidas de prueba para esta alfa. La instalación original permanece intacta.

## Prueba breve del nuevo menú

En dos PCs con Añil y Python 3.10+ abrí `Jugar-Coop.cmd`. En cada una elegí la
carpeta del juego solo la primera vez. El anfitrión va a **Multijugador → Crear
partida**; si tiene varias direcciones, elige la IP de LAN/Tailscale/Hamachi.
Le envía esa IP y el código de 12 caracteres al amigo. El amigo entra en
**Multijugador → Unirse a un amigo**, ingresa ambos datos y verifica que aparezcan
dos jugadores. Cada uno pulsa **Cargar partida** y luego **Continuar**.
Intentá volver al menú de multijugador antes de cargar, desconectar y reconectar
sin cerrar el juego. Si falla, anotá el mensaje exacto, el sistema y el commit;
no compartas claves, IP privadas ni guardados públicamente.
