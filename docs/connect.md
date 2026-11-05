# Conectar dos computadoras

Cada persona usa su propia copia legal de Pokémon Añil del build fijado, Python
3.10+ y una copia de este repositorio. El juego y los guardados permanecen en su
computadora. El anfitrión obtiene la IP privada de su LAN o de una VPN privada
compartida. No uses una IP pública, port forwarding ni la dirección `0.0.0.0`.

Elegí un código de sesión de 6 a 12 letras mayúsculas/números, por ejemplo
`ANIL01`. Creá una clave aleatoria de al menos 16 caracteres y compartila con
el amigo por un canal privado; no la escribas en el repositorio. En ambos equipos
deben coincidir IP, puerto, código y clave. El servidor autentica con un desafío
HMAC-SHA256: la clave no viaja por la red. En LAN los mensajes posteriores son TCP
sin cifrar; para jugar fuera de una red confiable usá una VPN privada.
Podés generar una clave con `python3 -c 'import secrets; print(secrets.token_urlsafe(24))'`
o con `py -3 -c 'import secrets; print(secrets.token_urlsafe(24))'` en Windows.

## Linux Mint con Wine

En cada computadora, desde `anil-coop`, prepará una copia propia con
`python3 -B tools/h0.py prepare --source '<juego propio>' --clients 1` si aún no
existe; después ejecutá `python3 -B tools/install_presence.py --clients client01`.
El anfitrión inicia el servidor en una terminal:

```sh
export ANIL_COOP_SECRET='CLAVE_COMPARTIDA_LARGA_Y_ALEATORIA'
python3 -B src/server/session_server.py --bind <IP_PRIVADA_DEL_ANFITRION> --port 17641
```

En otra terminal, el anfitrión inicia su juego:

```sh
export ANIL_COOP_SECRET='CLAVE_COMPARTIDA_LARGA_Y_ALEATORIA'
python3 -B tools/wine_smoke.py --client client01 --seconds 600 \
  --gameslot ../coop-anything/tools/gameslot/gameslot.py \
  --session ANIL01 --port 17641 --server-host <IP_PRIVADA_DEL_ANFITRION> \
  --host-client client01
```

El amigo ejecuta el mismo comando en su computadora, con su propia `client01`,
**omitiendo `--host-client client01`**. Entra primero al mapa el anfitrión; el
invitado puede unirse después. Hacé clic en cada ventana para controlarla.
`gameslot.py` es la herramienta existente de Co-op Anything y se indica su ruta
local, sin copiarla dentro del mod.

## Windows x64 nativo

Python 3.10+ (`py -3`), PowerShell y una copia local de Co-op Anything/GameSlot
son necesarios. En cada PC, prepará el overlay una sola vez con
`./packaging/windows/Prepare.ps1 -Source 'D:/Juegos/Pokemon Anil' -Clients 1`.
Cada terminal que use la sesión necesita la misma variable:

```powershell
$env:ANIL_COOP_SECRET = 'CLAVE_COMPARTIDA_LARGA_Y_ALEATORIA'
```

El anfitrión inicia el servidor en una terminal:

```powershell
py -3 src/server/session_server.py --bind <IP_PRIVADA_DEL_ANFITRION> --port 17641
```

En otra terminal, inicia su juego:

```powershell
./packaging/windows/Launch.ps1 -Clients client01 -Run `
  -GameSlot 'D:/dev/coop-anything/tools/gameslot/gameslot.py' `
  -ServerHost <IP_PRIVADA_DEL_ANFITRION> -Port 17641 -Session ANIL01 -Mode create
```

El amigo ejecuta ese último comando en su PC con su propio `-GameSlot` y
`-Mode join`. Si el firewall bloquea la conexión, permití TCP 17641 solo en la
red privada o interfaz VPN correspondiente. No abras puertos del router.

**Estado probado:** dos juegos reales bajo Wine se conectaron mediante la IP
privada de una misma computadora; el invitado vio moverse al anfitrión. Pasaron
las pruebas de autenticación y rechazo de direcciones públicas. Aún no se probó
con dos computadoras físicas ni en Windows nativo. La VPN requiere configuración
propia de quienes juegan; este prototipo no la instala.
