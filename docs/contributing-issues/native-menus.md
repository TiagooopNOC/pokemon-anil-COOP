# [Pruebas] Recorrer los menús normales del 2v2 con dos jugadores

Base: `main` en `491ddbf` o posterior. Proyecto experimental para dos jugadores; desarrollo Linux Mint, destino Windows x64. Guía de ejecución: [docs/alpha.md](https://github.com/TiagooopNOC/pokemon-anil-COOP/blob/main/docs/alpha.md).

Usar una instalación propia y copias/perfiles aislados. No adjuntar juego, assets, guardados, claves de sesión, IP privadas ni rutas con nombres personales. No abrir puertos públicos. Distinguir pruebas humanas, motores reales con órdenes programadas y simulaciones.

## Contexto
La victoria gráfica y el menú de espera se probaron con órdenes programadas. Reservas/datos permanecieron abiertos más de 35 s y cerraron ante desconexión. Falta navegación humana completa.

## Alcance
Elegir 1–3 Pokémon personales, quitar/reordenar la selección, preparar ambos jugadores, iniciar sin pulsar Actualizar en el invitado, elegir movimientos/objetivos, cancelar submenús, consultar datos, cambiar voluntariamente y sustituir debilitados.

## Criterios de aceptación
- [ ] Cada jugador solo controla su Pokémon y reservas.
- [ ] Los menús responden y no pierden conexión por una consulta de más de 30 s.
- [ ] Una orden no resuelve el turno antes de recibir la otra.
- [ ] Cancelar un submenú no registra una orden accidental.
- [ ] Batalla finaliza y ambos vuelven al mapa con controles normales.

Informar botón/menú, propietario, turno y mensaje exacto ante fallos. Bolsa y mecánicas especiales siguen limitadas; no ampliar alcance aquí.
