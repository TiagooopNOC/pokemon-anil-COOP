# [Gameplay] Integrar evoluciones individuales después del combate cooperativo

Base: `main` en `491ddbf` o posterior. Proyecto experimental para dos jugadores; desarrollo Linux Mint, destino Windows x64. Guía de ejecución: [docs/alpha.md](https://github.com/TiagooopNOC/pokemon-anil-COOP/blob/main/docs/alpha.md).

Usar una instalación propia y copias/perfiles aislados. No adjuntar juego, assets, guardados, claves de sesión, IP privadas ni rutas con nombres personales. No abrir puertos públicos. Distinguir pruebas humanas, motores reales con órdenes programadas y simulaciones.

## Contexto
EXP, subidas de nivel, persistencia 3+3 y Repartir Exp. ya tienen pruebas específicas. `src/game/coop_evolution.rb` es trabajo preparatorio y todavía no está habilitado por el loader; no presentarlo como funcional.

## Alcance
Adaptar la escena original de evolución después de aplicar el resultado individual confirmado. Solo los Pokémon seleccionados y elegibles del propietario. Mantener conexión durante escena y aprendizaje de movimientos, permitir cancelación humana y conservar los no seleccionados.

## Criterios de aceptación
- [ ] Evolución por nivel de un participante sin evolucionar el equipo del otro.
- [ ] Aprendizaje/cancelación de movimientos y cancelación de evolución con controles normales.
- [ ] Guardado/recarga conserva resultado y no repite premios.
- [ ] Pokémon excluidos permanecen intactos.
- [ ] Desconexión durante la escena no corrompe el resultado ya acordado.
- [ ] Casos Nincada/Shedinja, Randomlocke y debilitados se adaptan con pruebas o quedan explícitamente fuera de alcance.

Reutilizar Essentials/Añil; no ejecutar indiscriminadamente hooks globales que alteren todo el equipo. No repetir la batería 3+3 salvo que el cambio afecte ese contrato.
