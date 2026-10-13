# Build and run helpers. Everything Docker-side uses the HOST path to this
# project directory when a Docker socket is bind-mounted into the caller
# (e.g. Hermes running in Docker with DooD): volume/context sources resolve on
# the host daemon, not inside the caller's container.
SHELL := /bin/bash
IMAGE ?= rea-agent:6.4.0-linux-amd64
DOCKER ?= docker
COMPOSE ?= $(DOCKER) compose
TAG ?= $(IMAGE)

.DEFAULT_GOAL := help

.PHONY: help
help: ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: env
env: ## create .env from .env.example when missing
	@test -f .env || (cp .env.example .env && echo "created .env - review it, then 'make build'")

.PHONY: build
build: env ## build the image
	$(COMPOSE) build rea-agent

.PHONY: up
up: ## start the long-lived analysis container
	$(COMPOSE) up -d rea-agent

.PHONY: down
down: ## stop the stack
	$(COMPOSE) down

.PHONY: shell
shell: ## interactive shell in the running container
	$(COMPOSE) exec rea-agent bash

.PHONY: doctor
doctor: ## REA readiness report from inside the container
	$(COMPOSE) exec rea-agent rea doctor --json

.PHONY: providers
providers: ## list analysis providers and their capabilities
	$(COMPOSE) exec rea-agent rea providers --json

.PHONY: verify
verify: ## full in-container verification (long: builds fixtures, runs engine analysis)
	$(COMPOSE) exec rea-agent /opt/rea/verify/verify-all.sh

.PHONY: verify-quick
verify-quick: ## fast verification (tool presence + static + MCP handshake)
	$(COMPOSE) exec rea-agent /opt/rea/verify/verify-all.sh --quick

.PHONY: mcp-stdio
mcp-stdio: ## speak MCP over stdio the way Hermes does
	$(DOCKER) exec -i rea-agent rea mcp

.PHONY: http
http-up: ## start the Streamable HTTP bridge overlay
	$(COMPOSE) -f docker-compose.yml -f compose.http.yml up -d

.PHONY: ida
ida-up: ## start with the IDA overlay (needs your own IDA install/licence)
	$(COMPOSE) -f docker-compose.yml -f compose.ida.yml up -d

.PHONY: test-host
test-host: ## run the harness in a throwaway container against ./work
	$(DOCKER) run --rm -it --shm-size=1g \
	  --user "$$(id -u):$$(id -g)" \
	  -v $(PWD)/work:/work -v $(PWD)/config:/etc/rea:ro $(TAG) \
	  /opt/rea/verify/verify-all.sh

.PHONY: clean
clean: ## remove build output, not the image
	rm -rf work/verify-reports work/tmp
