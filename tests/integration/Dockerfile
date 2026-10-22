# systemd-in-docker host used by the devmesh integration test (hub and machines).
ARG BASE=ubuntu:20.04
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update -qq \
  && apt-get install -y -qq systemd systemd-sysv dbus openssh-server sudo iproute2 iptables \
     curl ca-certificates rsyslog kmod procps iputils-ping openssl tmux python3 netcat-openbsd \
  && rm -rf /var/lib/apt/lists/*
# Trim units that make no sense in a container.
RUN systemctl mask getty.target console-getty.service systemd-firstboot.service \
     systemd-udevd.service systemd-udev-trigger.service systemd-modules-load.service \
  && useradd -m -s /bin/bash dev \
  && printf 'dev ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/dev \
  && chmod 0440 /etc/sudoers.d/dev
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
