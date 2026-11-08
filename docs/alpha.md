# Alfa experimental para dos amigos

Cada uno conserva historia, equipo, bolsa y guardado. Exploración compartida,
salvajes independientes y 2v2 contra un único entrenador ordinario, con hasta
3 Pokémon elegidos por persona. Solo los seleccionados reciben EXP/efectos;
la victoria y el dinero corresponden a quienes participaron.

## Iniciar

1. Cada PC necesita su propia instalación del mismo Pokémon Añil v4.14 (motor
   Essentials 21.1), Python 3.10+ y esta carpeta del mod. El juego no está incluido.
2. Windows x64: abrir `Jugar-Coop.cmd`. Linux Mint: `./jugar-coop.sh` (Wine instalado).
3. La primera vez, elegir la carpeta original en la ventana del sistema: el
   lanzador crea una copia aislada. No hay que escribir comandos.
4. En el menú del juego, elegir **Multijugador → Crear partida** e indicar la IP
   que usarán ambos: `100.64–100.127.x.x` (Tailscale), `25.x.x.x` (Hamachi) o la IP LAN.
   El valor sugerido puede ser la IP LAN: reemplazarlo si usan una VPN. Compartir
   esa IP y el código de 12 caracteres mostrado. No hay clave adicional.
5. El amigo elige **Multijugador → Unirse a un amigo** e ingresa IP y código.
   Permitir TCP 17641 en el firewall
   solo para esa red privada. No abrir puertos del router ni usar una IP pública.
6. Ambos regresan al menú principal y eligen **Continuar** o **Partida Nueva**.
   Guardar normalmente antes de cerrar; cada partida sigue en su copia.

## Combatir

Hablar con el mismo entrenador pendiente en ambas aventuras. Elegir 1–3 Pokémon
en orden, confirmar la selección y marcarse listo. El iniciador confirma los
listos. El invitado entra automáticamente. Cada ventana usa los controles normales
para su Pokémon, objetivos y reservas propias. «Combatir solo» mantiene el flujo
individual original. Los demás jugadores pueden seguir explorando.

## Comprobación manual de movimiento y objetivos

Con dos PC en la misma sala, caminá, corré, detenete, girá y cambiá de mapa
alternadamente. El otro jugador debe verse desplazarse entre casillas sin saltos;
al cambiar de mapa, su sprite debe desaparecer y reaparecer en el mapa correcto.
Contra un NPC ordinario, probá un movimiento que se aplique automáticamente al
usuario o a un lado (por ejemplo, Salpicadura), luego ataques con objetivo
elegido y un turno tras debilitar o sustituir un Pokémon. Ambos deben terminar
el combate y volver al mapa conectados. Si aparece «illegal target», guardá
`coop.log` de ambos perfiles aislados y anotá movimiento, turno y objetivo;
el log incluye los índices y la regla de objetivo, sin la clave de conexión.

## Alcance que falta comprobar

Se probaron motores reales bajo Wine con decisiones programadas. Falta una partida
completa controlada por dos humanos, dos computadoras físicas y Windows nativo.
No se garantiza cualquier evento de historia/gimnasio: el adaptador cubre NPC
ordinarios `trainer(n)`, un entrenador y hasta seis enemigos. Entrenadores con
objetos de bolsa y encuentros especiales requieren combatir individualmente.
La bolsa y las mecánicas especiales del combate cooperativo están limitadas;
la evolución cooperativa todavía no está habilitada. No hay 3v3 ni combates de
cuatro jugadores. Una desconexión antes del resultado aborta sin aplicar victoria;
la recuperación tras caída del servidor durante la confirmación final sigue pendiente.
Usar partidas de prueba para esta alfa. La instalación original permanece intacta.
