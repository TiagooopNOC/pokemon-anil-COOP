# Decisiones y contratos de arquitectura

Fecha de referencia: 2026-11-05. Esto prepara límites entre componentes futuros;
no es código de sincronización. El único componente de runtime actual es el preload
de aislamiento de pruebas.

## Evidencia de esta instalación

- Identidad fijada por hashes en `config/build.json`: carpeta v4.14, pero
  `Data/Scripts/001_Settings/002_Settings.rb:10` declara GAME_VERSION 4.1.1;
  en el mismo archivo, líneas 674/676: Essentials 21.1 y mkxp-z 2.4.2/d13f35c.
  No decidir compatibilidad usando únicamente el nombre de la carpeta.
- Game.exe es Windows PE x64; importa `x64-msvcrt-ruby310.dll`, Ruby 3.1.3.
  El nombre de una carpeta Ruby 3.3.0 no identifica el runtime activo.
- `Game.ini` carga `Data/Scripts.rxdata`; plugins desde
  `Data/PluginScripts.rxdata`, a través de PluginManager. El diagnóstico anterior
  encontró 356 scripts base y 320 scripts cacheados de plugins coincidentes con
  sus fuentes. Hay ocho fuentes extra de Advanced AI ausentes del caché: no
  recompilar plugins indiscriminadamente.
- SaveData calcula FILE_PATH en `Data/Scripts/007_Save data/002_SaveData.rb:8`;
  Multi Save calcula SAVE_DIR en `Plugins/Multi Save/Multi Save.rb:54`. Ambos
  consultan `System.data_directory`; si no existe, caen en el directorio del juego.
  Multi Save puede migrar/eliminar un guardado antiguo durante la carga.
