# devmesh — Guía de uso

**Una red privada, confianza entre dispositivos y control de energía para tus equipos.**
Versión en inglés: [../en/GUIDE.md](../en/GUIDE.md).
devmesh conecta tus máquinas de desarrollo, tu Mac, tu tablet y tu celular en una red privada. Desde cualquiera de ellos llegas a los demás, los enciendes, mandas archivos y decides qué dispositivos son de confianza, aunque estés fuera de casa. [Herdr](https://herdr.dev) corre las terminales y los agentes encima.

---

## Cómo funciona, en 30 segundos

| Pieza | Qué es | Ejemplos |
|---|---|---|
| **Hub** | El centro de control. Coordina la red privada, recibe los registros y te avisa si algo se cae | `hub.example.com` o `203.0.113.10` |
| **Máquina** | Un equipo donde trabajas. Llegas a él desde cualquier lado y Herdr corre ahí tus terminales y agentes | Tu laptop 24/7, otras PCs |
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

Tu Mac se une a la red igual que una máquina Linux y la alcanzas desde la tablet o el celular.

- **Nadie puede entrar a tu Mac desde la red:** el sshd de devmesh escucha solo en la propia Mac (`127.0.0.1`), y tus dispositivos llegan a ella únicamente por el túnel cifrado del hub, con su llave.
- Para usar la app móvil de Herdr con la Mac hace falta activar el Acceso remoto de macOS (ver "App móvil de Herdr").

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
| **Linux** (laptop, PC) | En una terminal, con tu usuario normal | Te pide tu contraseña de `sudo` y queda como **máquina**: la alcanzas desde cualquier lado |
| **Mac** | En Terminal | Sin `sudo`. Queda como **control**. Para la VPN, importa `~/.config/devmesh/wireguard/devmesh.conf` en la app WireGuard |
| **Android** (Termux) | En Termux. Desde el QR: lo escaneas con la cámara, copias el texto y lo pegas | Te pide importar `Download/devmesh-<nombre>.conf` en la app WireGuard y presionar Enter. El archivo se borra solo |

El dispositivo **detecta solo** qué es. No eliges nada.

> La línea sirve **una sola vez** y vence a los **15 minutos**. La segunda parte es un secreto: nunca llega al servidor ni a ningún log. Si te equivocas, `dm rm` cancela la invitación y deja la línea inutilizable al instante.

**Antes de agregar un Android:** instala **Termux** desde **F-Droid** (no desde Play Store) y la app **WireGuard**. Después, para que Android no corte tus sesiones:
- *Ajustes → Opciones de desarrollador →* **Disable child process restrictions**
- *Batería → Termux →* **Sin restricciones**

En la Mac, `dm` necesita bash 4+ y Homebrew (`brew install bash`); se relanza solo con el bash de Homebrew si lo encuentra.

---

## 3. Herdr encima

devmesh es la red. [Herdr](https://herdr.dev) (apps de escritorio y móvil) corre las terminales y
los agentes en tus máquinas. devmesh no instala Herdr: es opcional, y lo que necesita
`herdr-core` en una máquina te avisa cuando falta.

Un uso típico: dejar una PC potente dormida y, desde la laptop, escribir

```bash
dm use pc claude
```

devmesh enciende `pc` con Wake-on-LAN si está dormida, la espera y abre `claude` en una
terminal de Herdr ahí. Luego la ves y la manejas en Herdr, en el escritorio o en el celular.

### `dm use`: correr algo en una máquina

```bash
dm use <máquina> [--cwd DIR] [--attach] [-- comando...]
```

- Corre el comando en una terminal de Herdr en esa máquina, a través de su `herdr-core`. Sin
  comando, abre una shell.
- Si la máquina está dormida, la enciende primero y `dm use` espera hasta 180 s
  (`DM_USE_WAIT=<segundos>` lo cambia).
- `--cwd DIR` fija la carpeta. `--attach` conecta la terminal aquí mismo en vez de solo abrirla.
- Necesita `herdr-core` en el destino. Si falta, `dm use` lo dice y no instala nada.

### `dm power`: ver y cambiar la energía de una máquina

```bash
dm power <máquina> [status|wake|suspend|off]
```

- `status` (el predeterminado) muestra si la máquina está encendida o apagada y qué se puede hacer.
- `suspend` y `off` solo se permiten si otra máquina en línea de su red de confianza puede
  volver a encenderla. `off` te pide escribir el nombre de la máquina. La máquina donde estás
  nunca se apaga sola.
- `wake` envía Wake-on-LAN a través de otra máquina de la misma red, como `dm wake`.

### App móvil de Herdr

Usa solo la app oficial de [herdr.dev/mobile](https://herdr.dev/mobile) (id en Google Play
`dev.herdr.app`). Las apps de terceros "Herdr Mobile" que piden instalar un
`herdr-mobile-bridge` hablan con la TUI de Herdr, no con `herdr-core`, y no ven nada.

1. **El celular o la tablet está en la malla con WireGuard activado.** Es el túnel de la app
   WireGuard que importaste al unir el dispositivo.
2. **Agrega cada máquina en la app** con su IP de la malla (`10.73.0.x`, mira `dm devices`), puerto
   `22` y el usuario de la máquina.
3. **Elige "Add the key yourself".** La app muestra una llave (o una línea completa que la
   agrega). En un dispositivo ya unido corre:
   ```bash
   dm herdr allow phone '<lo que muestra la app>'
   ```
   Puedes pegar la línea completa. devmesh encuentra la llave pública en ella y la agrega a
   `~/.ssh/authorized_keys` en todas las máquinas. La entrada queda marcada
   `devmesh-herdr:phone`, sirve solo desde la IP de la malla del celular (`from="<IP de la malla>"`)
   y no permite reenvíos. Las máquinas sin conexión se informan: corre el mismo comando cuando
   vuelvan, repetirlo es seguro.
4. **Cada máquina necesita `herdr-core`.** Viene con la app de escritorio de Herdr, o instálalo.
5. **Las Mac necesitan Acceso remoto.** El sshd de devmesh en una Mac escucha solo en
   `127.0.0.1`, así que la app no puede usarlo. Activa Ajustes del Sistema > General >
   Compartir > Acceso remoto (Remote Login), permite solo a tu usuario y desactiva "acceso
   total al disco para usuarios remotos". Deja el sshd de macOS solo con llaves. Las máquinas
   Linux no necesitan nada: su sshd ya escucha en la IP de la malla.

```bash
dm herdr ls                    # las llaves, por máquina
dm herdr revoke phone          # quita las llaves de ese dispositivo
```

`dm rm <dispositivo>` también revoca las llaves de Herdr de ese dispositivo en todas las máquinas en línea.

### `dm go`: una terminal simple

```bash
dm go                  # elige una máquina y entra a su terminal "main"
dm go mac api          # máquina "mac", terminal "api"
```

Abre una terminal tmux en la máquina, por el camino A y, si falla, por el B. Úsala cuando Herdr
no esté al alcance, por ejemplo desde Termux o en una red que solo permite el camino B. Dentro:

| Atajo | Qué hace |
|---|---|
| `Ctrl+b` `s` | Ver y saltar entre sesiones y pestañas |
| `Ctrl+b` `c` | Pestaña nueva |
| `Ctrl+b` `,` | Renombrar la pestaña |
| `Ctrl+b` `%` · `Ctrl+b` `"` | Dividir la pantalla |
| `Ctrl+b` `d` | **Salir sin cerrar nada**: todo sigue corriendo |

### Idioma

Los mensajes salen en **inglés** por defecto. Para español usa `DM_LANG=es` (por ejemplo `DM_LANG=es dm help`) o un idioma del sistema en español (`LANG=es_PE.UTF-8`). Lo que falte en la traducción sale en inglés.

### Comandos

`dm` sin argumentos imprime esta lista (`dm help`).

| Quieres… | Escribe |
|---|---|
| Correr algo en una máquina (la enciende) | `dm use <máquina> [--cwd DIR] [--attach] [-- comando...]` |
| Ver o cambiar la energía de una máquina | `dm power <máquina> [status\|wake\|suspend\|off]` |
| Dejar entrar a la app de Herdr | `dm herdr allow <dispositivo> <llave>` · `dm herdr revoke <dispositivo>` · `dm herdr ls` |
| Terminal simple | `dm go [máquina] [nombre]` |
| Mandar / traer archivos | `dm send` · `dm fetch` |
| Ver la web de una máquina | `dm port` (se detiene con `dm port stop`) |
| Ver / cambiar lo que una máquina expone en la malla | `dm mesh` |
| Dispositivos · agregar · quitar | `dm devices` · `dm add <nombre>` · `dm rm` |
| Aprobar un dispositivo · confianza firmada | `dm approve` · `dm trust init\|pin\|status` |
| Encender una máquina | `dm wake <máquina>` |
| Traer la lista de dispositivos | `dm refresh` |
| Actualizar `dm` | `dm update` |
| Seguir al hub si cambió de dirección | `dm repoint <ip-o-host>` |
| Aviso al celular cuando Claude te necesita | `dm notify on\|off\|status` |
| Ayuda | `dm help` |

La integración con la shell agrega un solo alias, `m='dm go'`.

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
| La tablet "se desconecta" | Es Android cerrando Termux. Vuelve a abrir tu sesión: lo que corría en la máquina sigue intacto (en Herdr, o en tmux con `dm go`) |
| `dm` dice "not enrolled" | Ese dispositivo no está registrado: `dm add <nombre>` desde otro dispositivo y pega la línea en este |
| La línea dice "missing secret" | Se copió incompleta: tiene que terminar en `sh -s` + 12 caracteres |
| La línea da 404 | Venció (15 min), ya se usó o se canceló: genera otra con `dm add` |
| Mudé un hub en modo IP y los dispositivos no llegan | `dm repoint <ip-nueva>` en cada dispositivo |
| El instalador dice que el sistema no es compatible | Usa Docker: `HUB_HOST=… docker compose -f docker/hub/compose.yml up -d --build` |
| `dm use` dice que herdr-core no está en la máquina | Herdr es opcional. Instala `herdr-core` ahí (viene con la app de escritorio de Herdr) |
| La app de Herdr en el celular no ve máquinas | WireGuard activo en el celular, la máquina agregada por su IP de la malla y la llave pasada con `dm herdr allow`. En una Mac, activa Acceso remoto |
