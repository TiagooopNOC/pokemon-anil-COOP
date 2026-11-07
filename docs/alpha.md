# Alfa experimental para dos amigos

Cada uno conserva historia, equipo, bolsa y guardado. Exploración compartida,
salvajes independientes y 2v2 contra un único entrenador ordinario, con hasta
3 Pokémon elegidos por persona. Solo los seleccionados reciben EXP/efectos;
la victoria y el dinero corresponden a quienes participaron.

## Iniciar

1. Cada PC necesita su propia instalación del mismo Pokémon Añil v4.14 (motor
   Essentials 21.1), Python 3.10+ y esta carpeta del mod. El juego no está incluido.
2. Windows x64: abrir `Jugar-Coop.cmd`. Linux Mint: `./jugar-coop.sh` (Wine instalado).
3. La primera vez, indicar la carpeta original: el lanzador crea una copia aislada.
   Después elegir el perfil. Crear/cargar la partida desde esa copia.
4. Estar en la misma LAN o VPN privada. El anfitrión elige **Crear**, introduce su
   IP privada y un código. Comparte IP, código y la clave que aparece en su terminal.
5. El amigo elige **Unirme** con esos mismos datos. Permitir TCP 17641 en el firewall
   solo para esa red privada. No abrir puertos del router ni usar una IP pública.
6. El anfitrión mantiene abierta su sesión. El juego no tiene límite de diez minutos.
   Guardar normalmente antes de cerrar; el lanzador nunca adopta la partida del amigo.

## Combatir

Hablar con el mismo entrenador pendiente en ambas aventuras. Elegir 1–3 Pokémon
en orden, confirmar la selección y marcarse listo. El iniciador confirma los
listos. El invitado entra automáticamente. Cada ventana usa los controles normales
para su Pokémon, objetivos y reservas propias. «Combatir solo» mantiene el flujo
individual original. Los demás jugadores pueden seguir explorando.

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
