# Build and run helpers for the rea-agent images.
#
# Four images, one engine each - select with ENGINE=all|ghidra|hopper|ida:
#
#   make build ENGINE=ghidra      make up ENGINE=hopper      make verify ENGINE=ida
#   make build-ghidra             make up-hopper             make verify-ghidra
#
# Everything Docker-side uses the HOST path to this project directory when a
# Docker socket is bind-mounted into the caller (e.g. Hermes running in Docker
# with DooD): volume/context sources resolve on the host daemon, not inside the
# caller's container. scripts/build.sh does that translation.
SHELL := /bin/bash

ENGINE ?= all
DOCKER ?= docker
COMPOSE ?= $(DOCKER) compose
TAG_SUFFIX ?= 6.5.0-linux-amd64

# engine -> compose service / profile (the image name comes from
# scripts/image-name.sh, which also honours the REA_*_IMAGE names in .env, so a
# local build tags exactly what `docker compose pull` would fetch)
engine_service = $(if $(filter all,$(1)),rea-agent,rea-$(1))

IMAGE    := $(shell scripts/image-name.sh $(ENGINE))
SERVICE  := $(call engine_service,$(ENGINE))
PROFILE  := $(if $(filter all,$(ENGINE)),,--profile $(ENGINE))
COMPOSE_ENGINE = $(COMPOSE) -f docker-compose.yml

.DEFAULT_GOAL := help

.PHONY: help
help: ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  ENGINE=$(ENGINE) -> image $(IMAGE), service $(SERVICE)"
	@echo "  images: all=rea-agent (Ghidra+Hopper) | ghidra | hopper | ida (bring your own IDA)"

.PHONY: env
env: ## create .env from .env.example when missing
	@test -f .env || (cp .env.example .env && echo "created .env - review it, then 'make build'")

.PHONY: build
build: env ## build the image for $(ENGINE)
	scripts/build.sh --engine $(ENGINE)

.PHONY: build-ghidra build-hopper build-ida
build-ghidra: ## build the Ghidra-only image
	scripts/build.sh --engine ghidra
build-hopper: ## build the Hopper-only image
	scripts/build.sh --engine hopper
build-ida: ## build the engine-less IDA image (bring your own IDA)
	scripts/build.sh --engine ida

.PHONY: build-all
build-all: ## build all four images
	scripts/build-all.sh

.PHONY: up
up: ## start the long-lived container for $(ENGINE)
	$(COMPOSE_ENGINE) $(PROFILE) up -d $(SERVICE)

.PHONY: up-ghidra up-hopper up-ida
up-ghidra: ## start the Ghidra-only container
	$(COMPOSE_ENGINE) --profile ghidra up -d rea-ghidra
up-hopper: ## start the Hopper-only container
	$(COMPOSE_ENGINE) --profile hopper up -d rea-hopper
up-ida: ## start the IDA container (needs your own IDA install/licence)
	$(COMPOSE_ENGINE) --profile ida up -d rea-ida

.PHONY: down
down: ## stop every compose service of this project
	$(COMPOSE) down

.PHONY: shell
shell: ## interactive shell in the running $(ENGINE) container
	$(COMPOSE) exec $(SERVICE) bash

.PHONY: doctor
doctor: ## REA readiness report from inside the $(ENGINE) container
	$(COMPOSE) exec $(SERVICE) rea doctor --json

.PHONY: providers
providers: ## list analysis providers and their capabilities
	$(COMPOSE) exec $(SERVICE) rea providers --json

.PHONY: verify
verify: ## full in-container verification for $(ENGINE)
	scripts/verify.sh --image $(IMAGE)

.PHONY: verify-quick
verify-quick: ## fast verification (tool presence + static + MCP handshake)
	scripts/verify.sh --image $(IMAGE) --quick

.PHONY: verify-ghidra verify-hopper verify-ida
verify-ghidra: ## full verification of the Ghidra-only image
	scripts/verify.sh --engine ghidra --only tools,analysis,static,clients,mcp
verify-hopper: ## full verification of the Hopper-only image
	scripts/verify.sh --engine hopper --only tools,analysis,static,clients,mcp
verify-ida: ## verification of the engine-less IDA image
	scripts/verify.sh --engine ida --only tools,static,clients,mcp

.PHONY: pull
pull: ## pull the published image for $(ENGINE) from GHCR (no local build)
	$(DOCKER) pull $(IMAGE)

.PHONY: pull-all
pull-all: ## pull all four published images from GHCR
	@for e in all ghidra hopper ida; do \
	  img="$$( scripts/image-name.sh $$e )"; \
	  echo "== pulling $$img"; \
	  $(DOCKER) pull "$$img" || exit 1; \
	done

.PHONY: mcp-stdio
mcp-stdio: ## speak MCP over stdio the way Hermes does
	$(DOCKER) exec -i $(SERVICE) rea mcp

.PHONY: http-up
http-up: ## start the Streamable HTTP bridge for $(ENGINE)
	REA_IMAGE=$(IMAGE) REA_ENGINE=$(ENGINE) $(COMPOSE_ENGINE) $(PROFILE) -f compose.http.yml up -d rea-mcp-http

.PHONY: ida-up
ida-up: ## start the IDA overlay (needs your own IDA install/licence)
	$(COMPOSE_ENGINE) -f compose.ida.yml --profile ida up -d rea-ida

.PHONY: test-host
test-host: ## run the harness in a throwaway container against ./work
	$(DOCKER) run --rm -it --shm-size=1g \
	  --user "$$(id -u):$$(id -g)" \
	  -v $(PWD)/work:/work -v $(PWD)/config:/etc/rea:ro $(IMAGE) \
	  /opt/rea/verify/verify-all.sh

.PHONY: check-updates
check-updates: ## are the pins still current? (upstream + what REA admits)
	scripts/check-updates.py $(ARGS)

.PHONY: check-updates-json
check-updates-json: ## the same check as JSON (for scripts)
	scripts/check-updates.py --json --no-fail

.PHONY: sizes
sizes: ## report the size of every engine image
	@for e in all ghidra hopper ida; do \
	  img="$$( scripts/image-name.sh $$e )"; \
	  bytes="$$( $(DOCKER) image inspect "$$img" --format '{{.Size}}' 2>/dev/null || echo '' )"; \
	  if [ -n "$$bytes" ]; then \
	    human="$$(awk -v b="$$bytes" 'BEGIN{printf "%.2f GB", b/1024/1024/1024}')"; \
	    printf '  %-52s %s (%s bytes)\n' "$$img" "$$human" "$$bytes"; \
	  else \
	    printf '  %-52s %s\n' "$$img" "not built/pulled"; \
	  fi; \
	done

.PHONY: clean
clean: ## remove build output, not the images
	rm -rf work/verify-reports work/tmp
