# Resultados de Hito 0

Fecha: 2026-11-05. Desarrollo ejecutado en Linux Mint 22.3, Python 3.12.3,
Git 2.43.0. Informes privados reproducibles en `local/reports/`.

## Validación adicional con Wine, 2026-11-05

Wine 9.0 (`9.0~repack-4build3`) y winepath están instalados. `wine --version`
falló inicialmente con `Bad system call` dentro de la sandbox. La misma llamada
funcionó con el permiso de sandbox escalado. No se necesitó `sudo` ni se instaló
software en esta sesión. Se inicializaron exclusivamente los prefijos de prueba
de client01 y client02.

En client01, `Game.exe` abrió la pantalla de título bajo Wine. El preload escribió
`profile/bootstrap-loaded.txt` con Ruby 3.1.3 y `System.data_directory` dirigido a
`client01/profile/saves`. Se creó una partida Normal desechable mediante la
interfaz, se guardó en Partida 1 y apareció la confirmación del juego. Tras cerrar
el proceso, una nueva ejecución mostró Partida 1 en el menú y la cargó hasta la
habitación guardada. La segunda ejecución cerró con código 0.

Client02 arrancó con otro prefijo y otro marcador de preload. Se creó y guardó
una segunda partida desde su interfaz y cerró con código 0. Ambos archivos se
llaman `Partida 1.rxdata`, pero viven en perfiles distintos:

| Perfil | Tamaño | SHA-256 |
| --- | ---: | --- |
| client01 | 119.392 bytes | `d86e6aa9791d4e00743f115cd718524ce7130661089c13cd45d54ea25c8c873a` |
| client02 | 119.472 bytes | `177a316b96825063d8b18ed995c74b8ad1719b75878ab12a4c234e425d87fb49` |

El hash de client01 se registró antes de iniciar client02 y coincidió después de
guardar client02. Client03 y client04 siguen sin archivos de guardado. No se
observaron escrituras en la instalación original. La verificación posterior de
SHA-256 y lista de archivos originales y de las cuatro copias dio PASS: 26.571
archivos originales, cuatro copias independientes. La suite propia volvió a pasar
con 19 pruebas. El cambio de 18 a 19 añade una regresión para los enlaces
estándar que Wine crea dentro de su prefijo, manteniendo el rechazo de enlaces
en `game/` y `profile/`.

La evidencia de ejecución está en los logs, marcadores archivados y JSON privados
de `local/reports/`; las capturas de la interfaz se guardaron allí. El runner
`tools/wine_smoke.py` se limita a observar arranque/preload y cerrar sus propios
procesos. El ciclo guardar/cargar se operó y verificó por separado en la interfaz.

**Límite:** las dos copias se ejecutaron una después de la otra; no se verificó
todavía su ejecución simultánea. Tampoco se ejecutó nada en Windows x64 nativo.
Faltan allí el arranque del preload, guardar/cerrar/cargar, separación de dos
clientes en paralelo y la prueba de hasta cuatro clientes. El Hito 1 no comenzó.

## Recuperación tras la interrupción

La inspección del historial y del sistema de archivos confirmó que antes de
retomar estaban terminados los diagnósticos, la lectura de instrucciones/skills,
la evaluación inicial de VMS y las 13 pruebas MCP. No existían todavía un
repositorio del mod, código Hito 0 ni copias de prueba. El checkout Co-op Anything
estaba limpio. No había una copia parcial que recuperar ni trabajo que sobrescribir.
No se repitió aquella suite MCP: se conserva su resultado observado y procedencia
en `local/reports/prior-evidence.json`. Se comprobó una llamada real adicional a
detect_engine, que respondió correctamente aunque no reconoció el motor.

## Implementado y ejecutado

