# Resultados de Hito 0

Fecha: 2026-11-05. Desarrollo ejecutado en Linux Mint 22.3, Python 3.12.3,
Git 2.43.0. Informes privados reproducibles en `local/reports/`.

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
| Suite propia Hito 0 | 18 pruebas, OK; cero omitidas en Linux | Fixtures sintéticos; corrupción, enlaces, sobrescritura, perfiles y paquete |
| Preparación real | 4 clientes, 26.571 archivos base por cliente | Copias físicas; 3,3 GiB aproximadamente |
| Integridad original | PASS, 26.571 archivos comparados | SHA-256, tamaños y lista completa contra baseline inicial |
| Integridad de las cuatro copias | PASS | Originales preservados; solo configuración y dos archivos de overlay propios |
| Separación física | PASS | Sin hardlinks, symlinks ni junctions compartidos; identidades de archivo revisadas |
| Directorios de saves | PASS | Cuatro archivos sonda con contenido distinto; retirados al terminar |
| Plan de cuatro lanzamientos | Generado, PLAN_ONLY | cwd, perfil, variables y prefijo Wine distintos; ningún proceso de juego iniciado |
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

No están disponibles Wine, wine64, winepath ni Ruby de sistema; tampoco CMake ni
MinGW. Los dos últimos no son necesarios para este Hito 0. Python sirve para toda
la preparación. La DLL Ruby incluida corresponde al juego Windows y permanece
intacta; no puede ejecutarse nativamente como un intérprete Linux.

**No se ejecutó Game.exe.** La estructura de Wine está reservada, sin inicializar.
No se validaron el arranque del preload, las rutas efectivas de SaveData/Multi Save,
un ciclo guardar/cerrar/cargar ni cuatro ventanas reales. Los wrappers PowerShell
y el flujo nativo de GameSlot tampoco se ejecutaron en Windows. El marcador
`runtime_tested: false` no debe cambiarse hasta disponer de evidencia real.

Para resolverlo: Windows x64 con Python y Co-op Anything/GameSlot, más una instalación
propia del build fijado; alternativamente, instalar Wine con autorización y validar
su adaptador de procesos. No se presume disponible una VM Windows porque haya QEMU.
No se expuso ningún servicio a Internet ni se integró VMS.

## Preparación para Hito 1

Está lista la base de código, documentación, cuatro perfiles y verificaciones para
continuar. Queda abierto el control de ejecución/guardado real de Hito 0; realizarlo
antes de afirmar que hay clientes listos para pruebas de sesión. Hito 1 no se inició.

Quedaron documentados 1–4 jugadores, campaña compartida, propiedad personal,
salvajes/aleatorización independientes, encuentro pendiente con confirmación,
roster cerrado al iniciar, formatos original/2v2/3v3/dos 2v2, doble victoria,
reintentos por pareja y duplicación mínima del equipo enemigo efectivo. Persisten
decisiones posteriores sobre balance de XP, mezcla de modalidades, excepciones de
encuentros y recuperación de campaña. Nada de eso se presenta como implementado.
