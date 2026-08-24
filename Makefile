.PHONY: env up down status logs check

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