| Verificación | Resultado observado | Alcance |
| --- | --- | --- |
| Suite MCP de Co-op Anything | 13 pruebas, OK | Suite ejecutada antes de la reanudación |
| Suite propia Hito 0 | 19 pruebas, OK; cero omitidas en Linux | Fixtures sintéticos; corrupción, enlaces, sobrescritura, perfiles, Wine y paquete |
| Preparación real | 4 clientes, 26.571 archivos base por cliente | Copias físicas; 3,3 GiB aproximadamente |
| Integridad original | PASS, 26.571 archivos comparados | SHA-256, tamaños y lista completa contra baseline inicial |
| Integridad de las cuatro copias | PASS | Originales preservados; solo configuración y dos archivos de overlay propios |
| Separación física | PASS | Sin hardlinks, symlinks ni junctions compartidos; identidades de archivo revisadas |
| Directorios de saves | PASS | Cuatro archivos sonda con contenido distinto; retirados al terminar |
| Plan de cuatro lanzamientos | Generado, PLAN_ONLY | cwd, perfil, variables y prefijo Wine distintos; luego se ejecutaron client01 y client02 individualmente |
| Estructura / inventario | Completa | doctor sin carpetas/archivos requeridos faltantes |
| Guardados personales | Ninguno importado o abierto | No se encontraron saves con los nombres filtrados en la instalación |

Las pruebas negativas introducen cambios deliberados en fixtures: reemplazar un
archivo por un hardlink, compartir un perfil, quitar el bootstrap, cambiar mkxp,
alterar el original, apuntar saves por symlink, repetir la preparación y simular una
interrupción. Los verificadores rechazan esos casos. No se provocaron corrupciones
ni se hicieron escrituras de prueba sobre la instalación original.

Se inicializó Git exclusivamente en `anil-coop`. `.gitignore` excluye local/, dist/,
saves, binarios y assets. El juego y Co-op Anything no se incorporan al repositorio
ni al ZIP. Las herramientas de preparación no solicitan credenciales ni usan red.

## Herramientas y bloqueos

Funcionan Python, Git y las llamadas MCP probadas. El venv anterior ya tenía las
dependencias de la suite MCP; no se instaló nada nuevo. Se detectaron QEMU, xvfb-run
y dotnet, pero no se hicieron pruebas de ejecución del juego con ellos.

Wine 9.0 está disponible y funcionó con las copias aisladas según lo descrito
arriba. Ruby del sistema, CMake y MinGW siguen ausentes; no fueron necesarios.
La DLL Ruby integrada se ejecutó dentro del juego Wine y reportó 3.1.3.

Los wrappers PowerShell y el flujo nativo de GameSlot no se ejecutaron en Windows.
Para resolverlo hace falta Windows x64 con Python y Co-op Anything/GameSlot, más
una instalación propia del build fijado. No se presume disponible una VM Windows
porque haya QEMU.
No se expuso ningún servicio a Internet ni se integró VMS.

## Preparación para Hito 1

Está lista la base de código, documentación, cuatro perfiles y verificaciones.
El control de ejecución/guardado real pasó bajo Wine para los dos primeros perfiles.
Quedan abiertos Windows nativo y concurrencia real. Hito 1 no se inició.

Quedaron documentados 1–4 jugadores, campaña compartida, propiedad personal,
salvajes/aleatorización independientes, encuentro pendiente con confirmación,
roster cerrado al iniciar, formatos original/2v2/3v3/dos 2v2, doble victoria,
reintentos por pareja y duplicación mínima del equipo enemigo efectivo. Persisten
decisiones posteriores sobre balance de XP, mezcla de modalidades, excepciones de
encuentros y recuperación de campaña. Nada de eso se presenta como implementado.

## Combates salvajes individuales — 2026-11-05

En dos copias aisladas bajo Wine, `client01` mantuvo abierto un combate salvaje
durante más de un minuto mientras `client02` caminó y siguió viendo su personaje.
Tras huir, ambos volvieron a verse en el mapa sin reconexión. Una segunda ejecución
mostró dos combates salvajes simultáneos. Los guardados de las copias mantuvieron
sus SHA-256 anteriores; no se tocó la instalación original. Las partidas de prueba
aún no tenían Pokémon inicial, por lo que el escenario de QA agregó uno temporal
solo en memoria. Capturas, experiencia y Randomlocke no se comprobaron en juego;
la arquitectura los deja en cada proceso y guardado individual.
