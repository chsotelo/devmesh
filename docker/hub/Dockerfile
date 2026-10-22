# devmesh hub in a container (any Linux with Docker). Build from the repo root:
#   docker build -f docker/hub/Dockerfile -t devmesh-hub .
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    DEVMESH_WEBROOT=/var/lib/devmesh/www \
    DEVMESH_BACKUP_DIR=/var/lib/devmesh/backups

# The packages of step_packages (minus fail2ban, which belongs on the host), plus what the
# host normally already has: sshd, sudo, nginx, openssl, certbot (domain mode), tar and
# iptables (devmesh-fw). wireguard-go is the fallback when the host kernel has no WireGuard.
RUN apt-get update -qq \
  && apt-get install -y -qq --no-install-recommends \
     wireguard-tools wireguard-go curl vnstat iproute2 iptables \
     openssh-server sudo nginx openssl certbot ca-certificates tar gzip procps \
  && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default \
  && ln -sf /dev/stdout /var/log/nginx/access.log \
  && ln -sf /dev/stderr /var/log/nginx/error.log

# ntfy and age: the same pinned versions and checksums as the native install (web.sh).
COPY server/install/web.sh /tmp/web.sh
RUN bash -c 'ih_die() { echo "$*" >&2; exit 1; }; ih_log() { :; }; source /tmp/web.sh; ih_install_ntfy; step_age' \
  && rm -f /tmp/web.sh

COPY server/ /opt/devmesh-src/server/
COPY client/ /opt/devmesh-src/client/
COPY VERSION /opt/devmesh-src/VERSION
COPY docker/hub/entrypoint.sh /usr/local/bin/devmesh-hub-entrypoint

VOLUME ["/etc/devmesh", "/var/lib/devmesh", "/etc/letsencrypt"]
ENTRYPOINT ["/usr/local/bin/devmesh-hub-entrypoint"]
