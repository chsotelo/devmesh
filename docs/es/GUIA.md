# devmesh — Guía de uso

**Todas tus terminales, en todos tus equipos, desde cualquier lugar.**
Versión en inglés: [../en/GUIDE.md](../en/GUIDE.md).
devmesh conecta tus máquinas de desarrollo, tu Mac, tu tablet y tu celular en una red privada. Desde cualquiera de ellos ves las terminales abiertas en las demás, entras a la que quieras, creas nuevas y mueves archivos, aunque estés fuera de casa.

---

## Cómo funciona, en 30 segundos

| Pieza | Qué es | Ejemplos |
|---|---|---|
| **Hub** | El centro de control. Coordina la red privada, recibe los registros y te avisa si algo se cae | `hub.example.com` o `203.0.113.10` |
| **Máquina** | Un equipo Linux donde trabajas. Sus terminales viven en tmux y se pueden ver desde cualquier lado | Tu laptop 24/7, otras PCs |
| **Control** | Un equipo desde el que manejas las máquinas | Tu Mac |
| **Móvil** | Tablet o celular Android con Termux | Tu tablet, tu celular |

Cada dispositivo tiene hasta tres caminos para llegar a las máquinas:
- **Camino L (misma red local):** directo, sin pasar por el hub. Solo en las redes que marcaste
  como de confianza en esa máquina (ver "Directo en tu red local").
- **Camino A (VPN WireGuard):** pasa por el hub.
- **Camino B (túnel por el hub):** se usa solo si la VPN no está disponible.

No tienes que elegir: `dm` usa el que funcione.

---

## 0. Instala el hub

Necesitas un servidor pequeño con dirección pública: Ubuntu 20.04+ o Debian 11+ (o cualquier Linux con Docker), 1 vCPU y 512 MB. Abre **UDP 51820** y **TCP 2222**, más **TCP 443** (modo dominio) o **TCP 8443** (modo IP). Con dominio, el puerto 80 también debe llegar para el desafío de Let's Encrypt.

### Instalador guiado

```bash
curl -fsSL https://raw.githubusercontent.com/chsotelo/devmesh/main/install.sh | sudo bash
```

