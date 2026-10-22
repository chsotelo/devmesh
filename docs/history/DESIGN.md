# devmesh — Plan

Infraestructura propia para controlar todas mis máquinas de desarrollo desde cualquier dispositivo (tablet, celular, otra laptop), con terminales persistentes, varias máquinas trabajando en proyectos distintos y acceso que **no depende de un solo camino**.

Estado: **v0.1.0 implementada en local** (sin desplegar) · Iniciado: 2026-10-20 · Revisión 3: plan completo con correcciones Codex + Grok · Código: ver `README.md`, `make check` (shellcheck + shfmt + 84 tests bats) + `make integration` (60 checks end-to-end en contenedores reales) · Revisado por agentes de seguridad y calidad (hallazgos corregidos, ver §15)

---

## 1. Objetivo

- Tablet y celular = **punto de control** de todas las máquinas.
- Cada máquina es **independiente**: sus propios repos, proyectos y herramientas (Claude Code, Codex o lo que sea, incluso tareas que no son código). devmesh no gestiona credenciales, repos ni configuración de herramientas.
- El VPS es solo **central de comunicación**: no contiene repos ni código.
- Desde cualquier dispositivo: ver terminales abiertas, entrar a una sesión de Claude en vivo, crear terminales nuevas, enviar comandos.
- **Siempre** poder abrir una terminal: el acceso no puede depender de un solo servicio.
- Registrar una máquina nueva = **un código y un comando**.
- Si una máquina cae: me entero (alerta), puedo encenderla a distancia, y mientras tanto sigo trabajando en las otras.
- Costo extra: **$0**. Open source.

### Requisitos

