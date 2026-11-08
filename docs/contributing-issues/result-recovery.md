# [Netcode] Recuperar una desconexión durante la confirmación final del combate

Base: `main` en `491ddbf` o posterior. Proyecto experimental para dos jugadores; desarrollo Linux Mint, destino Windows x64. Guía de ejecución: [docs/alpha.md](https://github.com/TiagooopNOC/pokemon-anil-COOP/blob/main/docs/alpha.md).

Usar una instalación propia y copias/perfiles aislados. No adjuntar juego, assets, guardados, claves de sesión, IP privadas ni rutas con nombres personales. No abrir puertos públicos. Distinguir pruebas humanas, motores reales con órdenes programadas y simulaciones.

## Problema
Hay barreras de checksum, abortos de combate y recibos locales contra repetición. Falta recuperación durable si cae el servidor o un cliente durante la confirmación final: no asumir que ambos aplicaron el resultado.

## Punto de partida
`src/server/coop_battle.py`, `src/server/session_server.py`, `src/game/coop_battle.rb` y `src/game/coop_result.rb`.

## Trabajo propuesto
Definir y documentar brevemente estados de resultado pendiente/confirmado/aplicado y recuperación por identidad de combate y propietario. Implementar primero una prueba de fallo que reproduzca la ventana problemática, luego el cambio mínimo. No trasladar guardados completos ni objetos Ruby deserializados por red.

## Criterios de aceptación
- [ ] Inyectar caída antes/después de cada confirmación y aplicación local.
- [ ] Reintentos y mensajes duplicados no repiten EXP, dinero ni victoria.
- [ ] Un cliente rezagado recupera el resultado autorizado o queda explícitamente pendiente; nunca inventa victoria.
- [ ] Reiniciar servidor/cliente tiene un comportamiento comprobado y consistente.
- [ ] Se conservan validaciones de mensajes, checksums y propiedad individual.

Requiere experiencia con protocolos/transacciones. Sin campaña compartida ni migración de anfitrión en este issue.
