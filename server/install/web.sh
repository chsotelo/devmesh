# shellcheck shell=bash
# install-hub: nginx site (enrollment scripts + ntfy), TLS certificate, ntfy, age.

# Pinned upstream releases (sha256 from the GitHub release digests, 2026-10-20).
# Read through indirection (NTFY_SHA256_$arch), hence SC2034.
# shellcheck disable=SC2034
readonly NTFY_VERSION=2.32.0
readonly NTFY_SHA256_amd64=dfb527714c80c4bbdd7af370e0b0aa76e63ff5ea2a33d540d615ee6ce309d99e
readonly NTFY_SHA256_arm64=44d780d87b4347a63aa6ada68e7d5187911f87ca122db7ae1385e39f1e63435a
readonly AGE_VERSION=1.3.2
readonly AGE_SHA256_amd64=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
readonly AGE_SHA256_arm64=6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4

ih_arch() {
  case $(uname -m) in
    x86_64) printf 'amd64\n' ;;
    aarch64) printf 'arm64\n' ;;
    *) ih_die "unsupported architecture $(uname -m)" ;;
  esac
}

# ih_fetch URL SHA256 OUT — download and verify, or fail.
ih_fetch() {
  curl -fsSL --retry 3 -o "$3" "$1" || ih_die "download failed: $1"
  printf '%s  %s\n' "$2" "$3" | sha256sum -c --quiet - || ih_die "checksum mismatch: $1"
}

