# Co-op Anything, VMS y dependencias

## Co-op Anything

Checkout consultado: `a71be2ca706c5d6e4edc02f957e0081fd2742e43`.
Se leyeron AGENTS.md y las skills coop-triage, coop-research,
coop-reverse-engineer, coop-qa y coop-sync-testing. Se utilizó MCP get_skill,
search_directory y detect_engine. El detector devolvió motor desconocido para
esta instalación; la identificación manual mediante archivos sigue siendo la
evidencia válida. Buscar Pokemon devolvió otros proyectos (Archipelago, SilphNet,
Gen1Coop), no una implementación directamente aplicable a Añil.

Las 13 pruebas unitarias de `tools/mcp/test_coop_mcp.py` finalizaron con OK usando
el venv ya existente. Esto valida esa suite y las llamadas observadas, no todos los
adaptadores ni un servidor multijugador. No se ejecutó git pull ni se utilizaron
cuentas para issues/PR; no se publicó información del propietario.

GameSlot se incluye sin modificaciones en `vendor/gameslot/`, con su licencia MIT,
revisión y SHA-256 en el README de ese directorio. El lanzador Wine lo usa para
reservar procesos; el lanzador Windows usa un bloqueo del sistema por perfil,
que se libera si el proceso termina. El juego, sus plugins y VMS no se redistribuyen.

## Voltseon's Multiplayer Solution (VMS)

Referencias examinadas:

- [Recurso VMS](https://eeveeexpo.com/resources/1453/): edición publicada 3.0.3,
  para Essentials 21.1; requiere rainefallUtils.
- [Código fijado al commit 30a710537e64f88dabc84780856bfeab77a855e1](https://github.com/heitorcordeiromaciel/essentialsmultiplayersolution/tree/30a710537e64f88dabc84780856bfeab77a855e1).
- [rainefallUtils](https://eeveeexpo.com/resources/1079/): recurso 1.2 para
  Essentials 20/20.1/21.1; pide acreditar a rainefall. No está instalado como
  dependencia identificable en esta copia de Añil.

En el árbol de VMS revisado no se encontró LICENSE/COPYING/NOTICE y la API del
repositorio devolvió `license: null`. Esto **no equivale a permiso de reutilización**.
Los créditos no sustituyen una licencia de redistribución. Tampoco se verificó una
licencia formal suficiente de rainefallUtils. Antes de copiar o distribuir código
de cualquiera de ambos hacen falta términos explícitos compatibles; no se contactó
a sus autores ni se incorporó código.

Hallazgos del código, no garantías de compatibilidad:

- Tiene una configuración de hasta cuatro jugadores, sincronización de presencia
  y ayudas para combates/enlace; no demuestra la campaña compartida solicitada.
- Sus defaults desactivan varias sincronizaciones y la comprobación juego/versión.
  No se pueden importar como una configuración segura del proyecto.
- Su multi de cuatro corresponde a un flujo distinto del encuentro NPC con dos
  parejas y commit común; sustituye equipos/curaciones y desactiva premios en
  determinados caminos. No implementa nuestros recibos ni reglas individuales.
- La conexión descomprime y usa `Marshal.load` sobre datos recibidos. La conversión
  de Pokémon incluye `eval` sobre una representación recibida. Esos caminos no
  deben incorporarse al transporte del mod.
- El servidor integrado usa hilos y estado mutable; no es un journal transaccional
  de campaña con reintentos idempotentes.

**Decisión Hito 0:** referencia técnica, no dependencia integrada. Adoptar ideas
solo después de revisar licencia y encaje; implementar contratos propios con
mensajes de datos validados. No se descargaron/ejecutaron servidores VMS ni se
abrieron puertos. Cable Club permanece byte por byte en cada copia, sin usarlo
todavía como transporte del cooperativo.

## Empaquetado y herramientas

Python usa solo su biblioteca estándar; no se instaló pip ni paquetes del sistema.
El ZIP incluye únicamente los directorios propios permitidos. La titularidad y
licencia de distribución del mod propio deberán acordarse antes de publicarlo;
este Hito 0 no asigna licencias a código ni assets de terceros. Los hashes del juego
permiten reconocer una instalación del usuario sin redistribuir sus contenidos.