- El mkxp de referencia ejecuta `preloadScript` antes de los scripts empaquetados
  ([binding-mri.cpp, commit d13f35c](https://github.com/mkxp-z/mkxp-z/blob/d13f35c/binding/binding-mri.cpp)).
  `dataPathOrg` y `dataPathApp` controlan el directorio de preferencias
  ([config.cpp del mismo commit](https://github.com/mkxp-z/mkxp-z/blob/d13f35c/src/config.cpp)).
El preload ya se observó en el ejecutable instalado bajo Wine; Windows nativo
todavía no se probó.

## Aislamiento implementado en Hito 0

`tools/h0.py prepare` valida seis hashes críticos, registra un manifiesto completo
del original y copia archivos, sin enlaces duros/simbólicos. No importa guardados
Game/Partida/Auto/Backup. Mantiene los plugins, fuentes y cachés originales.

En cada copia cambia únicamente `mkxp.json` y añade `CoopDev/isolate.rb` y un
identificador. Conserva el mkxp original dentro del perfil. `dataPathOrg=AnilCoopDev`
y un `dataPathApp` UUID constituyen una segunda separación del namespace original.
El preload valida el identificador de lanzamiento y devuelve el directorio privado
`profile/saves` al consultar `System.data_directory`, antes de crear las constantes
de guardado. Se crean las carpetas antes de arrancar para evitar el fallback.

Cada cliente dispone también de APPDATA, LOCALAPPDATA y un directorio de prefijo Wine
distintos. Cambiar variables APPDATA por sí solo no garantiza que todas las APIs de
Windows redirijan sus carpetas conocidas: la protección no depende solo de eso.
El runtime escribió dos partidas desechables en perfiles privados bajo Wine.
No se abrieron ni migraron partidas personales.

El lanzador nativo usa el GameSlot de Co-op Anything, sin incluir su código en el
paquete. Reserva los cuatro slots para un conjunto elegido de clientes y renueva la
reserva. Solo registra/termina procesos hijos propios. Bajo Wine se usó
`tools/wine_smoke.py`: GameSlot reservó los slots y el runner cerró únicamente sus
procesos y prefijo privado. GameSlot no puede verificar identidad de PID Windows
en Linux; por eso no se delegó en él la limpieza de procesos Wine.

## Componentes previstos para hitos posteriores

| Componente | Responsabilidad | No puede hacer |
| --- | --- | --- |
| TransportAdapter | Mensajes versionados, tamaños limitados, autenticación de sesión y reconexión | `eval`, objetos Ruby deserializados de la red, apertura automática de puertos |
| SessionCoordinator | 1–4 miembros, capacidades, autoridad y épocas de sesión | Reemplazar identidad/guardados personales |
| WorldPresence | Mapa, posición, dirección, animación y transiciones de avatares | Ejecutar eventos de historia al dibujar un compañero |
| CampaignJournal | Secuencia de efectos confirmados y recibos por jugador | Copiar todos los switches/variables globales sin clasificación |
| EncounterCoordinator | Roster, preparación, formato y resultados hijos | Admitir participantes tras STARTED |
| EnemyRosterPlanner | Equipo efectivo, distribución y duplicación mínima | Inventar especies; volver a aleatorizar durante un reintento |
| BattleAdapter | Control/validación de decisiones por propietario de Pokémon | Permitir que un cliente elija acciones del equipo de otro |
| PersonalSaveAdapter | Estado personal + referencias de campaña + recibos | Sobrescribir partidas ajenas o fusionar historiales sin migración explícita |

Propuesta: coordinador separado, ejecutable también en Windows; no simular dos
batallas gráficas dentro de un mismo proceso RGSS. Cada batalla tiene una autoridad
y un stream de decisiones/resultados. Transporte concreto, relay/NAT y alojamiento
siguen pendientes de prototipo y elección en Hito 1, que no se inició.

## Contratos conceptuales

Identificadores opacos, versionados y separados del PlayerID de Pokémon:

- `Session`: protocol_version, build_fingerprint, session_id, epoch,
  campaign_id, members[player_id, capabilities, individual_rules].
- `CampaignEffect`: effect_id, encounter_id, sequence, expected_revision,
  kind, payload validado, recipients. Persistencia y confirmación antes de dar
  efectos por entregados. No transmitir objetos Marshal.
- `Encounter`: encounter_id, campaign_revision, trainer_event_key, initiator,
  participants/ready, state, roster_plan, child_battles, reward_receipts.
- `EnemyInstance`: enemy_id, source_original_id, is_duplicate, effective_snapshot,
  child_battle_id, reserve_order. Cada instancia muta PS/estados/PP por separado.
- `BattleResult`: child_battle_id, attempt_id, authority_epoch, result,
  personal_deltas, receipt_ids; validado contra participantes y plan congelado.

Estados futuros: `PENDING -> STARTED -> WAITING_RESULTS -> COMMITTED`.
Errores/desconexiones requieren estados explícitos de recuperación; no equivalen a
victoria. Solo PENDING permite incorporaciones. Para cuatro jugadores, cada hijo
tiene `PENDING/RUNNING/WON/RETRYABLE`; un hijo WON queda sellado mientras el otro
reintenta. COMMITTED exige ambos WON. Recibos impiden repetir premios tras un crash.

El journal de campaña registra cambios comunes; los saves personales registran
consumibles, PS, muertes, inventario y recibos. Hace falta protocolo de recuperación
porque dos archivos en dos computadoras no se guardan atómicamente. Los resultados
parciales no deben borrar consecuencias personales de una derrota.

## Adaptación del motor y riesgos abiertos

Essentials utiliza globals y estado monojugador. Los eventos del juego incluyen
diálogos, scripts y efectos mezclados; cada familia relevante necesita clasificación
y adaptador. No reproducir indiscriminadamente comandos de eventos en todos los
clientes. Páginas, self-switches, regalos, medallas y puertas son especialmente
sensibles. Vencer solo a un entrenador opcional puede registrar su derrota común;
los premios personales se atribuyen solo a quienes correspondan.

Las bases de batalla admiten múltiples posiciones, pero eso no demuestra 3v3 humano:
hay límites de número de entrenadores, ownership, selección de objetivos, cambios,
IA y escenas. Debe probarse contra los plugins de Añil. Cuatro jugadores implican
dos simulaciones separadas y un coordinador de resultados, no un array 4v4.

RNG local para salvajes; RNG de batalla bajo la autoridad de cada combate. No usar
`srand` global para sincronizar todo el juego. Reproducibilidad de decisiones no
garantiza determinismo entre runtimes/plugins; verificar hashes y snapshots.

No se admite todavía importar saves personales, unirse con historias divergentes,
migrar builds o garantizar todas las modalidades. Tampoco se eligieron fórmulas de
XP de duplicados ni recuperación ante abandono definitivo de una pareja. Esas son
decisiones de hitos posteriores, no bloqueos para preparar infraestructura.
