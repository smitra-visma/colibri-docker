.PHONY: build up down logs health models chat docs clean

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f colibri

health:
	curl -fsS http://localhost:$${COLI_PORT:-18000}/health && echo

models:
	curl -fsS http://localhost:$${COLI_PORT:-18000}/v1/models && echo

chat:
	curl -fsS http://localhost:$${COLI_PORT:-18000}/v1/chat/completions \
		-H 'Content-Type: application/json' \
		-d '{"model":"$(or $(MODEL_ID),glm-5.2)","messages":[{"role":"user","content":"$(or $(PROMPT),Hello)"}],"max_tokens":128}' \
		&& echo

docs:
	docker compose --profile docs up -d swagger-ui

clean:
	docker compose down --rmi local --remove-orphans