| ID | Requisito | Criterio de aceptación |
|---|---|---|
| R1 | **Alta con un código, sin llaves privadas en el VPS** | `devmesh invite <name>` devuelve un código de un solo uso (15 min) y un único comando (descarga + verificación SHA-256 + ejecución); pegarlo en la máquina nueva la deja operativa sin otro paso. **Todas las llaves privadas se generan en el dispositivo**; el VPS solo recibe y guarda llaves públicas. El script descargado no contiene secretos de larga vida (ver §5) |
| R2 | **Alta de tablet/celular** | `devmesh invite <name> --phone` da el comando para Termux; Termux genera las llaves WG y SSH localmente, se registra, y deja el `.conf` de WireGuard en Descargas para **importar desde archivo** en la app WireGuard (luego se borra). Sin QR con llave privada |
| R3 | **Baja rápida y honesta** | `devmesh remove <name>`: (1) quita el peer WG → camino A cortado al instante para tráfico nuevo; sesiones TCP abiertas por WG mueren en ≤ 45 s (`ClientAliveInterval 15` × 3 en las máquinas); (2) quita su llave del usuario `tunnel` **y mata las sesiones activas de `tunnel`** (`pkill -u tunnel`; los túneles de las máquinas legítimas se reconectan solos en segundos) → camino B cortado al instante; (3) quita la llave de `clients.pub` → las máquinas la dejan de aceptar en ≤ 1 min; (4) borra la fila del registro. No borra datos del disco del dispositivo. Camino C (Claude) se revoca aparte desde claude.ai |
| R4 | **Sin panel web en v1** | Toda la gestión por CLI `devmesh` en el VPS. Panel web solo como fase futura, accesible **solo dentro de la VPN** y construido sobre la misma CLI |
| R5 | **Menú `dm`** (fzf, en Termux y máquinas) | Menú navegable con dedo/flechas: Ver dispositivos · Agregar · Eliminar · Ver sesiones · Entrar a… Al agregar muestra el código y el comando de alta en pantalla. Solo envuelve comandos `devmesh` |
| R6 | **Estado de dispositivos** | `devmesh ls`: nombre, IP WG, puerto de túnel, último handshake WG, túnel up/down, color |
| R7 | **Dónde está cada sesión** | `devmesh who`: por máquina → sesiones tmux, pestañas (ventanas) con la activa marcada, y desde qué dispositivo están conectadas (IP de origen → nombre vía registro; local si no es remota). Máquinas caídas como `OFFLINE` |
| R8 | **Identificación dentro de la máquina** | Barra tmux: `máquina │ sesión │ pestañas (activa con *) │ clientes conectados`, color fijo por máquina desde el registro. Título de la terminal: `máquina · sesión · programa` |
| R9 | **Pestañas con nombre útil** | Nombre automático de ventana tmux = `carpeta:programa` (ej. `api:claude`); renombrable con `Ctrl+b ,` |
| R10 | **Pestañas locales visibles** | Cada pestaña de la terminal gráfica de la máquina nace en tmux (autoarranque, excluyendo terminales de IDE) y aparece en `devmesh who` y en `t` |
| R11 | **Siempre poder abrir terminal** | Sesión tmux `main` mantenida por systemd (con linger) aunque nadie haya iniciado sesión |
| R12 | **Entrada con fallback** | `m <máquina>` intenta camino A (mosh) y cae a B (ssh vía VPS) sin intervención |
| R13 | **Lista de terminales con color e identificador** (tablet/celular) | `dm` → "Terminales" muestra todas las terminales de todas las máquinas, cada línea con el **color de su máquina** y su **ID global** `máquina:sesión:pestaña`; tocar una = entrar. Máquinas caídas en gris, no seleccionables |
| R14 | **Crear siempre pregunta dónde** | "Nueva terminal" pide en orden: 1) **máquina** (solo las en línea, con color), 2) **proyecto** (carpetas de `~/PROJECTS` de esa máquina, o nombre libre), 3) entra. Nunca se crea sin máquina explícita |
| R15 | **Rastro de cada terminal** | Toda terminal creada guarda: dispositivo que la creó, fecha/hora, carpeta. Visible en `devmesh who` y en la lista de R13 |
| R16 | **Estado del agente por terminal (opcional por máquina)** | Si en esa terminal corre un agente con hooks (Claude Code hoy; Codex u otro si los soporta), la lista muestra **trabajando / esperando / libre**. Mecanismo agnóstico: cualquier herramienta puede marcar la pestaña con `tmux set -p @agent <estado>`. Sin hooks, la terminal se lista igual, sin estado |
| R17 | **ID único y estable** | Formato `máquina:sesión` (+ `:pestaña`). Nombres sin `.` ni `:` (tmux los prohíbe). Si el nombre ya existe en esa máquina, ofrece entrar a la existente en vez de duplicar |
| R18 | **Mismo nombre en la app de Claude (opcional)** | En máquinas que usen Claude con Remote Control, la sesión usa el mismo ID (`lap:api`) |
| R19 | **Cerrar terminales viejas** | `dm` → "Cerrar terminal" con confirmación; la lista muestra hace cuánto no se usa cada una |
| R20 | **Confirmación en acciones destructivas** | Eliminar dispositivo o cerrar terminal pide confirmación escribiendo el nombre |
| R21 | **Actualizar devmesh en todas las máquinas** | `devmesh update` en cada máquina trae la versión actual de los scripts desde el VPS; `devmesh ls` muestra versión por máquina |
| R22 | **Formato para pantalla chica** | En celular la lista usa formato compacto (una línea por terminal, sin columnas largas) |
| R23 | **Manejo táctil (v1)** | En `dm`: **tocar** una línea la marca, **doble toque** entra, **deslizar** hace scroll; Enter también entra. Dentro de tmux: tocar el nombre de una pestaña en la barra la abre, deslizar hace scroll del historial. Verificado en código fuente (ver §6 "Táctil") |
| R24 | **Enviar y traer archivos** (tablet/celular ↔ máquina) | `dm` → "Enviar archivo": eliges archivo del dispositivo (imagen, captura, PDF…), **máquina** y carpeta destino → `scp` por camino A (o B). "Traer archivo": al revés, a la carpeta de descargas del dispositivo. Funciona igual para cualquier herramienta (Claude, Codex, otra) |
| R25 | **Ver la UI en desarrollo desde la tablet** | `dm` → "Abrir puerto": eliges máquina y puerto → por camino A muestra la URL `http://10.73.0.x:<puerto>` para el navegador; por camino B levanta `ssh -L` y muestra `http://localhost:<puerto>`. Requisito documentado: el dev server escucha en `0.0.0.0` (o se usa siempre `ssh -L`) |
| R26 | **Alerta cuando una máquina cae** | Cron en el VPS cada 1 min: si una máquina pasa > 3 min sin handshake WG **y** sin túnel → aviso push al celular/tablet con el nombre de la máquina; aviso de vuelta cuando se recupera. Canal: **ntfy en el VPS como binario nativo + systemd** (sin Docker), detrás de nginx, con `auth-default-access: deny-all` y token (nadie que adivine la URL puede leer ni publicar) |
| R27 | **Encendido tras corte de luz y a distancia** | BIOS de cada PC: "Restore on AC power loss = On". Wake-on-LAN habilitado; `dm` → "Encender máquina" envía el paquete mágico desde otra máquina **encendida en la misma red local** (si todas están apagadas en esa red, WoL no sirve; queda el encendido tras corte). Laptop: limitar carga al ~80% (24/7 enchufada) |
| R28 | **Política de actualizaciones y reinicios** | `unattended-upgrades` solo seguridad; reinicio automático permitido solo en ventana (ej. 04:00) y **escalonado** (nunca dos máquinas a la vez); tras reiniciar, R11 levanta todo y R26 avisa si no volvió |
| R29 | **Seguridad** | (a) Usuario `tunnel` en VPS sin shell (ver R35); (b) firewall del VPS: ufw ya está activo → solo **agregar** `allow <puerto WG>/udp`; reenvío según R33; (c) `fail2ban`; (d) SSH solo con llave en VPS y máquinas; (e) bloqueo de pantalla obligatorio en tablet/celular (la llave SSH no tiene passphrase); (f) revocación con `devmesh remove`; (g) medir tráfico del VPS (`vnstat`) porque es el de producción |
| R30 | **Redes que bloquean UDP** | Si WG no conecta (hotel, oficina), `m`/`t` caen solos a camino B (TCP 22); si también está bloqueado, hotspot del celular. Documentado en `dm` → ayuda |
| R32 | **El hub enruta entre dispositivos** | `ip_forward` ya está en 1 (lo activó Docker; verificado 2026-10-20) → no se cambia. `wg-quick@devmesh` habilitado y ordenado **después de `docker.service`** (drop-in `After=`/`Requires=`) para que exista `DOCKER-USER` al subir. Hub: `AllowedIPs = 10.73.0.N/32` por peer. Clientes: `AllowedIPs = 10.73.0.0/24` (el internet del celular/tablet no pasa por el VPS) y **`PersistentKeepalive = 25` en todos los peers** (sin esto, las máquinas tras NAT dejan de ser alcanzables tras inactividad). Probar tráfico peer↔peer explícitamente, no solo handshakes |
| R33 | **No romper producción con el firewall** | Verificado: `FORWARD` policy `DROP`, `DOCKER-USER` es la primera cadena, iptables legacy, ufw activo. La regla de reenvío va en **`DOCKER-USER`**: `PostUp = iptables -I DOCKER-USER -i devmesh -o devmesh -j ACCEPT` / `PostDown = iptables -D DOCKER-USER -i devmesh -o devmesh -j ACCEPT` dentro de `devmesh.conf` (vive y muere con la interfaz). No tocar políticas por defecto ni cadenas de Docker. Antes y después: `iptables-save` a archivo + health check de cada vhost de producción |
| R34 | **Subred y MTU seguras** | Subred poco común (ej. `10.73.0.0/24`, no `10.10.x` ni `192.168.x`) para no chocar con Wi-Fi de hoteles/oficinas. `MTU = 1280` en tablet/celular (redes móviles fragmentan; con 1420 SSH puede colgarse) |
| R35 | **Usuario `tunnel` mínimo** | Shell `/bin/sh` (los comandos forzados se ejecutan con la shell del usuario; `nologin` los bloquearía) y **cada** llave lleva `command=`; `GatewayPorts no`, `PermitTTY no`. Opciones por llave en `authorized_keys`: máquinas → `restrict,port-forwarding,permitlisten="localhost:22xx"` (el túnel se lanza como `ssh -N -R localhost:22xx:localhost:22`, misma cadena `localhost` en ambos lados); tablet/celular → `restrict,port-forwarding,permitopen="localhost:2211",permitopen="localhost:2212",…` (solo saltar a los túneles). `restrict` ya desactiva pty, agent, X11 y user-rc |
| R36 | **sshd de las máquinas no expuesto en redes locales** | `ListenAddress` = IP devmesh + `127.0.0.1` (el túnel llega por localhost); `ClientAliveInterval 15`, `ClientAliveCountMax 3`. En un Wi-Fi público la laptop no ofrece SSH a nadie más. La consola física de la máquina no se ve afectada |
| R37 | **Autoarranque de tmux no puede dejarte sin terminal** | Sin `exec`: si tmux falla, queda la shell normal en vez de cerrarse la ventana |
| R38 | **¿Quién vigila al VPS?** | R26 corre en el VPS: si el VPS cae, no avisa. `lap` revisa cada 2 min que el hub responda; si no, avisa por **ntfy.sh** (topic aleatorio largo), canal que no depende del VPS. El mensaje solo dice "hub caído" (sin IPs ni nombres internos), porque un topic público lo puede leer quien adivine el nombre. La app ntfy del celular suscrita a ambos y con batería sin restricciones |
| R31 | **Calidad de los scripts** | `shellcheck` sin advertencias + tests `bats` para `invite`, `remove`, `ls`, `who` y el script de alta, antes de usarlos en serio |
| R39 | **Hub reproducible desde código** | Todo lo del VPS sale del repo: `make hub HOST=<ip>` instala y configura un VPS Ubuntu limpio (WireGuard, usuarios `tunnel`/`enroll`, sshd, nginx si falta, ntfy, timers, `devmesh`). Idempotente: correrlo dos veces no cambia nada. Nada se edita a mano en el VPS |
| R40 | **Los dispositivos apuntan a un nombre, no a una IP** | Endpoint WireGuard y host SSH del camino B = `hub.example.com` (TTL 300 s), nunca `203.0.113.10`. Máquinas: timer con `reresolve-dns` (wireguard-tools) cada 2 min para seguir al hub si cambia de IP. Tablet/celular: apagar y prender el túnel en la app tras una migración |
| R41 | **Estado respaldado fuera del VPS, cifrado** | Timer diario en el VPS: empaqueta `/etc/wireguard`, `/etc/devmesh`, llaves de host SSH (`/etc/ssh/ssh_host_*`) y datos de ntfy, cifrado con `age` a **tu** llave pública (la privada solo en tus dispositivos). `lap` lo descarga con una llave restringida (`command="cat <último backup>"`). Restaurar las llaves de host evita alertas de "host key changed" en el camino B |
| R42 | **Migración/restauración en minutos, probada** | `make restore HOST=<ip-nueva> BACKUP=<archivo>` (descifra en tu máquina, sube, aplica) + cambiar el registro DNS de `hub.example.com`. Objetivo: hub nuevo operativo en ≤ 15 min + TTL de DNS, sin re-registrar dispositivos. **Simulacro** obligatorio en un VPS temporal o VM local antes de dar la v1 por terminada |

