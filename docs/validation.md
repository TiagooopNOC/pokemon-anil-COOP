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
solo en memoria. En esa ejecución no se probaron captura, experiencia ni
Randomlocke; las pruebas posteriores figuran abajo.

## Espera NPC y perfiles con iniciales — 2026-11-05

Antes de la interrupción, dos clientes bajo Wine hablaron con el mismo NPC de
prueba, se prepararon y confirmaron el grupo; el invitado salió de la espera y
siguió caminando. El anfitrión inició solo el combate normal contra Azul y se
rechazó una incorporación tardía. `client03` guardó y recargó Bulbasaur en Normal;
`client04` guardó y recargó Charmander en Randomlocke. En combates salvajes
simultáneos apareció Rattata frente a Wooper, respectivamente. Los SHA-256 de
ambos guardados permanecen iguales tras cerrar las pruebas incompletas.
Captura, experiencia y evolución aún requieren acciones manuales en el juego;
la automatización de entrada fue rechazada por la revisión del entorno.

## Prototipo 2v2 — 2026-11-06

Checkpoint de recuperación: `08e6c77`. Los logs de la prueba manual anterior
confirman checksum inicial coincidente y entrada al combate en ambas copias;
no confirmaban un turno completo. Se corrigieron IDs de habilidades/objetos
también en battlers y el manejo de excepciones que Essentials normalmente absorbe.
La prueba `BOT006` ejecutó el motor original en dos procesos Wine, con órdenes
programadas y la escena de diagnóstico sin gráficos: 14 rondas, sustitución por
debilitamiento y victoria con hashes iguales; ambos saves intactos y conexión viva.
No valida los menús ni la presentación visual. Equipos temporales, sin recompensas,
EXP ni persistencia; no equivale a integración terminada con equipos personales.

### Cierre gráfico y desconexiones — 2026-11-06

Checkpoint `73e0d2d`. El bloqueo visual era una página de texto de Mar Llamas
esperando confirmación; el bot ahora usa `Window#resume`, sin simular teclas ni
cambiar los controles humanos. El escenario usa la preparación nativa Añil/LBDSKY.
`VIS004`: dos Game.exe reales bajo Wine, gráficos y órdenes programadas, victoria
en 11 rondas con checksums coincidentes; ambos regresaron al mapa renderizado,
se vieron y recibieron posiciones nuevas del compañero. Capturas de ambos mapas
inspeccionadas; guardados aislados sin cambios. Evidencia privada: reporte
`anil-wine-99bec222347b4fdf876a386db2ee7ee1.json` en `local/reports/`.
`DISC001`: desconexión en turno 1 con gráficos, ambos abortaron y regresaron al
mapa sin escribir resultados/guardados. `DESYNC1`: alteración deliberada de 1 PS
en el motor sin gráficos, ambos rechazaron el estado y abortaron. No se desactivó
ningún checksum. Las pruebas anteriores de cambio voluntario y derrota pasaron
con motores reales sin renderizado; no se repitieron.
Pendiente: selección humana de órdenes hasta finalizar, Windows nativo, equipos
personales y recompensas persistentes. Captura/EXP/evolución salvajes siguen
pendientes de prueba manual independiente.

### Experiencia por propietario (temporal)

`REWARD1`, dos motores reales sin renderizado: victoria, cada Squirtle propio
recibió 125 EXP y subió de 10 a 11; el equipo remoto no cambió. La segunda llamada
al reparto no añadió EXP. Los dos enemigos cuentan como un único origen para la
recompensa. El cálculo de EXP/EV y la subida usan los métodos originales de Añil
con Level Caps EX. Se aplican después del resultado acordado, a equipos temporales;
no hay dinero, evolución ni persistencia. Reporte privado:
`anil-wine-abd261d0b0514b37970148974b00e34c.json`.
`REWARD2` llegó gráficamente a victoria y subida de nivel, pero se detuvo en la
confirmación de estadísticas; se cerró de forma controlada y no cuenta como prueba
completa. El bot ahora muestra esa ventana nativa con confirmación temporizada;
para el jugador humano se conserva el botón normal y se bombea la conexión.
Reproducción/manual: [qa-2v2.md](qa-2v2.md).
`REWARD3` completó gráficamente victoria y retorno conectado en ambos; uno mostró
125 EXP/subida y el otro no recibió EXP porque su participante había caído y su
reserva no participó. Por eso no pasó la expectativa de subida para ambos. Para
probar esa UI sin depender de los KO aleatorios, el escenario `rewards` usa ahora
un rival temporal con Salpicadura; el escenario `basic` conserva el combate normal.
`REWARD4` pasó en ambos motores con gráficos: cinco rondas, victoria acordada,
125 EXP para Bulbasaur/Charmander de sus respectivos propietarios, nivel 10→11,
ventanas de estadísticas, repetición sin EXP adicional y regreso a ambos mapas
con conexión/posición remota. Guardados intactos. Reporte privado:
`anil-wine-30ea781146fc4b01a1f5a91865ed7db8.json`.

### Selección personal 1–3 — 2026-11-06

`TEAM001`: los iniciales reales de client03/client04 (Normal/Randomlocke), uno por
jugador, completaron seis rondas en dos motores Wine sin escena gráfica; 35 EXP
propios y regreso conectado. `TEAM002`: escenario explícitamente sintético en RAM,
seis Pokémon por perfil, seleccionados [2,0,4], completó 3+3 con cambio voluntario
y sustitución por debilitamiento. No agrega Pokémon al usar el mod normalmente.
Guardados intactos en ambas pruebas. 17 tests específicos pasaron, incluyendo
selección validada, propiedad de reservas y dos recorridos TCP. Menú humano y
lanzadores Windows nuevos todavía pendientes de prueba. Historia individual es
el requisito vigente; ningún interruptor de campaña se envía al servidor.

### Persistencia individual y Repartir Exp. — 2026-11-06

`SAVE003`: dos motores Wine, 3+3 sintético, cambios y sustituciones; resultado
aplicado únicamente a los seleccionados. Guardado nativo en archivos QA nuevos,
recarga con Game.load y repetición del resultado antes/después de recargar: PASS.
Los tres excluidos conservaron sus atributos. La recarga actualiza únicamente
`@last_update_time`, reloj de tiempo en equipo de LBDSKY; todos los demás atributos
se compararon. Partida 1 sin cambios. `SHARE01`: EXP All de un propietario repartió
35/17/17 a sus elegidos; reparto individual del otro dio 35/0/35. Cero EXP para
los excluidos, persistencia y recibos antirrepetición pasaron. Estos recorridos
usaron el motor real sin renderizado, no acciones humanas. Se corrigió además
el ledger de encuentros ausente de perfiles QA antiguos, solo en la copia temporal
usada por el combate, y el cierre ya preserva la causa original de un error.
