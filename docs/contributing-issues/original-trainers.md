# [Compatibilidad] Validar entrenadores NPC originales y victorias individuales

Base: `main` en `491ddbf` o posterior. Proyecto experimental para dos jugadores; desarrollo Linux Mint, destino Windows x64. Guía de ejecución: [docs/alpha.md](https://github.com/TiagooopNOC/pokemon-anil-COOP/blob/main/docs/alpha.md).

Usar una instalación propia y copias/perfiles aislados. No adjuntar juego, assets, guardados, claves de sesión, IP privadas ni rutas con nombres personales. No abrir puertos públicos. Distinguir pruebas humanas, motores reales con órdenes programadas y simulaciones.

## Contexto
Se probó un evento QA con intérprete nativo y equipo real de Azul: victoria, EXP/dinero y marca local. Esto no demuestra compatibilidad con los eventos de los mapas originales.

## Alcance
Empezar por un NPC ordinario `trainer(n)`, un entrenador y sin objetos de bolsa. Anotar mapa/NPC y condiciones para reproducir. Probar un enemigo (duplicación) y un equipo con varios enemigos cuando sea accesible. No modificar mapas originales ni sincronizar historia.

## Criterios de aceptación
- [ ] Ambos jugadores interactúan con el mismo NPC y entran al 2v2.
- [ ] Victoria y recompensas se aplican una sola vez a cada participante.
- [ ] Un jugador conectado que no participa conserva su NPC pendiente y progreso intacto, si se dispone de ese cliente de observación.
- [ ] Los participantes guardan/recargan sin repetir premios ni quedar atrapados en el evento.
- [ ] El combate individual del NPC sigue disponible.

Marcar por separado lo no probado. No generalizar el resultado a gimnasios, rivales de historia o encuentros especiales.