## 2. Principios

1. **Infraestructura propia como camino principal.** Remote Control de Claude es respaldo, no base (depende de Anthropic y se corta).
2. **Varios caminos de entrada que no fallen juntos.**
3. **Todo se levanta solo** (systemd, `Restart=always`).
4. **Una sola fuente de verdad** para las máquinas: el registro en el VPS.
5. **El hub es desechable:** código en git + estado en backup cifrado fuera del VPS. Perder el VPS = levantar otro con `make hub` + `make restore` + cambiar DNS.
6. **Máquinas independientes, VPS sin código de proyectos:** devmesh solo conecta, identifica y avisa; no sabe ni le importa qué herramienta corre cada máquina.
7. **Sin sobreingeniería:** herramientas del sistema (WireGuard, OpenSSH, tmux, systemd, nginx existente) + un script propio pequeño.

## 3. Arquitectura

```
                         ┌───────────────────────────────────────────┐
                         │ VPS 203.0.113.10 (example.com)           │
                         │  WireGuard hub  devmesh  10.73.0.1  (UDP)     │ ← camino A
                         │  sshd (solo llave, usuario "tunnel")      │ ← camino B
                         │  nginx: /devmesh/j/<código> (alta)        │ ← registro
                         │  /etc/devmesh/hosts.tsv  (registro)       │
                         │  devmesh CLI                              │
                         └──────▲───────────────▲────────────────────┘
                   WireGuard    │               │  ssh -R (túnel inverso)
        ┌───────────────────────┼───────────────┼───────────────────────┐
┌───────┴────────┐     ┌────────┴─────────┐     │           ┌───────────┴────┐
│ Tablet / cel   │     │ lap 10.73.0.11   │─────┘           │ pc2 10.73.0.12 │
│  App WireGuard │     │  wg-quick@devmesh    │                 │  (igual)       │
│  Termux        │     │  devmesh-tunnel  │                 └────────────────┘
│   ssh / mosh   │     │  sshd            │
│  App Claude    │     │  tmux "main" (systemd)
└────────────────┘     │  claude remote-control (respaldo)
                       └──────────────────┘
```

### Caminos de entrada

| Camino | Ruta | Depende de | Da |
|---|---|---|---|
| **A. Principal** | Tablet → WireGuard → VPS → máquina → SSH/mosh → tmux | VPS | Shell completa |
| **B. Respaldo** | Tablet → SSH al VPS → túnel inverso → máquina → tmux | VPS (no WireGuard) | Shell completa sin app VPN |
| **C. Emergencia** | App Claude → Remote Control | Anthropic (no VPS) | Solo Claude |

Android permite **una sola VPN activa**; por eso B es SSH puro (sin VPN). El VPS es el único punto que tumba A y B juntos → para eso existe C.

## 4. Componentes

| Pieza | Dónde | Para qué |
|---|---|---|
| WireGuard (`devmesh`) | VPS (hub) + cada dispositivo | Red privada cifrada, en kernel, sin servidor de coordinación |
| sshd | VPS + máquinas | Entrada a la shell; en VPS solo usuario `tunnel` con llave |
| `devmesh-tunnel` (systemd) | Cada máquina | `ssh -N -R localhost:<puerto>:localhost:22 tunnel@vps`, `ServerAliveInterval=15`, `ExitOnForwardFailure=yes`, `Restart=always` |
| `devmesh-tmux` (systemd user + linger) | Cada máquina | Sesión tmux `main` siempre viva aunque nadie haya iniciado sesión |
| tmux-resurrect + continuum | Cada máquina | Restaurar estructura de sesiones tras reboot (no procesos) |
| mosh | Máquinas + Termux | Sesión que sobrevive sleep / cambio de red (camino A) |
| `claude remote-control` (systemd user) | Cada máquina | Camino C; "Enable Remote Control for all sessions" en `/config` |
| Registro `hosts.tsv` | VPS | Fuente de verdad: nombre, IP, puerto de túnel, color |
| `devmesh` CLI | VPS | Alta/baja de máquinas, estado, generación de configs |
| nginx (existente) | VPS | Sirve el script de alta por código (sin secretos de larga vida), con caducidad |
| Usuario `enroll` | VPS | Recibe llaves **públicas** de dispositivos nuevos con una llave desechable de un uso (`expiry-time`, comando forzado) |
| ntfy (binario + systemd) | VPS | Alertas push autenticadas |
| Termux + App WireGuard + App Claude | Tablet / celular | Clientes |

## 4b. Código, estado y recuperación del hub

**Todo como código, en el repo `MYTOOLS/devmesh`:**

