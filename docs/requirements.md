# Requisitos aceptados

Estado: especificación; ninguna mecánica cooperativa está implementada en Hito 0.

## Plataforma y propiedad

- Desarrollo en Linux Mint; distribución y validación definitiva en Windows x64.
- Sesiones por Internet de 1 a 4 jugadores en computadoras diferentes.
- Misma historia y campaña compartida; cada jugador conserva personaje, equipo,
  inventario, guardados y reglas individuales. Nunca sustituir la partida de un
  invitado por la del anfitrión ni adoptar automáticamente su identidad.
- Normal, Randomlocke y otras modalidades: compatibilidad por capacidad y reglas
  verificadas, no una promesa universal. Rechazar combinaciones incompatibles con
  una explicación antes de entrar en una batalla.
- Explorar juntos; encuentros salvajes individuales. Un combate salvaje no detiene
  a los demás. Cada jugador mantiene su propia aleatorización de salvajes y reglas
  de captura, muerte y restricciones de desafío.

## Encuentros de entrenadores

1. Detectar o hablar con un entrenador crea un encuentro pendiente identificado
   por campaña, mapa, evento, página y revisión de historia.
2. El iniciador espera; otros se incorporan hablando con el mismo entrenador.
3. Cada participante confirma preparación. Solo el iniciador puede comenzar con
   el subconjunto preparado; el roster se congela al comenzar.
4. Si nadie se incorpora, el iniciador puede dejar de esperar y combatir solo.
   Esto no permite cancelar o saltarse un combate obligatorio.
5. Los no participantes siguen explorando; no se admite incorporarse a una batalla
   iniciada. No reutilizar `$game_temp.waiting_trainer`, que ya tiene otro propósito
   en el juego original.
6. La victoria actualiza la campaña de forma coherente y exactamente una vez.
   Desconexiones, reintentos y reconexión no permiten duplicar recompensas.

| Participantes al iniciar | Formato |
| --- | --- |
| 1 | Original, sin cambios innecesarios |
| 2 | Un combate cooperativo 2v2 |
| 3 | Un combate cooperativo 3v3 con adaptaciones de Essentials |
| 4 | Dos batallas 2v2 simultáneas, con parejas distintas, asociadas al mismo encuentro |

No existe formato 4v4. En cuatro jugadores **ambas parejas deben ganar**. La pareja
que ganó conserva su resultado; solo reintenta la que perdió. No regenerar equipos,
repartir otra vez recompensas ni volver a ejecutar efectos de la pareja ganadora.
La política ante abandono definitivo debe resolverse antes de implementar ese hito;
no convertir silenciosamente una victoria parcial en una victoria completa.

## Duplicación mínima de enemigos

Esta regla reemplaza cualquier idea previa de inventar especies o refuerzos.

1. Generar el equipo efectivo del NPC, incluida su aleatorización, **primero**.
2. Distribuir sus Pokémon originales entre las posiciones y batallas necesarias.
3. Si faltan ocupantes para el formato, duplicar solo los necesarios. Conservar
   todas las reservas y la lógica de cambios. No eliminar originales para ajustar
   el tamaño del combate ni llenar indiscriminadamente cada reserva con clones.
4. Cada duplicado es una instancia independiente con PS y estados propios. Copia
   nivel, estadísticas efectivas, movimientos y PP, habilidad, tipos, naturaleza,
   IV/EV, objeto y las propiedades efectivas relevantes, incluidas extensiones.
   Clonar un objeto superficialmente o recrearlo solo por especie/nivel no sirve.
5. Si ya hay suficientes enemigos, no crear duplicados. Un equipo vacío o un
   encuentro especial incompatible requiere un adaptador o rechazo explícito.

Para encuentros ordinarios con `n >= 1` originales, los mínimos de enemigos totales
son 1, 2, 3 y 4 según el formato. En cuatro jugadores el mínimo son dos por pareja.
Distribuir primero los originales para cubrir esos mínimos y después las reservas.
Cantidad mínima total de duplicados: `max(0, mínimo - n)`. El orden de reparto y
selección de plantillas debe ser determinista y persistir en el plan del encuentro.

| Equipo original | Jugadores | Resultado requerido |
| --- | --- | --- |
| Un Pikachu | 1 | Combate original |
| Un Pikachu | 2 | Dos instancias de ese Pikachu |
| Un Pikachu | 3 | Tres instancias de ese Pikachu |
| Un Pikachu | 4 | Dos batallas, cada una con dos instancias de ese Pikachu |
| Tres Pokémon distintos | 4 | Repartir los tres originales y añadir un único duplicado |
| Seis Pokémon | 4 | Repartir los seis, con reservas; ningún duplicado |

En Randomlocke se duplica la instancia ya aleatorizada. No compartir ni reiniciar
el RNG global de cada jugador. La política exacta de generación de NPC al mezclar
modalidades debe definirse y negociarse; los encuentros salvajes siguen siendo
personales en cualquier caso.

Dinero, XP y recompensas deben calcularse con identidad del encuentro, participación
y procedencia del enemigo; la existencia de clones no habilita multiplicadores
automáticos. Las cantidades exactas de XP y dinero quedan pendientes de diseño y
pruebas de balance. Objetos únicos y efectos de historia se entregan mediante recibos
idempotentes. No implementar estas reglas todavía.

## Límites de Hito 0

Solo infraestructura, aislamiento, herramientas, documentación y pruebas locales.
No conexión de sesiones, campaña, lobby de NPC, combate cooperativo, nuevas especies,
servidores expuestos, migración de partidas ni publicación. Conservar Cable Club y
los demás plugins originales. No instalar paquetes globales ni tocar los originales.
