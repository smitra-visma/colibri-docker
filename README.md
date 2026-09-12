# colibri-docker

Docker Compose setup that runs the [colibri](https://github.com/JustVugg/colibri)
inference engine and exposes an OpenAI-compatible HTTP API. The model is
bind-mounted from the host, so it never becomes part of the image.

- Engine sources are fetched and compiled at image build time — nothing from
  upstream is vendored here.
- Runtime image is Debian slim plus `python3` and `libgomp1`; the launcher and
  the HTTP gateway need no third-party Python packages.
- The API is documented by [`docs/openapi.yaml`](docs/openapi.yaml) and can be
  browsed in a Swagger UI container.

## Requirements

- Docker with the Compose plugin.
- An x86-64 host with AVX2 (the default `ARCH=x86-64-v3` build target).
- A converted int4 model directory on a local NVMe filesystem. GLM-5.2 int4 is
  roughly 360 GB. Never point `MODEL_DIR` at a network mount: expert streaming
  is latency-bound and a remote filesystem makes generation unusably slow.
- 32 GB RAM or more is a realistic minimum; less works but is very slow.

See the [upstream model conversion guide](https://github.com/JustVugg/colibri/blob/main/docker/README.md#step-1-download-the-model)
for how to download and convert the weights.

## Quick start

```bash
cp .env.example .env
# edit .env and set MODEL_DIR to the model directory on this host

docker compose up -d
docker compose logs -f colibri     # the first load takes several minutes
```

Then call the API:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "glm-5.2",
        "messages": [{"role": "user", "content": "Hello"}],
        "max_tokens": 128
      }'
```

Or with any OpenAI client:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="glm-5.2",
    messages=[{"role": "user", "content": "Hello"}],
).choices[0].message.content)
```

## API documentation

`docs/openapi.yaml` describes every endpoint. To browse it:

```bash
docker compose --profile docs up -d swagger-ui
open http://localhost:8080
```

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | Liveness; answers before the model has finished loading |
| `GET /v1/models` | List the served model |
| `POST /v1/chat/completions` | Chat completion, streaming or not |
| `POST /v1/completions` | Raw text completion |
| `POST /v1/messages` | Anthropic-shaped request over the same engine |

## Configuration

All settings live in `.env`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MODEL_DIR` | *(required)* | Host directory holding the int4 model, mounted read-only at `/model` |
| `COLI_MODEL_ID` | `glm-5.2` | Model name reported by the API and expected in requests |
| `COLI_PORT` | `8000` | Host port for the API |
| `DOCS_PORT` | `8080` | Host port for the Swagger UI |
| `COLI_RAM` | `0` | Expert-cache RAM budget in GB; `0` lets the engine choose |
| `COLI_API_KEY` | *(empty)* | Bearer token required on `/v1/*`; empty disables authentication |
| `COLI_ALLOWED_HOSTS` | *(empty)* | Extra `Host` headers accepted by the DNS-rebinding guard |
| `COLI_MAX_QUEUE` | `8` | Maximum queued requests |
| `COLI_KV_SLOTS` | `1` | Concurrent KV cache slots |
| `COLIBRI_REF` | `main` | Upstream git ref to build; pin a commit for reproducible builds |
| `ARCH` | `x86-64-v3` | Target CPU ISA passed to the compiler |

### Exposing the server beyond localhost

The container listens on `0.0.0.0` inside its own network namespace, and Compose
publishes the port on the host. If you reach the server through a hostname or a
reverse proxy, add that hostname to `COLI_ALLOWED_HOSTS` or the DNS-rebinding
guard rejects the request. Set `COLI_API_KEY` before exposing the port to
anything other than the local machine: without it, every endpoint is open to
whoever can reach the port.

### Build for a specific CPU

`ARCH=x86-64-v3` produces a portable AVX2 binary. A more specific ISA level is
faster but only runs on a matching host:

```bash
ARCH=x86-64-v4 docker compose build
```

`ARCH=native` is deliberately not the default: it bakes in the build machine's
instruction set and the binary dies with `SIGILL` on a different CPU.

## Operating notes

- The healthcheck has a 10 minute `start_period`, because a cold load of a
  744B model from disk takes minutes. The container reports `starting` until
  then, not `unhealthy`.
- `docker compose down` stops the server; the model directory is untouched.
- Conversion of weights is out of scope for this image — it needs `torch`. Run
  it from an upstream checkout.

## License

This repository is Apache-2.0. The engine it builds is a separate project;
see [upstream's LICENSE](https://github.com/JustVugg/colibri/blob/main/LICENSE).
