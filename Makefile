TREEMAN_BIN ?= treeman

.PHONY: env up down status logs check e2e setup-e2e

env:
	@test -f .env || cp .env.example .env

up: env
	docker compose up -d --wait

down:
	docker compose down

status:
	docker compose ps

logs:
	docker compose logs -f postgres

check:
	npm run check:db

e2e: up
	TREEMAN_BIN="$(TREEMAN_BIN)" ./scripts/e2e.sh

setup-e2e: up
	TREEMAN_BIN="$(TREEMAN_BIN)" ./scripts/setup-e2e.sh
