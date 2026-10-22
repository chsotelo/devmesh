# devmesh — lint, test, deploy the hub from code, backup and restore its state.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

SCRIPTS := $(shell find server client scripts docker install.sh -type f \( -name '*.sh' -o -path '*/sbin/*' -o -path '*/bin/*' \) -not -name 'dm-tui-*' 2>/dev/null | sort)
# Your own hub's settings (HOST, HUB_HOST, ACME_EMAIL, BACKUP_RECIPIENT, SSH) live in
# deploy.local.mk, which git ignores: copy deploy.local.mk.example. Command-line values win.
-include deploy.local.mk

REMOTE_SRC ?= /opt/devmesh-src
HOST ?=
HUB_HOST ?=
ACME_EMAIL ?=
BACKUP_RECIPIENT ?=
BACKUP ?=
AGE_IDENTITY ?= $(HOME)/.config/devmesh/backup.agekey
# ssh command used for rsync/ssh/scp, e.g. SSH="ssh -i ~/.ssh/id_ed25519"
SSH ?= ssh

.PHONY: help lint fmt test check integration integration-images hub restore backup-pull demo tui tui-all tui-check

help:
	@echo "make check                         lint + unit tests (bats, stubs)"
	@echo "make tui | tui-all                 build dm-tui for this machine | for every supported OS/arch"
	@echo "make tui-check                     go vet + gofmt + go test for the dm-tui module"
	@echo "make integration                   real hub + machines in systemd containers (Docker)"
	@echo "make hub HOST=root@ip HUB_HOST=hub.example.com [ACME_EMAIL=..] [BACKUP_RECIPIENT=age1..]"
	@echo "make restore HOST=root@ip BACKUP=file.tar.gz.age [AGE_IDENTITY=..]"
	@echo "make backup-pull                   fetch the latest encrypted backup via hub-admin"

lint:
	shellcheck -x $(SCRIPTS) tests/stubs/*
	shfmt -d -i 2 -ci $(SCRIPTS)

fmt:
	shfmt -w -i 2 -ci $(SCRIPTS)

test:
	PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" bats tests

check: lint test

# dm-tui: the Go panel (Bubble Tea). Binaries go to client/bin/dm-tui-<goos>-<goarch> (git ignored);
# "dm" picks the one of its OS/arch. CGO is off so the same build works on Termux (android/arm64).
VERSION := $(shell tr -d '[:space:]' < VERSION)
TUI_LDFLAGS := -s -w -X main.version=$(VERSION)
TUI_TARGETS := darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 android/arm64

tui:
	cd tui && CGO_ENABLED=0 go build -trimpath -ldflags "$(TUI_LDFLAGS)" -o "../client/bin/dm-tui-$$(go env GOOS)-$$(go env GOARCH)" ./cmd/dm-tui

tui-all:
	for target in $(TUI_TARGETS); do \
	  os=$${target%/*}; arch=$${target#*/}; \
	  (cd tui && GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -ldflags "$(TUI_LDFLAGS)" -o "../client/bin/dm-tui-$$os-$$arch" ./cmd/dm-tui); \
	done
	@ls -1 client/bin/dm-tui-*

tui-check:
	cd tui && go vet ./... && test -z "$$(gofmt -l .)" && go test ./...

# Real end-to-end run in systemd containers (hub 20.04, machines 22.04/24.04). Needs Docker
# and internet (apt, GitHub releases). ~6 min. KEEP=1 leaves the containers for debugging.
integration-images:
	for b in 20.04 22.04 24.04; do docker build -q --build-arg BASE=ubuntu:$$b -t devmesh-it:$$b tests/integration >/dev/null; done

integration: integration-images
	PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" bash tests/integration/run.sh

# Build or re-apply the hub on a fresh or existing Debian/Ubuntu VPS (idempotent).
hub: tui-all
	@test -n "$(HOST)" || { echo "HOST=root@<ip> is required"; exit 2; }
	bash scripts/sign-dist.sh dist
	rsync -az --delete -e "$(SSH)" --exclude .git --exclude tests --exclude backups --exclude deploy.local.mk --exclude PLAN-OSS.md ./ "$(HOST):$(REMOTE_SRC)/"
	$(SSH) "$(HOST)" "HUB_HOST='$(HUB_HOST)' ACME_EMAIL='$(ACME_EMAIL)' BACKUP_RECIPIENT='$(BACKUP_RECIPIENT)' bash $(REMOTE_SRC)/server/install-hub.sh"

# Decrypt locally (the hub never has the identity), push the state, rebuild the hub on it.
restore: tui-all
	@test -n "$(HOST)" -a -n "$(BACKUP)" || { echo "HOST and BACKUP are required"; exit 2; }
	bash scripts/sign-dist.sh dist; \
	umask 077; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	age -d -i "$(AGE_IDENTITY)" -o "$$tmp/state.tar.gz" "$(BACKUP)"; \
	rsync -az --delete -e "$(SSH)" --exclude .git --exclude tests --exclude backups --exclude deploy.local.mk --exclude PLAN-OSS.md ./ "$(HOST):$(REMOTE_SRC)/"; \
	$(SSH) "$(HOST)" "cat > /root/devmesh-state.tar.gz" < "$$tmp/state.tar.gz"; \
	$(SSH) "$(HOST)" "HUB_HOST='$(HUB_HOST)' ACME_EMAIL='$(ACME_EMAIL)' BACKUP_RECIPIENT='$(BACKUP_RECIPIENT)' bash $(REMOTE_SRC)/server/install-hub.sh --restore /root/devmesh-state.tar.gz && shred -u /root/devmesh-state.tar.gz"

backup-pull:
	mkdir -p backups
	ssh hub-admin backup-latest > "backups/devmesh-$$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"
	@ls -1t backups | head -n 3

# docs/demo.gif from docs/demo.tape: fake machines answered by the test ssh stub, and the
# real dm-tui of this machine on top.
demo: tui
	vhs docs/demo.tape
