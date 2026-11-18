# Pokémon Añil Co-op

Mod experimental para explorar Pokémon Añil con amigos por LAN o VPN privada.
Podés ver a otros jugadores y sus Pokémon acompañantes, y combatir en equipo
contra entrenadores compatibles. Cada jugador conserva su propia historia,
equipo y partida.

## Jugar en Windows x64

Cada jugador necesita su propia instalación de **Pokémon Añil v4.14** y el
paquete `AnilCoop-Launcher-win-x64.zip`. El paquete incluye Python y el mod.
El juego original se consigue por separado.

1. Extraé el ZIP completo en una carpeta.
2. Abrí `AnilCoop-Launcher.exe`.
3. En el primer inicio, elegí la carpeta del juego original que contiene `Game.exe`.
4. Esperá a que termine la preparación. Cuando aparezca **Listo para jugar**,
   pulsá **JUGAR**.

El launcher prepara una copia aislada y muestra el progreso por archivo. En los
siguientes inicios podés pulsar **JUGAR** directamente. Las partidas de Co-op
quedan en `%LOCALAPPDATA%\AnilCoop\local\clients\client01\profile\saves`.

¿Tenés el código fuente de GitHub y necesitás el ZIP? La compilación genera
`dist/windows/AnilCoop-Launcher-win-x64.zip`. [Compilar el launcher y preparar el ZIP](docs/windows-launcher.md#compilar-y-distribuir).

## Jugar en Linux Mint

Con Wine, Python 3.10 o posterior y Tkinter instalados, abrí una terminal en
la carpeta del repositorio y ejecutá:

```sh
./jugar-coop.sh
```

La primera vez, elegí la carpeta de tu Pokémon Añil v4.14 para preparar la copia
aislada.

## Conectarte con amigos

1. En cada equipo, cargá una partida y entrá al mapa.
2. El anfitrión abre **ESC → Online → Crear sala** y elige su IP privada de LAN
   o VPN. Comparte esa IP y el código de sala.
3. Los invitados abren **ESC → Online → Unirse a un amigo** e ingresan la IP
   y el código.

La exploración admite hasta cuatro jugadores. Los combates cooperativos son 2v2,
con hasta tres Pokémon elegidos por persona. Usá partidas de prueba para esta
alfa. [Combates, controles de prueba y límites conocidos](docs/alpha.md#combatir).

## Desarrollo

Los comandos de desarrollo requieren Python 3.10 o posterior. En Windows, usá
`py -3` en lugar de `python3`. El [manifiesto de compatibilidad](config/build.json)
identifica el build de Añil y sus archivos críticos.

```sh
python3 -B tools/h0.py doctor
python3 -B -m unittest discover -s tests -v
```

- [Compilación, distribución y guardados del launcher de Windows](docs/windows-launcher.md)
- [Preparación de perfiles aislados y pruebas con Wine](docs/hito-0.md)
- [Conexión manual entre equipos para desarrollo](docs/connect.md)
- [Resultados de validación](docs/validation.md)
- [Arquitectura del mod](docs/architecture.md) y [requisitos funcionales](docs/requirements.md)
- [Dependencias y licencias de terceros](docs/third-party.md)