```
devmesh/
├── PLAN.md
├── Makefile                 # lint, test, hub, deploy, backup-pull, restore
├── server/                  # everything the hub needs
│   ├── install-hub.sh       # idempotent: packages, users, sshd, devmesh, nginx snippet, ntfy, timers
│   ├── bin/devmesh          # invite, remove, ls, who, hosts, ssh-config, update
│   ├── bin/devmesh-enroll   # forced command for the enroll user
│   ├── lib/                 # wg.sh, registry.sh, keys.sh
│   ├── templates/           # devmesh.conf, enroll-linux.sh, enroll-termux.sh, authorized_keys lines
│   ├── nginx/devmesh.conf
│   └── systemd/             # alert timer, backup timer
├── client/
│   ├── linux/               # dm, tunnel/tmux units, reresolve timer, tmux.conf, sshd drop-in
│   └── termux/              # dm, m, t
└── tests/                   # bats
```

| | Código (repo) | Estado (backup cifrado) |
|---|---|---|
| Qué | Scripts, plantillas, unidades systemd, snippet nginx, instalador | Llave privada del hub + peers (`/etc/wireguard`), registro y `clients.pub` (`/etc/devmesh`), llaves de host SSH, usuarios/tokens de ntfy |
| Dónde | git | VPS + copia `age` en `lap` (y donde quieras) |
| Se recupera con | `make hub HOST=<ip>` | `make restore HOST=<ip> BACKUP=<archivo>` |

**Migrar o recuperar el hub (runbook):**
1. Crear VPS Ubuntu nuevo con tu llave SSH.
2. `make hub HOST=<ip-nueva>` → instala todo desde cero.
3. `make restore HOST=<ip-nueva> BACKUP=<último .age>` → mismo hub, mismos dispositivos, mismas llaves de host.
4. Cambiar el registro A de `hub.example.com` a la IP nueva.
5. Máquinas: se reconectan solas (`reresolve-dns`). Tablet/celular: apagar y prender el túnel WireGuard.
6. `devmesh ls` → todos `up`.

Ningún dispositivo se vuelve a registrar.

## 5. Registro de máquinas: "un código y listo"

### Máquina Linux nueva

```bash
# 1) Desde cualquier lado (tablet, lap): pedir un código
ssh vps devmesh invite pc3
#  → code: 7KQ2-M9XW-4TPA   (válido 15 min, un solo uso)
#  → run on pc3 (one line, copy-paste):
#    curl -fsSLo /tmp/dm-join https://example.com/devmesh/j/7KQ2M9XW4TPA \
#      && echo "<sha256>  /tmp/dm-join" | sha256sum -c && sudo bash /tmp/dm-join

# 2) En pc3: pegar ese comando. Fin.
```

**Regla de seguridad:** el VPS **nunca genera ni guarda llaves privadas de dispositivos**. Cada dispositivo genera las suyas; el VPS solo recibe públicas.

Qué hace `invite` en el VPS:
1. Reserva la siguiente IP libre (`10.73.0.x`), el siguiente puerto de túnel (`22xx`) y un color.
2. Crea una **llave SSH desechable de un uso** y autoriza su pública en el usuario `enroll` con `restrict,expiry-time="<ahora+15min>",command="devmesh-enroll <código>"` (OpenSSH 8.2 en el VPS soporta `expiry-time`). Esa llave solo sirve para entregar llaves públicas a ese hueco reservado.
3. Escribe el script de alta en `/var/www/devmesh/j/<código>`: datos públicos (llave pública del hub, endpoint, IP y puerto asignados, color) + la llave desechable. Imprime su SHA-256 para el comando.
4. El script se borra del webroot al primer uso o a los 15 min (lo que ocurra primero).

Qué hace el script de alta en la máquina nueva:
1. Instala `wireguard openssh-server mosh tmux fzf`.
2. **Genera localmente** su par WireGuard y su llave SSH de túnel.
3. Envía **solo las llaves públicas** con `ssh -i <desechable> enroll@vps`; `devmesh-enroll` valida el código, agrega el peer (`wg set` + persistir), autoriza la llave de túnel con las opciones de R35, marca el código como usado y **revoca la llave desechable**.
4. Escribe `/etc/wireguard/devmesh.conf` (`PersistentKeepalive = 25`) y activa `wg-quick@devmesh`.
5. Instala `devmesh-tunnel.service`, `devmesh-tmux.service`, timer de `clients.pub`; activa linger; configura sshd (R36).
6. Fija hostname, color de tmux y `~/.tmux.conf` base.
7. Imprime: `pc3 ✓ wg 10.73.0.13 · tunnel :2213 · color 94 · key SHA256:…`.

La llave desechable va **cifrada con un segundo secreto** que solo aparece en la línea que imprime `invite` (no en la URL ni en el script publicado): quien solo tenga la URL no puede registrarse. Riesgo residual: quien vea la línea completa dentro de los 15 min obtiene lo mismo que un dispositivo nuevo — shell de usuario en todas las máquinas y acceso `dmadmin` (por diseño, todos los dispositivos son administradores). Mitigación: la línea es de un uso, se pega una vez; `devmesh ls` muestra IP de origen y hora de cada alta; `devmesh remove` si no la reconoces.

### Tablet / celular nuevo

```bash
ssh vps devmesh invite tablet --phone
#  → muestra el comando para Termux (mismo formato: descarga + sha256 + bash, sin sudo)
```

El script de Termux:
1. Instala `openssh mosh fzf wireguard-tools`.
2. Genera localmente llave SSH y par WireGuard; envía solo las públicas (igual que arriba).
3. Escribe `~/.ssh/config.d/devmesh` + funciones `dm`, `m`, `t`.
4. Deja `devmesh-<nombre>.conf` en Descargas (`termux-setup-storage`) → en la app WireGuard: **Importar desde archivo** → el script espera tu confirmación y **borra el archivo** (contiene la llave privada WG del propio dispositivo).

### Llaves de clientes

- Lista central: `/etc/devmesh/clients.pub` en el VPS (solo públicas).
- Cada máquina la sincroniza con un timer de systemd **cada 1 min** a `~/.ssh/authorized_keys.devmesh`.
- Dar de alta o revocar un dispositivo = una línea; se propaga sola.

### Baja

```bash
ssh vps devmesh remove tablet
```

| Paso | Efecto | Cuándo |
|---|---|---|
| Quita el peer de WireGuard en el VPS | Camino A: tráfico nuevo cortado; sesiones abiertas mueren por `ClientAlive` | Inmediato / ≤ 45 s |
| Quita su llave del usuario `tunnel` + `pkill -u tunnel` | Camino B cortado, incluidas sesiones abiertas (los túneles legítimos se reconectan solos) | Inmediato |
| Quita su llave de `clients.pub` | Las máquinas dejan de aceptarla (segunda barrera) | ≤ 1 min |
| Borra su fila del registro | Desaparece de `devmesh ls` / `who` | Inmediato |

