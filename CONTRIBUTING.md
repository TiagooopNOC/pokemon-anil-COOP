# Contribuir a Pokémon Añil Co-op

Empezá por un [issue concreto](https://github.com/TiagooopNOC/pokemon-anil-COOP/issues)
y explicá qué sistema usás, qué versión de Añil y qué commit probaste. Esta alfa
se desarrolla en Linux Mint para Windows x64. Leé [la guía de prueba](docs/alpha.md)
antes de ejecutar dos clientes.

Trabajá siempre sobre una copia aislada creada por las herramientas del proyecto.
Nunca subas el juego, assets, plugins originales, guardados, claves de sala,
direcciones privadas ni rutas con datos personales. `local/` y `dist/` quedan
fuera de Git. Usá LAN o VPN privada; no abras el servidor a Internet público.

Para un cambio pequeño, ejecutá sus pruebas específicas con
`python3 -B -m unittest tests.test_nombre -v`. Si requiere el juego, indicá
si lo comprobaste en Windows nativo, en Game.exe bajo Wine, mediante órdenes
internas programadas o con una simulación. No describas una simulación como
partida humana. Documentá pasos para reproducir fallos y qué guardados se usaron,
sin adjuntarlos. Los PR deben explicar el comportamiento final y sus límites.
