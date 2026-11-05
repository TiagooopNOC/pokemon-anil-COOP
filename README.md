# Pokémon Añil Co-op — Hito 0

Infraestructura de desarrollo para Windows x64 desde Linux Mint. **Todavía no hay
multijugador.** Se preparan de uno a cuatro clientes independientes, un preload de
aislamiento de guardados, verificaciones de integridad y herramientas portables.

El repositorio contiene únicamente herramientas y documentación propias. El juego,
sus plugins, las copias de prueba, los guardados y los informes privados quedan
fuera de Git, dentro de `local/`. No se distribuye el juego ni VMS.

## Uso

Requiere Python 3.10 o posterior, sin dependencias de pip. Ejecutar desde este
repositorio; utilizar una instalación propia del build identificado en
`config/build.json`. No ejecutar el juego original para probar el mod.

```sh
python3 -B tools/h0.py doctor
python3 -B -m unittest discover -s tests -v
python3 -B tools/h0.py prepare --source "<carpeta original del juego>" --clients 4
python3 -B tools/h0.py verify
python3 -B tools/h0.py launch --clients client01 client02 client03 client04
python3 -B tools/h0.py package
```

`prepare` se ejecuta una sola vez: rechaza sobrescribir clientes existentes.
`launch` sin `--run` **solo muestra un plan**. No abre el juego ni sockets.
`package` crea un ZIP de herramientas propias; no es un mod cooperativo jugable.

En Windows usar `py -3` en lugar de `python3` o los scripts PowerShell de
`packaging/windows/`. La ejecución nativa requiere el `gameslot.py` revisado de
Co-op Anything. Ver instrucciones y límites en [Hito 0](docs/hito-0.md).

## Estado y documentos

- [Resultados reales y bloqueos](docs/validation.md).
- [Reglas funcionales, incluidos duplicados enemigos](docs/requirements.md).
- [Arquitectura y contratos para los próximos hitos](docs/architecture.md).
- [Procedimiento de preparación, Windows y guardados](docs/hito-0.md).
- [Dependencias, licencias y evaluación de VMS](docs/third-party.md).

El arranque del preload y el ciclo guardar/cerrar/cargar en el runtime real siguen
pendientes. No declarar cerrado ese control ni avanzar a pruebas de conexión antes
de validarlo. El trabajo de este repositorio se limita al Hito 0.