- Baja de una máquina (ej. `pc3`): se corta su túnel y su acceso a la red; sus archivos quedan en su disco.
- Camino C: cerrar la sesión de Claude de ese dispositivo desde claude.ai.

## 6. Identificación: sin UI

No hace falta UI. Todo sale del registro:

```bash
ssh vps devmesh ls
# NAME    WG IP        TUNNEL  WG LAST SEEN   TUNNEL   COLOR
# lap     10.73.0.11   :2211   12s ago        up       22
# pc2     10.73.0.12   :2212   48s ago        up       24
# pc3     10.73.0.13   :2213   3h ago         DOWN     94
# tablet  10.73.0.21   —       5s ago         —        —
```

- **Estado:** `wg show` (último handshake) + puerto del túnel escuchando en el VPS.
- **Configs de cliente generadas:** `ssh vps devmesh ssh-config > ~/.ssh/config.d/devmesh` → todas las máquinas con caminos A y B. Una máquina nueva aparece sola tras regenerar.
- **Dentro de cada máquina:** barra de tmux `#H │ #S` con el color del registro.
- **Selector:** `t` (fzf) lista todas las sesiones tmux de todas las máquinas del registro.
- **Dónde está cada sesión** (`devmesh who`):
  ```
  MACHINE  SESSION    TABS                          CONNECTED FROM
  lap      proyectoA  1:claude* 2:zsh 3:logs        tablet, lap (local)
  lap      main       1:zsh                         —
  pc2      proyectoB  1:claude* 2:npm               —
  pc3      OFFLINE
  ```
  "Connected from": `tmux list-clients` (tty) + `who` (IP de origen) → nombre vía registro (IP WG fija por dispositivo).
- **Barra tmux dentro de la máquina:**
  ```
   lap │ proyectoA │ 1:claude*  2:zsh  3:logs                    tablet ●
  ```
- **Menú `dm`** (fzf): Terminales · Nueva terminal · Cerrar terminal · Dispositivos · Agregar dispositivo (código + comando) · Eliminar dispositivo

### Pantallas de `dm` en la tablet/celular

**Terminales** (cada línea con el color de su máquina vía ANSI, `fzf --ansi`):
```
terminal>
● lap:api:1 claude      ⏳ esperando    tablet · hace 2m
● lap:api:2 zsh                         tablet · hace 40m
● lap:main:1 zsh                         local  · hace 3h
● pc2:web:1 claude   ⚙ trabajando    celular · hace 10s
○ pc3  OFFLINE
```

**Nueva terminal** (siempre pregunta dónde):
```
¿En qué máquina?      →  ● lap   ● pc2   ○ pc3 (offline)
¿Qué proyecto?        →  api · web · mobile · (nombre libre)
→ crea lap:api (o ofrece entrar si ya existe) y entra
```

### Cómo se implementa (simple)

- **Color en la lista:** `devmesh ls` ya tiene el color de cada máquina; la lista lo pinta con códigos ANSI y `fzf --ansi`.
- **Rastro (R15):** al crear, se guardan opciones de tmux en la sesión: `@origin` (dispositivo), `@created` (fecha), y la carpeta. `who` y la lista las leen con `tmux ls -F`.
- **Estado de Claude (R16):** hooks de Claude Code en cada máquina marcan la pestaña donde corre:
  - `UserPromptSubmit` → `tmux set -p -t "$TMUX_PANE" @claude working`
  - `Notification` → `... @claude waiting`
  - `Stop` → `... @claude idle`
- **Mismo nombre en la app (R18):** `claude --remote-control "<máquina>:<sesión>"` dentro de tmux.

### Táctil (R23) — verificado en código fuente, 2026-10-20

- **Termux** (`terminal-view/.../TerminalView.java`): cuando el programa activa mouse tracking, al levantar el dedo envía un **clic izquierdo** en esa celda (`onUp` → `MOUSE_LEFT_BUTTON` press + release, sin esperar detección de doble toque); un deslizamiento envía **rueda arriba/abajo** (`MOUSE_WHEELUP/DOWN_BUTTON`).
- **fzf** (man page, v0.74): mouse activo por defecto (`--no-mouse` lo desactiva); clic mueve el cursor al ítem; acción `accept` ligada por defecto a `enter` y `double-click`; `scroll-up`/`scroll-down` soportados.
- **tmux** con `set -g mouse on`: clic en el nombre de una ventana de la barra la selecciona; rueda entra al historial.
- Límite conocido: arrastrar con el dedo no se envía como arrastre de mouse (Termux lo convierte en scroll) → no redimensionar paneles con el dedo; usar `Ctrl+b` + flechas.
- Riesgo residual: la ventana de tiempo de fzf para doble clic vs. velocidad del doble toque. Plan B dentro de v1 (sin cambiar diseño): Enter en el teclado, o `--bind 'left-click:accept'` si el doble toque resulta incómodo.
- Panel web: fase futura, solo dentro de la VPN, sobre la misma CLI. No en v1.

## 7. Configuración de referencia (cliente Termux, generada por `devmesh ssh-config`)

```
Host *
  ServerAliveInterval 15
  ServerAliveCountMax 3

Host vps
  HostName hub.example.com
  User tunnel

Host lap                 # camino A
  HostName 10.73.0.11
  User <usuario>
Host lap-b               # camino B
  HostName localhost
  Port 2211
  User <usuario>
  ProxyJump vps
```

```bash
# Enter a machine: path A with mosh, fallback to path B with ssh
m() { mosh "$1" -- tmux new -A -s main 2>/dev/null || ssh -t "$1-b" tmux new -A -s main; }

# Pick any tmux session on any machine
t() {
  local pick
  pick=$(for h in $(ssh vps devmesh hosts); do
      ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" \
        "tmux ls -F '$h #{session_name} #{?session_attached,●,○} #{pane_current_command}'" 2>/dev/null \
        || echo "$h - OFFLINE"
    done | fzf --prompt='session> ') || return
  set -- $pick
  [ "$2" = "-" ] && return
  mosh "$1" -- tmux new -A -s "$2" 2>/dev/null || ssh -t "$1-b" tmux new -A -s "$2"
}
```

**tmux (en cada máquina):**
```
set -g mouse on
set -g history-limit 50000
set -g window-size latest
setw -g aggressive-resize on
set -g set-clipboard on
set -g status-left-length 40
set -g status-left "#[bold] #H │ #S "
set -g set-titles on
set -g set-titles-string "#H · #S · #W"
source-file -q ~/.tmux.devmesh.conf   # color written by enrollment
```