Busca la última versión, la verifica contra `SHA256SUMS` y te pregunta:
1. **Dominio o IP** del servidor (te propone la IP pública detectada).
2. **Correo**, solo si es dominio (Let's Encrypt).
3. **Llave pública de backup** (`age1…`), o vacío para no tener backup externo.

Para saltarte las preguntas, define `HUB_HOST` (y `ACME_EMAIL` si es dominio) en el entorno.

### Modo dominio y modo IP

| | Modo dominio | Modo IP |
|---|---|---|
| `HUB_HOST` | `hub.example.com` | `203.0.113.10` |
| Certificado | Let's Encrypt | autofirmado |
| Puerto web | 443 | 8443 |
| Línea para unirse | `curl -fsSL https://hub.example.com/j/<código> \| sh -s <secreto>` | `curl -fsSL --pinnedpubkey 'sha256//…' -k https://203.0.113.10:8443/j/<código> \| sh -s <secreto>` |

En modo IP ninguna autoridad avala al hub, así que `-k` desactiva esa validación y `--pinnedpubkey` ata la conexión al certificado del propio hub. curl sigue exigiendo la huella.

### Desde el repo, por SSH

```bash
make hub HOST=root@203.0.113.10 HUB_HOST=hub.example.com ACME_EMAIL=tu@example.com
```

Es idempotente: vuelve a correrlo para actualizar un hub existente. Agrega `BACKUP_RECIPIENT=age1…` para activar el backup cifrado y `SSH="ssh -i ~/.ssh/id_ed25519"` para elegir llave. Para no escribirlos cada vez, copia `deploy.local.mk.example` a `deploy.local.mk` (git lo ignora) y corre solo `make hub`. Despliega una versión publicada (`git checkout vX.Y.Z`), no algo a medio hacer.

### Con Docker

```bash
HUB_HOST=203.0.113.10 docker compose -f docker/hub/compose.yml up -d --build
docker compose -f docker/hub/compose.yml exec hub devmesh invite lap
```

El contenedor usa la red del host. fail2ban y el sysctl `net.ipv4.ip_forward` son del host. Detalles y límites: [../../docker/hub/README.md](../../docker/hub/README.md).

### El primer dispositivo

En el hub, como root:

```bash
devmesh invite mac
```

Pega en el dispositivo la línea `JOIN:` que imprime (siguiente sección). Los demás se agregan desde cualquier dispositivo ya unido con `dm add`.

---

## 1. Tu Mac como máquina

Tu Mac comparte sus terminales igual que una máquina Linux. Las ves y las creas desde la tablet o el celular.

- **Toda terminal nueva** que abras en la Mac arranca dentro de tmux y aparece en el panel de tus otros dispositivos.
- **Siempre existe una terminal `main`,** aunque no tengas ninguna ventana abierta.
- **Nadie puede entrar a tu Mac desde la red:** su acceso escucha solo en la propia Mac (`127.0.0.1`), y tus dispositivos llegan a ella únicamente por el túnel cifrado del hub, con su llave.

---

## 2. Agrega cualquier dispositivo: un nombre, una línea

**En un dispositivo ya conectado** (por ejemplo la Mac):

```bash
dm add tablet
```

No te pregunta nada. Para una **máquina Linux** puedes sumar dos opciones: `--lan home` (para encenderla a distancia) y `--watch-hub` (te avisa si el hub se cae):

```bash
dm add lap --lan home --watch-hub
```

Te aparecen tres cosas:
1. **La línea para unirse**, que ya queda **copiada en tu portapapeles**:
   ```
   JOIN: curl -fsSL https://hub.example.com/j/K7Q2M9XW4TPA | sh -s 4TPAZ85XR6QX
   ```
2. **Un código QR** con esa misma línea, para escanear con el celular.
3. Con `--watch-hub`, el tema de ntfy.sh para esas alertas.

**En el dispositivo nuevo**, sea cual sea, pegas la línea y presionas Enter:

| Dispositivo | Dónde pegarla | Qué pasa |
|---|---|---|
| **Linux** (laptop, PC) | En una terminal, con tu usuario normal | Te pide tu contraseña de `sudo` y queda como **máquina**: sus terminales se ven desde cualquier lado y siempre existe la terminal `main` |
| **Mac** | En Terminal | Sin `sudo`. Queda como **control**. Para la VPN, importa `~/.config/devmesh/wireguard/devmesh.conf` en la app WireGuard |
| **Android** (Termux) | En Termux. Desde el QR: lo escaneas con la cámara, copias el texto y lo pegas | Te pide importar `Download/devmesh-<nombre>.conf` en la app WireGuard y presionar Enter. El archivo se borra solo |

El dispositivo **detecta solo** qué es. No eliges nada.

> La línea sirve **una sola vez** y vence a los **15 minutos**. La segunda parte es un secreto: nunca llega al servidor ni a ningún log. Si te equivocas, `dm rm` cancela la invitación y deja la línea inutilizable al instante.

**Antes de agregar un Android:** instala **Termux** desde **F-Droid** (no desde Play Store) y la app **WireGuard**. Después, para que Android no corte tus sesiones:
- *Ajustes → Opciones de desarrollador →* **Disable child process restrictions**
- *Batería → Termux →* **Sin restricciones**

En la Mac, `dm` necesita bash 4+ y Homebrew (`brew install bash`); se relanza solo con el bash de Homebrew si lo encuentra.

---

## 3. El día a día: un solo espacio de trabajo

En cualquier dispositivo escribe:

```bash
dm
```

Se ve como el panel de terminales de VS Code: **una pestaña por máquina arriba, la lista de
terminales de esa máquina a la izquierda y la terminal real a la derecha**.

```
 devmesh │ ● laptop  desktop  ○ builder                   + │ 🗑 │ ✕   ← máquinas (pestañas) y botones
▎ >_ api              ● │ $ claude
  >_ web                │   I updated the auth middleware…
  >_ docs             ● │   Edit src/auth.ts?   (la terminal elegida, en vivo)
```

- **Barra de arriba = selector de máquina.** La pestaña activa va brillante con el color de la
  máquina; las demás en gris; una máquina apagada muestra `○`. Toca o haz clic para cambiar.
- **Izquierda = terminales de la máquina,** una fila cada una, con un punto del agente que corre
  en ella (amarillo esperando, azul trabajando, verde en reposo). Toca una fila (o `enter`) y se
  muestra a la derecha; flechas o `j`/`k` para moverte; la lista se actualiza cada 3 segundos.
- **Botones (arriba a la derecha):** `+` terminal nueva (escribes un nombre), `🗑` eliminar la
  terminal en pantalla (pregunta antes), `✕` salir: todo sigue corriendo y el próximo `dm` te
  devuelve al mismo lugar. Teclas: `Ctrl+a +`, `Ctrl+a x`, `Ctrl+a d`.
- **Celular:** con menos de 70 columnas la lista se oculta y la terminal ocupa la pantalla; `☰`
  (o `Ctrl+a s`) alterna entre la lista y la terminal, y al elegir una fila vuelves a la terminal.
- **Si se corta la conexión, la terminal se reconecta sola.**
- Requiere tmux 3.2 o superior y el binario `dm-tui`. Sin ellos, o con `DM_UI=cards` /
  `DM_UI=fzf`, `dm` usa el panel de tarjetas / el de fzf que se describen a continuación.

Panel de tarjetas (`DM_UI=cards`): está hecho para el tacto (un celular o una tablet vertical en Termux) y también funciona con teclado y mouse:

```
 ‹ volver  devmesh 0.8.1 › laptop            [nueva] [↻] [enviar] [web]  <- botones: tócalos
 ● laptop  3 terminales                                          [nueva]
╭─────────────────────────────────╮ ╭────────────────────────────────╮
│ api                 ● esperando │ │ web                            │  <- una tarjeta por terminal:
│ claude · tablet             40s │ │ node · laptop               5m │     nombre, estado, comando,
│ ── tablet ───────────────────── │ │ ────────────────────────────── │     origen, última actividad,
│ I updated the auth middleware … │ │ $ npm run dev                  │     conectados y una miniatura
│ Edit src/auth.ts?               │ │ VITE v6 ready in 312 ms        │     en vivo de su pantalla
╰─────────────────────────────────╯ ╰────────────────────────────────╯
 ○ desktop  sin conexión                                     [despertar]
                  enter abrir  n nueva  / filtrar  ? atajos  q salir
 tablet · 3 máquinas · 3 terminales · 1 esperando                       <- estado + atajos
```

- **Tarjetas, no una lista:** cada máquina es una sección y cada terminal una tarjeta. La cuadrícula tiene una columna en un celular, dos en una tablet vertical y más en una pantalla ancha. La miniatura muestra tantas líneas como quepan.
- **Detalle:** en una pantalla angosta `enter` (o tocar una tarjeta ya elegida) abre el detalle de la terminal: una vista en vivo grande con `[abrir]`, `[enviar archivo]` y `[web]`; `esc` vuelve. Desde 140 columnas el detalle es un panel junto a las tarjetas y `enter` abre la terminal directamente.
- **Las máquinas apagadas** salen atenuadas con su botón `[despertar]` (Wake-on-LAN a través de otra máquina de la misma red). Una máquina sin terminales lo dice y ofrece `[nueva]`.
- **Se actualiza solo:** las máquinas cada 4 segundos y las miniaturas de las tarjetas a la vista cada 3 segundos. Una máquina lenta o caída nunca bloquea el panel.
- **Tacto:** toca una tarjeta para elegirla y tócala otra vez para abrirla; los botones de arriba y los de cada máquina se tocan; la rueda desplaza.
- **Nueva terminal:** `n` (o `[nueva]`). Elige la máquina (se omite si solo tienes una), luego el proyecto, o **escribe el nombre** en la caja de abajo: al escribir se filtran los proyectos y aparece `+ Nueva terminal "<nombre>"`. Se abre como pestaña nueva y el panel sigue ahí.
- **Agregar dispositivo:** `a`, escribe su nombre (ej. `lap`) y enter. Aparecen la línea de un solo uso y el código QR. Si aún no hay máquinas, la primera pantalla lo explica y ofrece `[agregar equipo]`.
- **Filtrar:** `/` y escribe; `esc` borra el filtro, y `esc` en la pantalla principal sale.

| Tecla | Acción |
|---|---|
| flechas · `h j k l` | Moverse entre tarjetas y máquinas |
| `enter` | Abrir la terminal o su detalle; abrir el menú de una máquina; despertar una apagada |
| `o` | Abrir la terminal elegida |
| `n` | Nueva terminal (en la pantalla de una máquina, en esa máquina) |
| `s` · `f` | Enviar archivo · traer archivo |
| `w` | Ver aquí el servidor web de una máquina |
| `d` · `a` | Listar dispositivos · agregar dispositivo |
| `r` | Actualizar |
| `/` | Filtrar terminales |
| `esc` | Volver (en la pantalla principal: borra el filtro y luego sale) |
| `?` | Ver todos los atajos |
| `q` · `ctrl+c` | Salir del panel |

- El panel es el programa `dm-tui` que viene con el cliente. Solo dibuja: todo lo que toca una máquina lo hace `dm`, como antes. Donde no hay `dm-tui` para tu sistema, o con `DM_TUI=0 dm`, se usa el panel clásico con fzf (con un fzf anterior a 0.66, una versión de un menú a la vez). Sin tmux, el panel corre sin pestañas.
- `Ctrl+a p` vuelve al panel y `Ctrl+a n` pasa a la pestaña siguiente.

### Sesiones de Claude

La lista de la izquierda muestra las **sesiones de Claude Code** de esa máquina con el nombre
que les pusiste (`claude --name "19Oct - redi general"`) y una palabra de estado:
`trabajando`, `te espera` o cuánto llevan sin usarse (`20 min`, `5 h`, `3 d`). Tócala y se
abre a la derecha: escribes ahí como siempre. devmesh lee el registro de sesiones que el
propio Claude Code mantiene; no hace falta instalar nada.

- **Detener:** elige una sesión y toca `Detener`. Se cierra y libera su memoria, y queda en
  `Historial ›`. Si hay sesiones sin usar hace más de 1 h, una línea ofrece detenerlas todas.
- **Solas a las 2 h:** las sesiones que corren en devmesh y llevan 2 h sin usarse se detienen
  solas cada 5 minutos (`DM_CLAUDE_AUTOSTOP_MIN=0` lo desactiva). Su terminal no se cierra: queda
  dormida mostrando la sesión, y Enter la retoma ahí mismo con toda la conversación. Las que no
  corren dentro de tmux nunca se tocan.
- **Cerradas a mano:** cuando Claude termina en una terminal de devmesh (`/exit`, Ctrl+C), la
  línea `claude --resume …` que imprime ya queda escrita en el siguiente prompt: Enter la retoma,
  Ctrl+C la descarta.
- **Historial ›:** las sesiones detenidas con nombre de los últimos 30 días, con buscador.
  `Reanudar` la abre donde quedó, con toda la conversación.
- **＋ Nueva:** un nombre (viene con la fecha, `27Oct - `) y una carpeta de proyecto; abre
  `claude --name` ahí.
- **Mover a <máquina>:** detiene la sesión aquí y la retoma en la otra máquina con toda la
  conversación; desde entonces la memoria, el procesador y los comandos son de esa máquina
  (tú la sigues viendo y escribiendo desde donde estés). La otra máquina necesita Claude
  instalado y el mismo proyecto en `~/PROJECTS` con el mismo commit: si hay cambios sin
  commit o los commits no coinciden, te dice qué hacer en vez de mover.
- **Terminales ›:** tus terminales normales, como siempre.
- **`⏻` suspender, apagar, despertar:** solo se ofrece lo que se puede deshacer desde aquí.
  Una máquina se suspende o se apaga solo si otra máquina en línea comparte su red de
  confianza y tiene Wake-on-WLAN activo, para poder despertarla. Apagar pide confirmar dos
  veces y solo se vuelve a prender con su botón. La máquina donde estás nunca se apaga sola.

### Idioma

El panel y los mensajes de alta de dispositivos salen en **inglés** por defecto. Para español usa `DM_LANG=es` (por ejemplo `DM_LANG=es dm`) o un idioma del sistema en español (`LANG=es_PE.UTF-8`). Lo que falte en la traducción sale en inglés.

Atajos si prefieres comandos:

| Quieres… | Escribe |
|---|---|
| Abrir el panel | `dm` · `t` |
| Nueva terminal (guiada) | `dm new` · o directo en una máquina: `dm new mac` |
| Entrar directo | `dm go mac api` |
| Mandar / traer archivos | `dm send` · `dm fetch` |
| Ver la web de una máquina | `dm port` (se detiene con `dm port stop`) |
| Ver / cambiar lo que una máquina expone en la malla | `dm mesh` |
| Ver todas las terminales | `dm list` · `dm who` (tabla con estado del agente y clientes) |
| Cerrar una terminal | `dm close` |
| Dispositivos · agregar · quitar | `dm devices` · `dm add <nombre>` · `dm rm` |
| Encender una máquina | `dm wake <máquina>` |
| Traer la lista de dispositivos | `dm refresh` |
| Seguir al hub si cambió de dirección | `dm repoint <ip-o-host>` |
| Avisar el estado del agente (hooks) | `dm agent working\|waiting\|idle\|clear` |

### Dentro de una terminal (tmux)

| Atajo | Qué hace |
|---|---|
| `Ctrl+b` `s` | Ver y saltar entre sesiones y pestañas |
| `Ctrl+b` `c` | Pestaña nueva |
| `Ctrl+b` `,` | Renombrar la pestaña |
| `Ctrl+b` `%` · `Ctrl+b` `"` | Dividir la pantalla |
| `Ctrl+b` `d` | **Salir sin cerrar nada**: todo sigue corriendo |
| Tocar una pestaña en la barra | Cambiar a ella |

La barra de abajo siempre te dice dónde estás: **máquina │ sesión │ pestañas │ quién está conectado**, con el color de esa máquina.

### Terminales de VS Code

En una máquina, `dm vscode on` agrega un perfil de terminal `devmesh` a VS Code (y a VS Code
Insiders y Cursor, si están instalados). Las terminales que abras desde ese momento arrancan
dentro de tmux, con el nombre de la carpeta del proyecto (una segunda en la misma carpeta es
`<proyecto>-2`), así otros dispositivos las ven y pueden entrar a la misma terminal en vivo.

- `dm vscode status` muestra, por archivo de configuración, si está `on`, `off`, `not-json` o `missing`.
- `dm vscode off` quita el perfil y restaura tu terminal predeterminada anterior.
- Los archivos de configuración con comentarios o comas finales no se modifican: `dm` imprime
  el fragmento para pegar. Antes del primer cambio se guarda una copia `settings.json.devmesh-bak`.
- Las terminales siguen corriendo cuando cierras VS Code. Usa el mouse para desplazarte (el mouse de tmux está activo).
  `Ctrl+b` es la tecla prefijo de tmux.

---

### Firewall de la malla

Las máquinas Linux solo responden a los demás dispositivos de la malla por **SSH, mosh y ping**.
Un servidor de desarrollo o una base de datos que escuche en `0.0.0.0` no es alcanzable desde
los otros dispositivos ni desde el hub. Para abrir un puerto a propósito (requiere root):

```bash
sudo devmesh-node mesh open tcp/8000        # también tcp/8000-8010 o udp/5353
sudo devmesh-node mesh close tcp/8000
devmesh-node mesh status                    # o simplemente: dm mesh
```

`dm mesh` no pide root: muestra qué está abierto e imprime el comando `sudo` exacto para
cambiarlo. Las máquinas que se unieron antes reciben el firewall con `dm update`.

### Directo en tu red local

Si tu Mac, tu tablet y una máquina están en la misma red (tu casa, tu oficina), `dm` se conecta
directo a la máquina, sin dar la vuelta por el hub: la latencia pasa de la del VPS a la de tu
WiFi. Se activa por red, en cada máquina, estando conectada a esa red (requiere root):

```bash
sudo devmesh-node lan trust       # confía en la red en la que está ahora (subred + router)
sudo devmesh-node lan forget      # deja de confiar en todas
devmesh-node lan status           # ¿está directo ahora?
```

La red se reconoce por su subred **y** por su router: una cafetería con la misma subred tiene
otro router y no cuenta. Fuera de tus redes de confianza, SSH ni siquiera escucha en la red
local (en un WiFi público, nadie la ve). La llave de host es la misma que por el hub, así que si
la dirección cambió o es otra máquina, la conexión se rechaza y `dm` usa el hub. Los
dispositivos aprenden la dirección solos, desde la máquina, y la vuelven a preguntar cada 30
minutos; la máquina revisa en qué red está cada minuto.

Para servidores web y bases de datos usa mejor `dm port`: va dentro de SSH, así que no se abre
nada y nada cruza la malla sin cifrar. El hub no puede leer tus sesiones SSH, pero sí cualquier
servicio sin cifrar que abras y que cruce la malla a través de él (la malla es una estrella).
macOS y Android/Termux no tienen este firewall: en macOS SSH escucha solo en `127.0.0.1` y los
teléfonos normalmente no ofrecen servicios.

En el hub la misma idea protege al propio VPS: desde la malla solo entran SSH en 2222 y ping, y
los contenedores publicados por Docker no se alcanzan por la dirección de la malla.

## 4. Alertas en el celular

Instala la app **ntfy** y suscríbete a:
- **Servidor:** `https://hub.example.com` (en modo IP, `https://203.0.113.10:8443`)
- **Tema:** `devmesh`
- **Usuario:** `devmesh-sub`. La contraseña está en el hub, en `/etc/devmesh/ntfy-subscriber.txt`, y solo root puede leerla.

Te llegará un aviso cuando una máquina se caiga y cuando vuelva (cuando lleve 5 minutos arriba, así una Mac dormida que despierta unos segundos de vez en cuando no te avisa cada vez). Si al agregar la laptop activaste "vigilar el hub", ese mismo `dm add` te dio un tema de **ntfy.sh**. Suscríbete a él para enterarte si el propio hub se cae.

**Claude te necesita.** En cada máquina donde uses Claude Code, corre una vez `dm notify on`. Cuando una sesión pida permiso, o lleve un minuto esperando tu respuesta, y no hayas tocado esa máquina en 2 minutos (teclado, mouse o una terminal conectada desde otro dispositivo), la misma app mostrará "Claude on <máquina>: <proyecto>" (el mismo aviso como mucho una vez cada 10 minutos). Agrega un hook `Notification` a `~/.claude/settings.json`, junto a tus propios hooks; `dm notify off` quita solo ese hook.

---

## Aprobar dispositivos

Con aprobadores, un hub comprometido no puede dar acceso, suplantar una máquina ni distribuir código: los dispositivos solo confían en llaves que firmó uno de *tus* dispositivos.

- **Primer aprobador (dueño).** En el hub: `devmesh invite <nombre> --owner` (solo mientras el hub no tenga ninguno). El dispositivo que se une con esa línea confía en su propia llave.
- **Un dispositivo nuevo se une** y queda `pending` (`dm devices`). Al final imprime sus huellas: `Approve on an approver device: dm approve <nombre> (check: client SHA256:..., host SHA256:...)`.
- **Aprobar** en un aprobador: `dm approve` lista lo que espera; `dm approve <nombre>` pide la comprobación. Las huellas no se muestran: léelas en el dispositivo nuevo (las imprime al final de unirse, o `dm trust status` allí) y escribe los últimos 16 caracteres de la huella de host (máquinas) o de cliente (teléfonos, Macs). `--signer` lo vuelve también aprobador. (`--yes` es solo para pruebas, `DM_TEST=1`.)
- **Quitar.** `dm rm` en un aprobador también firma una revocación: los dispositivos descartan esa llave y nunca vuelven a aceptar una aprobación vieja de ella.
- **Instalación existente (0.7).** En el hub: `devmesh owner <dispositivo>`. En ese dispositivo: `dm trust pin` y luego `dm trust init` (pide, por dispositivo, los últimos 16 caracteres de su huella; `--i-checked-all` lo omite: peligroso). En cada máquina: `dm trust pin` (imprime los `sudo` necesarios). `dm trust pin --reset` reemplaza a los aprobadores (escribe el final de la huella del dueño, leída con `dm trust status` en el dueño). `dm trust status` muestra el modo, los aprobadores y lo pendiente.
- En modo firmado, un dispositivo sin `allowed_signers` se niega a sincronizar, refrescar o actualizar en vez de volver al modo abierto.
- **Actualizaciones automáticas.** Con aprobadores, cada dispositivo se actualiza solo y solo a versiones firmadas por un aprobador: las máquinas Linux cada 30 minutos (`devmesh-update.timer`, sin `sudo` ni nadie conectado), la Mac y el teléfono al abrir `dm`. Para publicar una versión, despliega el hub desde un aprobador (`make hub` firma el bundle). Sin aprobadores no se actualiza nada solo: usa `dm update`. `DM_AUTO_UPDATE=0` lo apaga en la Mac o el teléfono.
- Límite conocido: la confianza parte de la línea de unión y de las huellas que comparas; hazlo en un dispositivo que tengas en la mano.

## 5. Si pierdes un dispositivo

En cualquier otro dispositivo escribe:

```bash
dm rm
```

Elige el dispositivo y escribe su nombre para confirmar. En ese mismo instante pierde la VPN, el túnel y el acceso al hub, y en menos de un minuto todas tus máquinas dejan de aceptar su llave.

---

### Abrir un servicio del propio hub a la malla

Para que todos los dispositivos lleguen a un servicio que corre **en el hub** (por ejemplo un
tablero de tareas en `10.73.0.1:8730`), agrega el puerto a `/etc/devmesh/hub.conf` y reaplica las
reglas sin tumbar el túnel (como root, en el hub):

```bash
# /etc/devmesh/hub.conf: TCP por defecto, "puerto/udp" para UDP; separa con espacios o comas
HUB_OPEN_PORTS="8730 9000/udp"

devmesh-fw up devmesh              # idempotente: reconstruye la cadena DEVMESH-HUB-IN
iptables -S DEVMESH-HUB-IN         # verifica
```

Solo se abre hacia la malla (interfaz `devmesh`), nunca hacia internet. Las entradas inválidas se
ignoran con un aviso. El servicio debe escuchar en `10.73.0.1` o en `0.0.0.0`.

## 6. Mantenimiento (solo cuando haga falta)

| Tarea | Cómo |
|---|---|
| Actualizar `dm` en un dispositivo | `dm update` (con aprobadores es automático, ver abajo) |
| Actualizar el hub | desde el repo: `make hub HOST=root@203.0.113.10 HUB_HOST=hub.example.com SSH="ssh -i ~/.ssh/id_ed25519"` |
| Bajar el último backup del hub | `make backup-pull` (queda cifrado en `backups/`) |
| Ver el estado del hub | en el hub, `devmesh ls` y `devmesh check` |
| Mudar el hub a otro VPS | `make restore HOST=root@<ip-nueva> BACKUP=backups/<archivo> HUB_HOST=<host>` |

> **Importante:** los backups se cifran con una llave pública `age` y necesitas la llave privada para abrirlos (`make restore` la lee de `~/.config/devmesh/backup.agekey`, o usa `AGE_IDENTITY=`). **Copia ese archivo a un segundo lugar seguro.** Sin él, los backups no se pueden abrir.

### Mudar el hub

- **Modo dominio:** después de `make restore`, apunta `hub.example.com` a la nueva IP. Tus dispositivos lo siguen solos.
- **Modo IP:** la dirección cambia y los dispositivos siguen apuntando a la vieja. En cada dispositivo corre una vez:
  ```bash
  dm repoint 198.51.100.7
  ```
  `dm repoint` reescribe la dirección del hub, el endpoint de WireGuard y la configuración de ssh, y **se niega a seguir si la nueva dirección no presenta la misma llave de host SSH** que ese dispositivo ya tenía fijada. El restore conserva la llave de host del hub, así que una mudanza legítima pasa.

---

## 7. Problemas comunes

| Síntoma | Qué hacer |
|---|---|
| `dm` dice que una máquina está OFFLINE | Revisa que esté encendida. Si tiene red pero no responde, prueba `dm wake <máquina>` desde otra máquina de su misma LAN |
| En un hotel u oficina la VPN no conecta | No hagas nada: `dm` usa el camino B automáticamente |
| La tablet "se desconecta" | Es Android cerrando Termux. Vuelve a escribir `dm`: tus terminales siguen intactas en la máquina |
| `dm` dice "not enrolled" | Ese dispositivo no está registrado: `dm add <nombre>` desde otro dispositivo y pega la línea en este |
| La línea dice "missing secret" | Se copió incompleta: tiene que terminar en `sh -s` + 12 caracteres |
| La línea da 404 | Venció (15 min), ya se usó o se canceló: genera otra con `dm add` |
| Mudé un hub en modo IP y los dispositivos no llegan | `dm repoint <ip-nueva>` en cada dispositivo |
| El instalador dice que el sistema no es compatible | Usa Docker: `HUB_HOST=… docker compose -f docker/hub/compose.yml up -d --build` |
| Quiero ver qué está haciendo Claude en cada terminal | Agrega a `~/.claude/settings.json` de esa máquina los hooks de `share/devmesh/hooks/claude-code-hooks.json` |
