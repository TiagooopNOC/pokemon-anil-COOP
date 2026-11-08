# [Pruebas] Validar la alfa en Windows x64 entre dos computadoras

Base: `main` en `491ddbf` o posterior. Proyecto experimental para dos jugadores; desarrollo Linux Mint, destino Windows x64. Guía de ejecución: [docs/alpha.md](https://github.com/TiagooopNOC/pokemon-anil-COOP/blob/main/docs/alpha.md).

Usar una instalación propia y copias/perfiles aislados. No adjuntar juego, assets, guardados, claves de sesión, IP privadas ni rutas con nombres personales. No abrir puertos públicos. Distinguir pruebas humanas, motores reales con órdenes programadas y simulaciones.

## Objetivo
Comprobar el recorrido de dos amigos en Windows nativo por LAN y, por separado, por VPN privada. Hasta ahora hay pruebas de motores reales bajo Wine; no se ha validado este recorrido en dos PCs.

## Pasos
1. Preparar una copia en cada PC con `Jugar-Coop.cmd`, Python 3.10+ y el build compatible de Añil.
2. Desde «Multijugador», crear/unirse compartiendo IP privada y código de sala;
   el flujo anterior también requería una clave separada.
3. Cargar partidas independientes y comprobar movimiento en el mismo mapa.
4. Combatir juntos contra un entrenador ordinario pendiente en ambas aventuras.
5. Volver al mapa, guardar y recargar cada copia.

## Criterios de aceptación
- [ ] Conexión y movimiento bidireccional en dos PCs Windows, sin Wine.
- [ ] Combate completo y regreso conectado.
- [ ] Equipos, dinero y guardados independientes después de recargar.
- [ ] Informe con versiones, commit, LAN/VPN, pasos y fallos reproducibles; no declarar VPN probada si solo se probó LAN.

No requiere programar. Un resultado negativo bien reproducido también sirve.