**Atajos tmux:** `Ctrl+b s` árbol de sesiones · `Ctrl+b c` terminal nueva · `Ctrl+b %`/`"` dividir · `Ctrl+b d` salir sin cerrar.

## 8. Matriz de fallas

| Falla | ¿Sigo trabajando? |
|---|---|
| Se corta el internet de la tablet | ✅ mosh reconecta; tmux conserva todo |
| WireGuard falla (app/config) | ✅ camino B |
| Túnel inverso cae | ✅ systemd lo reinicia; mientras, camino A |
| Máquina se reinicia | ✅ servicios arrancan solos; tmux restaurado (procesos no) |
| Máquina muere | ✅ Alerta (R26); intento encenderla (R27); sigo en las otras, que son independientes |
| Corte de luz | ✅ PCs encienden solas (R27); servicios arrancan (R11); alerta si alguna no volvió |
| Red sin UDP | ✅ Camino B por TCP (R30) |
| VPS cae | ⚠️ solo camino C (Claude) |
| Anthropic cae | ✅ A y B intactos |

## 9. Fases

### Fase 0 — Prueba mínima (manual, sin script) ⬅️ siguiente
- [ ] Antes de tocar el VPS: `iptables-save > /root/devmesh-pre.rules` + health check de cada vhost de producción
- [ ] WireGuard hub en VPS a mano (R32, R33: regla en `DOCKER-USER` vía PostUp/PostDown, `After=docker.service`) + `ufw allow <puerto>/udp`
- [ ] `lap` + tablet con llaves generadas en cada dispositivo, `PersistentKeepalive = 25`, MTU 1280 en tablet
- [ ] Probar **tráfico tablet ↔ lap** (no solo handshakes)
- [ ] Desde la tablet en **datos móviles**: `mosh 10.73.0.11 -- tmux new -A -s main`
- [ ] Túnel inverso manual desde `lap` (`-R localhost:2211:localhost:22`); entrar por camino B con WireGuard apagado
- [ ] Después: health check de producción de nuevo + diff contra `devmesh-pre.rules`

**Éxito:** entro a `lap` por A y por B desde fuera de casa, y producción sigue igual.

### Fase 1 — VPS
- [ ] WireGuard `devmesh` + abrir el puerto UDP elegido; `ip_forward` + FORWARD `devmesh↔devmesh`; `wg-quick@devmesh` habilitado (R32)
- [ ] Reglas de firewall solo agregadas, compatibles con Docker; verificar servicios de producción antes/después (R33)
- [ ] Subred `10.73.0.0/24` (o similar poco común) y MTU 1280 en móviles (R34)
- [ ] Usuario `tunnel`: solo llave, sin shell, `permitlisten` por llave
- [ ] sshd endurecido + `fail2ban` + firewall (R29)
- [ ] `/etc/devmesh/` (hosts.tsv, clients.pub) + location nginx `/devmesh/j/`
- [ ] ntfy binario + systemd detrás de nginx, `deny-all` + token (R26) + timer de alerta de máquina caída
- [ ] Usuario `enroll` + `devmesh-enroll` (comando forzado, llaves desechables con `expiry-time`) (R1)
- [ ] Todo lo anterior escrito en `server/install-hub.sh` (idempotente) y aplicado con `make hub` — nada a mano (R39)
- [ ] Registro DNS `hub.example.com` (TTL 300) y endpoints apuntando a él (R40)
- [ ] Timer de backup cifrado con `age` + descarga desde `lap` (R41)
- [ ] **Simulacro de migración** en VPS temporal o VM local: `make hub` + `make restore` + cambio de DNS, medir tiempo (R42)
- [ ] `vnstat` para medir tráfico del hub
- [ ] Backup de `/etc/wireguard` y `/etc/devmesh`

### Fase 2 — `devmesh` CLI (bash, en VPS)
- [ ] `invite <name> [--phone]`, `remove <name>`, `ls`, `who`, `hosts`, `ssh-config`
- [ ] Menú `dm` (fzf) sobre esos comandos: Terminales (color + ID), Nueva terminal (máquina → proyecto), Cerrar, Dispositivos
- [ ] Metadatos de sesión (`@origin`, `@created`) y hooks de estado de Claude (`@claude`)
- [ ] `devmesh update` + versión por máquina
- [ ] `dm`: Enviar/Traer archivo (R24), Abrir puerto (R25), Encender máquina (R27)
- [ ] `shellcheck` + tests `bats` (R31)
- [ ] `dm` con fzf mouse habilitado (default; nunca `--no-mouse`) y tmux `mouse on` — ver R23
- [ ] Barra tmux con clientes conectados y nombre automático de ventanas (`carpeta:programa`)
- [ ] Script de alta Linux + script de alta Termux
- [ ] Caducidad de códigos (15 min, un uso)
- [ ] Probar con `lap` (reemplaza la config manual de Fase 0)

### Fase 3 — Máquinas
- [ ] Alta de `lap`, luego `pc2`, `pc3` con `invite`
- [ ] No suspender: `HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`
- [ ] tmux-resurrect + continuum
- [ ] BIOS "Restore on AC power loss" + Wake-on-LAN; laptop con carga limitada ~80% (R27)
- [ ] `unattended-upgrades` solo seguridad, reinicio en ventana escalonada (R28)
- [ ] Herramientas de cada máquina (Claude, Codex, …): fuera del alcance de devmesh; cada máquina las configura a su manera
- [ ] Opcional, solo en máquinas con Claude: `claude remote-control` como servicio (binario real, no el alias `flow`) + hooks de estado (R16)

### Fase 4 — Tablet y celular
- [ ] Termux desde **F-Droid o GitHub**; alta con `invite --phone`
- [ ] Android: "Disable child process restrictions", batería sin restricciones, `termux-wake-lock`
- [ ] `extra-keys` ESC/CTRL/TAB/flechas
- [ ] App Claude: "Push when actions required"

### Fase 5 — Automatización (después)
- [ ] Tareas headless (`claude -p`) con timers
- [ ] Revisar la regla de permisos git/gh para sesiones autónomas

## 10. Decisiones