ih_render() {
  local file=$1 content
  shopt -u patsub_replacement 2>/dev/null || true
  content=$(<"$file")
  content=${content//@@HUB_HOST@@/$HUB_HOST}
  content=${content//@@WEBROOT@@/$DEVMESH_WEBROOT}
  content=${content//@@TLS_CERT@@/$TLS_CERT}
  content=${content//@@TLS_KEY@@/$TLS_KEY}
  content=${content//@@HTTPS_PORT@@/$HUB_HTTPS_PORT}
  printf '%s\n' "$content"
}

ih_nginx_install_site() {
  local tpl=$1 site="$NGINX_SITE_DIR/devmesh-hub.conf" backup=""
  [[ -e $site ]] && backup=$(mktemp) && cp -p "$site" "$backup"
  ih_render "$tpl" >"$site"
  if ! nginx -t 2>/dev/null; then
    if [[ -n $backup ]]; then mv -f "$backup" "$site"; else rm -f "$site"; fi
    ih_die "nginx rejected the devmesh site; restored previous state"
  fi
  [[ -n $backup ]] && rm -f "$backup"
  # A freshly installed nginx may not be running yet: reload when active, start otherwise.
  ih_systemctl enable nginx >/dev/null 2>&1 || true
  ih_service_reload nginx
}

step_nginx() {
  command -v nginx >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends nginx >/dev/null
  [[ -d $NGINX_SITE_DIR ]] || ih_die "NGINX_SITE_DIR=$NGINX_SITE_DIR does not exist"
  if hub_ip_mode; then
    step_nginx_ip
    return
  fi
  TLS_CERT=${TLS_CERT:-/etc/letsencrypt/live/$HUB_HOST/fullchain.pem}
  TLS_KEY=${TLS_KEY:-/etc/letsencrypt/live/$HUB_HOST/privkey.pem}
  if [[ ! -s $TLS_CERT ]]; then
    [[ -n ${ACME_EMAIL:-} ]] || ih_die "no certificate for $HUB_HOST; set ACME_EMAIL (Let's Encrypt) or TLS_CERT/TLS_KEY"
    if ((IH_CONTAINER)); then
      # nginx is not running yet (the entrypoint starts it): serve the http-only site and let
      # the entrypoint run certbot against it, then re-run this script for the full site.
      ih_log "container: certificate for $HUB_HOST is requested by the entrypoint once nginx runs"
      ih_nginx_install_site "$IH_SRC/server/nginx/devmesh-hub-http.conf.tpl"
      : >"$DEVMESH_ETC/.acme-pending"
      return
    fi
    command -v certbot >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends certbot >/dev/null
    ih_log "obtaining certificate for $HUB_HOST"
    ih_nginx_install_site "$IH_SRC/server/nginx/devmesh-hub-http.conf.tpl"
    certbot certonly --webroot -w "$DEVMESH_WEBROOT/acme" -d "$HUB_HOST" -m "$ACME_EMAIL" \
      --agree-tos -n --deploy-hook "systemctl reload-or-restart nginx" || ih_die "certbot failed (DNS for $HUB_HOST must point here)"
  fi
  rm -f "$DEVMESH_ETC/.acme-pending"
  ih_log "nginx site for $HUB_HOST"
  ih_nginx_install_site "$IH_SRC/server/nginx/devmesh-hub.conf.tpl"
}

# IP mode: no domain, so no Let's Encrypt. A self-signed certificate (created once) is
# served and its public-key pin goes into hub.conf for the invites.
step_nginx_ip() {
  if [[ -z ${TLS_CERT:-} ]]; then
    ih_log "IP mode: self-signed certificate for $HUB_HOST"
    tls_ensure_selfsigned "$HUB_HOST"
    TLS_CERT=$DEVMESH_TLS_DIR/cert.pem
    TLS_KEY=$DEVMESH_TLS_DIR/key.pem
  fi
  TLS_KEY=${TLS_KEY:?set TLS_KEY together with TLS_CERT}
  ih_conf_set HUB_PIN "$(tls_pin "$TLS_CERT")"
  ih_log "nginx site for $HUB_HOST:$HUB_HTTPS_PORT (certificate pin $HUB_PIN)"
  ih_nginx_install_site "$IH_SRC/server/nginx/devmesh-hub-ip.conf.tpl"
  if ! ((IH_CONTAINER)) && command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$HUB_HTTPS_PORT/tcp" comment devmesh-https >/dev/null
  fi
}

# ntfy state directories. In a container the user database must outlive the container, so
# the directories become links into the state volume (the ntfy CLI edits the database
# directly; the server is started later by the entrypoint).
step_ntfy_dirs() {
  install -d "$IH_NTFY_ETC"
  if ! ((IH_CONTAINER)); then
    install -d "$IH_NTFY_LIB" "$IH_NTFY_CACHE"
    return
  fi
  local pair d name
  for pair in "$IH_NTFY_LIB:ntfy" "$IH_NTFY_CACHE:ntfy-cache"; do
    d=${pair%:*}
    name=${pair##*:}
    install -d "$DEVMESH_STATE/$name"
    if [[ ! -L $d ]]; then
      rm -rf "$d"
      install -d "$(dirname "$d")"
      ln -s "$DEVMESH_STATE/$name" "$d"
    fi
  done
}

# ntfy_user_add NAME PASSWORD — 0 when created now, 1 when it already existed.
ntfy_user_add() {
  local out
  if out=$(NTFY_PASSWORD=$2 ntfy user add "$1" 2>&1); then
    return 0
  fi
  [[ $out == *"already exists"* ]] && return 1
  ih_die "ntfy user add $1 failed: $out"
}

# ih_install_ntfy — the pinned ntfy .deb (also used by docker/hub/Dockerfile).
ih_install_ntfy() {
  local arch deb tmp sha_var
  arch=$(ih_arch)
  tmp=$(mktemp -d)
  sha_var="NTFY_SHA256_$arch"
  deb="$tmp/ntfy_${NTFY_VERSION}_linux_$arch.deb"
  ih_fetch "https://github.com/binwiederhier/ntfy/releases/download/v$NTFY_VERSION/${deb##*/}" "${!sha_var}" "$deb"
  dpkg -i "$deb" >/dev/null
  rm -rf "$tmp"
}

# ntfy users: devmesh-pub publishes alerts (token), devmesh-sub is for the phone app.
step_ntfy() {
  [[ ${ENABLE_NTFY:-1} == 1 ]] || return 0
  local pass_sub token
  if ! dpkg-query -W -f='${Version}' ntfy 2>/dev/null | grep -qx "$NTFY_VERSION"; then
    ih_install_ntfy
  fi
  step_ntfy_dirs
  # Never clobber an ntfy config that devmesh did not write. The package ships a
  # fully commented template, which is fine to replace.
  if [[ -s "$IH_NTFY_ETC/server.yml" ]] && ! grep -q 'Generated by devmesh' "$IH_NTFY_ETC/server.yml" &&
    grep -Eqv '^[[:space:]]*(#|$)' "$IH_NTFY_ETC/server.yml"; then
    ih_die "$IH_NTFY_ETC/server.yml exists and is not managed by devmesh; set ENABLE_NTFY=0 or move it"
  fi
  ih_render "$IH_SRC/server/ntfy/server.yml.tpl" >"$IH_NTFY_ETC/server.yml"
  local _ ntfy_pid=""
  if ((IH_CONTAINER)); then
    # No systemd: run the server just long enough to create its auth database (the CLI
    # refuses to edit one that does not exist); the entrypoint starts the real server.
    ntfy serve --config "$IH_NTFY_ETC/server.yml" >/dev/null 2>&1 &
    ntfy_pid=$!
  else
    systemctl enable --now ntfy >/dev/null
    systemctl restart ntfy
  fi
  for _ in $(seq 1 20); do
    curl -fsS -m 2 http://127.0.0.1:2586/v1/health >/dev/null 2>&1 && break
    sleep 0.5
  done
  # Idempotent: right after a restart "user list" can come back empty, so an existing
  # user is detected by the add itself ("already exists") instead of a prior lookup.
  if ntfy_user_add devmesh-pub "$(head -c 24 /dev/urandom | base64)"; then
    ntfy access devmesh-pub "$NTFY_TOPIC" write-only >/dev/null
    token=$(ntfy token add devmesh-pub 2>/dev/null | grep -Eo 'tk_[A-Za-z0-9]+' | head -n1)
    [[ -n $token ]] || ih_die "could not create ntfy token"
    ih_conf_set NTFY_TOKEN "$token"
  fi
  # Publish to ntfy locally: no DNS, TLS or hairpin NAT between the hub and itself.
  ih_conf_set NTFY_URL "http://127.0.0.1:2586"
  pass_sub=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
  if ntfy_user_add devmesh-sub "$pass_sub"; then
    ntfy access devmesh-sub "$NTFY_TOPIC" read-only >/dev/null
    printf 'ntfy app: server https://%s  topic %s  user devmesh-sub  password %s\n' \
      "$(hub_url_authority)" "$NTFY_TOPIC" "$pass_sub" | (umask 077 && cat >"$DEVMESH_ETC/ntfy-subscriber.txt")
    ih_log "ntfy subscriber credentials: $DEVMESH_ETC/ntfy-subscriber.txt (root only)"
    ! hub_ip_mode || ih_log "IP mode: the ntfy phone app needs a valid certificate (domain mode); machine alerts still work"
  fi
  if [[ -n $ntfy_pid ]]; then
    kill "$ntfy_pid" 2>/dev/null || true
    wait "$ntfy_pid" 2>/dev/null || true
  fi
}

step_age() {
  local arch tmp sha_var
  if command -v age >/dev/null && age --version | grep -q "v$AGE_VERSION"; then
    return 0
  fi
  arch=$(ih_arch)
  sha_var="AGE_SHA256_$arch"
  tmp=$(mktemp -d)
  ih_fetch "https://github.com/FiloSottile/age/releases/download/v$AGE_VERSION/age-v$AGE_VERSION-linux-$arch.tar.gz" \
    "${!sha_var}" "$tmp/age.tgz"
  tar -xzf "$tmp/age.tgz" -C "$tmp"
  install -m 0755 "$tmp/age/age" /usr/local/bin/age
  rm -rf "$tmp"
}