| Decisión | Elegido | Descartado y por qué |
|---|---|---|
| Camino principal | **Infra propia (WireGuard + SSH + tmux)** | Solo Remote Control: depende de Anthropic, se corta, no da shell |
| Red | **WireGuard hub en VPS** | Headscale: más piezas (control plane, nginx especial, UDP 3478), VPS en Ubuntu 20.04 fuera de su soporte. Tailscale Personal: solo no comercial. NetBird Cloud: tercero (posible camino D a futuro) |
| Respaldo shell | **Túnel SSH inverso vía VPS** | Segunda VPN: Android solo permite una activa |
| Registro | **Código de un uso + script verificado por SHA-256**, llaves generadas en el dispositivo, públicas entregadas por SSH con llave desechable | Llaves privadas generadas en el VPS y servidas por nginx (versión anterior): el VPS de producción tendría todas las llaves. Servicio web propio: más piezas |
| Alcance v1 | **Plan completo (R1–R38) con correcciones** — decisión explícita del usuario tras revisión Codex + Grok, que recomendaban recortar | Mínimo sin CLI (Grok), CLI chica (Codex), intermedio (Claude) |
| Identificación | **CLI `devmesh ls` + barra tmux** | UI web (Headplane u otra): superficie expuesta extra |
| Avisos | **ntfy en el VPS** para máquina caída/recuperada (independiente de la herramienta); push de la app Claude solo en máquinas con Claude | Depender solo de la app Claude: no cubre máquinas con Codex ni caídas de máquina |
| Alcance | **Máquinas independientes**; devmesh no gestiona credenciales, repos ni config de herramientas | `devmesh doctor`, lista central de repos, dotfiles compartidos: innecesarios (cada máquina es autónoma) |
| Descartados por simplicidad | — | sesh, Zellij web, ControlMaster, color por hash, MagicDNS en Termux |

## 11. Riesgos

| Riesgo | Mitigación |
|---|---|
| VPS = punto único para A y B | Hub desechable: `make hub` + `make restore` + DNS en ≤ 15 min (R39–R42); mientras tanto camino C |
| Backup cifrado inaccesible (pierdes la llave `age`) | Llave privada `age` en al menos dos dispositivos tuyos; sin ella, plan B = re-registrar dispositivos (minutos cada uno) |
| Todo el tráfico pasa por el VPS (hub) | Latencia según ubicación del VPS; medir en Fase 0 |
| Script de alta interceptado o URL filtrada | Sin secretos de larga vida en el script; SHA-256 verificado; 15 min, un uso; alta visible en `devmesh ls` (IP origen, hora, huella) |
| Llaves de cliente comprometidas (tablet perdida) | `devmesh remove tablet` → A y B cortados al instante, sesiones abiertas ≤ 45 s, máquinas ≤ 1 min |
| Android mata Termux | Solo se corta la vista; `m`/`t` reconectan. Depende del fabricante: probar en Fase 0 |
| Romper producción al configurar el hub | Regla solo en `DOCKER-USER`, snapshot `iptables-save` y health check antes/después |
| Ubuntu 20.04 en VPS sin soporte estándar (terminó 31-may-2025): el hub queda en un SO sin parches estándar | WireGuard (módulo ya presente) funciona; activar actualizaciones de seguridad extendidas (Ubuntu Pro/ESM, verificar condiciones) o planear upgrade del VPS como tarea aparte |
| Mosh prioriza la pantalla actual sobre el historial | El historial y el scroll viven en tmux, no en mosh |
| Límite de uso de Claude compartido entre máquinas | Priorizar tareas |

## 12. Preguntas abiertas

- [ ] Distro de la laptop Linux 24/7
- [ ] Celular: ¿Android o iPhone?
- [ ] Puerto UDP de WireGuard en el VPS y firewall del proveedor
- [ ] ¿Ubicación física del VPS? (latencia del hub)
- [ ] Nombres y proyecto por máquina
- [ ] ¿Git init para `devmesh`?

## 13. Fuentes

- [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) · [Semana 34: device cards](https://code.claude.com/docs/en/whats-new/2026-w34)
- [Headscale reverse proxy](https://headscale.net/stable/ref/integration/reverse-proxy/) · [Headscale instalación](https://headscale.net/stable/setup/install/official/)
- [Tailscale pricing](https://tailscale.com/pricing) · [NetBird pricing](https://netbird.io/pricing)
- [Termux and local DNS](https://admin.brennt.net/termux-and-local-dns) · [Termux releases](https://github.com/termux/termux-app/releases) · [Fix Termux signal 9](https://cosyra.com/guides/termux-signal-9-fix.html)
- Revisión adversarial: Sonnet + Grok (2026-10-20, arquitectura) · Codex + Grok (2026-10-20, plan completo)
- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/) · [WireGuard quickstart](https://www.wireguard.com/quickstart/) · [sshd_config(5)](https://man.openbsd.org/sshd_config) · [sshd(8) authorized_keys](https://man.openbsd.org/sshd) · [ntfy install](https://docs.ntfy.sh/install/) · [Mosh](https://mosh.org/)

## 14. Decisiones de implementación (v0.1.0, 2026-10-20)

| Decisión | Por qué |
|---|---|
| Interfaz WireGuard `devmesh` (no `wg0`) | No chocar con VPNs existentes en el hub o las máquinas |
| Usuario `dmadmin` en el hub con comando forzado + allowlist (`devmesh _ssh <caller>`) | Tablet/celular gestionan dispositivos (`invite`, `remove`, `ls`…) sin shell root en el VPS de producción |
| `dm update` descarga el cliente por SSH (`hub-admin dist`) | Canal autenticado por la llave de host fijada, no por HTTP |
| Lógica de registro en `client/lib/bootstrap_*.sh`; la plantilla solo trae datos + cliente embebido | La lógica se puede testear; el script servido sigue siendo un único archivo verificable por SHA-256 |
| IP → puerto de túnel derivado (`10.73.0.N` → `2200+N`) | Sin otra tabla que mantener |
| `ip_nonlocal_bind=1` en máquinas | sshd puede escuchar en la IP devmesh aunque WireGuard arranque después |
| `ssh.socket` desactivado si existe | La activación por socket ignora `ListenAddress` |
| tmux `main` mantenido por un bucle de usuario (systemd + linger) | Tolera que `main` ya exista y la recrea si el servidor tmux muere |
| Hosts Linux: apt / dnf / pacman / zypper | Distro de la laptop aún desconocida |
| ntfy y age descargados con versión y SHA-256 fijados | ntfy v2.32.0, age v1.3.2 (digests de GitHub) |
| UI de `dm` en inglés | Regla del workspace: mensajes y código en inglés |

## 15. Revisión de seguridad y calidad (2026-10-20) — corregido

| Hallazgo | Corrección |
|---|---|
| Llaves de túnel podían abrir `-L` hacia servicios del VPS (Postgres, Redis…) | `permitopen="localhost:1"` en llaves de máquina y `permitlisten="localhost:1"` en llaves de cliente |
| `_enroll` tomaba el lock antes de leer stdin: un cliente mudo bloqueaba `remove` | Lectura acotada (4 KB, 10 s) **antes** del lock |
| Con solo la URL se podía registrar un dispositivo | Llave desechable cifrada con un secreto que va solo en la línea de `invite` |
| `restore` aceptaba symlinks dentro de rutas permitidas | Solo archivos y directorios, sin setuid, `--no-same-owner` |
| Nombre `pc3-b` podía secuestrar el alias del camino B de `pc3` | Nombres terminados en `-b` prohibidos |
| `remove` podía no matar túneles si fallaba WireGuard | Archivos → `pkill -u tunnel` → recién después WireGuard |
| `grep -q` en pipelines con `pipefail` podía saltarse chequeos de unicidad | `in_list` (lee toda la entrada antes de comparar) |
| `~/.ssh/config` generado con `Host … *` rompía `git push` a github.com | Bloque común solo para alias devmesh explícitos |
| Túneles muertos ocupaban el puerto en el hub ~2 h | `ClientAliveInterval 15` / `CountMax 3` para `tunnel`, `enroll`, `dmadmin` |
| `restore` no recargaba las llaves de host restauradas | `sshd` se reinicia tras `restore` |
| Registro no reanudable si fallaba a mitad | `node.conf` se escribe apenas el hub acepta |
| Termux podía dejar la llave privada WG en Descargas | Archivo con `umask 077` y borrado en cualquier salida (trap) |
| Token de ntfy visible en `ps` | Va por `curl -K -` (stdin) |
| `/tmp/dm-join` fijo, código en logs de nginx, ntfy ajeno sobrescrito | `mktemp`, `access_log off`, no se pisa un `server.yml` que no sea de devmesh |
| `find` + `pipefail` cortaba `dm send/fetch` en silencio; menú perdía `errexit` | Rutas inexistentes toleradas; cada acción del menú corre como proceso `dm` aparte |
| R21 y R28 no implementados | Versión por máquina en `devmesh ls` (reportada por key-sync); `unattended-upgrades` con ventana de reinicio escalonada por IP (03:00–05:59) |

Pendiente consciente: R18 (mismo nombre en la app de Claude) queda manual: `claude --remote-control "<máquina>:<sesión>"`. Riesgo aceptado: `dm update`/`dm refresh` confían en el hub (si el hub se compromete, la flota también).

## 16. Prueba de integración real (2026-10-21)

`make integration`: hub Ubuntu 20.04 (con `FORWARD DROP` + `DOCKER-USER` como un VPS típico con Docker), `lap` Ubuntu 24.04 (sshd por socket), `pc2` Ubuntu 22.04, y `hub2` para el simulacro de migración. systemd, sshd, WireGuard, tmux, nginx (TLS) y ntfy reales. Resultado final: **53/53**.

Cubre: instalación e idempotencia del hub, sshd global intacto, regla en `DOCKER-USER`, registro con la línea exacta de `invite`, WireGuard peer↔peer a través del hub, camino A y B con llaves fijadas, sshd no expuesto en la LAN, tmux `main` vivo, `dm who`, vista previa de UI por `ssh -L`, archivos, versión reportada, allowlist de `dmadmin`, bloqueo de `-L`/`-R` en el usuario `tunnel`, alertas por ntfy autenticado, revocación inmediata, y migración completa (backup → restore en VPS nuevo → cambio de DNS → las máquinas siguen solas al hub nuevo).

Bugs reales que solo apareció con sistemas reales (corregidos):

| Bug | Impacto | Corrección |
|---|---|---|
| `expiry-time="…Z"` | OpenSSH 8.2 (Ubuntu 20.04, tu VPS) descarta la llave: **ningún registro funcionaba** | Hora local sin `Z` |
| `apt-get install wireguard-tools` sin `--no-install-recommends` | En 20.04 instalaba kernels, firmware e initramfs en el host de producción (30 paquetes vs 3) | `--no-install-recommends` (y `install_weak_deps=False` en dnf) |
| nginx recién instalado no arrancado | Instalación del hub fallaba en un VPS sin nginx | `reload-or-restart` |
| `server.yml` por defecto de ntfy tomado como ajeno | Instalación fallaba | Solo se rechaza si tiene configuración activa |
| `/run/sshd` ausente con sshd por socket (Ubuntu ≥ 22.10) | Registro de máquinas 24.04 fallaba | Se crea antes de `sshd -t` |
| `trap` con variable local en `devmesh-node keys-sync` | Cada sync sin cambios terminaba en error y dejaba temporales | Variable global |
| Alertas publicadas por la URL pública del propio hub | Dependían de DNS/TLS/hairpin; no llegaban | ntfy local `127.0.0.1:2586` |
| `trap` de Termux pisaba el del bootstrap | Podía quedar la carpeta con la llave desechable | Trampa encadenada |
| Chequeo de WireGuard con `modprobe` | Falla con WireGuard compilado en el kernel | Prueba creando una interfaz |

Lo que sigue sin probarse en real: Termux/Android (no hay emulador en este entorno; la lógica está cubierta con tests unitarios y de protocolo), Let's Encrypt real (la prueba usa certificado propio), y un VPS real con otros servicios.

## 17. sshd propio del hub y fail2ban (2026-10-21)

Decisión para convivir con un VPS que ya corre otros servicios, sin tocar su sshd:

| Decisión | Detalle |
|---|---|
| **`devmesh-sshd` propio, puerto 2222** | Servicio aparte (`/etc/devmesh/sshd_config`, llave de host propia en `/etc/devmesh`). El sshd del sistema (puerto 22) **no se toca**: ni drop-ins ni reload. Solo `tunnel`, `enroll`, `dmadmin`; `AuthenticationMethods publickey`, `PermitRootLogin no`, sin TTY, forwarding solo para `tunnel`, `MaxAuthTries 3`, `LogLevel VERBOSE`. Abre `2222/tcp` en ufw |
| **fail2ban** | `jail.d/devmesh.conf`: el jail `sshd` banea en `ssh,2222` y conserva sus `ignoreip` + agrega `10.73.0.0/24` (tráfico por la VPN nunca cuenta) |
| **Máquina revocada no insiste** | `devmesh-node` detecta "Permission denied" del hub y espera 1 h entre intentos (túnel y key-sync), para que fail2ban no banee la IP pública compartida con otros dispositivos |
| Backup | La llave de host vive en `/etc/devmesh` (incluida en el backup sin duplicados) |

Integración: 60/60 (agrega: sshd del sistema sin archivos devmesh, devmesh-sshd en 2222, root y contraseñas rechazados en 2222, fail2ban cubre 2222 e ignora la VPN, máquina revocada en back-off y no baneada). Bug encontrado por la integración y corregido: entradas duplicadas en el backup se guardaban como hardlink y `restore` las rechazaba.
