# colibri-docker

Docker Compose setup that runs the [colibri](https://github.com/JustVugg/colibri)
inference engine and exposes an OpenAI-compatible HTTP API. The model is
bind-mounted from the host, so it never becomes part of the image.

- A prebuilt image is published to GHCR; building locally is also supported.
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

See [Getting the model](#getting-the-model) below.

## Getting the model

This image ships the GLM engine only, so it needs a model of the GLM-5.2/5.3
family already converted to colibri's int4 layout. Download the prebuilt
conversion from Hugging Face — about 372 GB, so check free space first.

```bash
python3 -m pip install -U "huggingface_hub[cli,hf_transfer]"

export HF_HUB_ENABLE_HF_TRANSFER=1      # parallel chunks, much faster
hf download mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp \
  --local-dir /nvme/glm52_i4
```

On an older `huggingface_hub`, the command is
`huggingface-cli download …` with the same arguments.

The download resumes: re-run the same command after an interruption and it
continues from the cached chunks. Point `--local-dir` at the directory you will
set as `MODEL_DIR`, on a local NVMe filesystem.

Then verify the directory before starting the server:

```bash
docker run --rm -v /nvme/glm52_i4:/model:ro \
  ghcr.io/smitra-visma/colibri-docker:latest info
```

`info` prints the model layout it detected; `doctor` checks it more strictly.

A model from another family (Qwen3.6, Inkling, Kimi K3, DeepSeek V4) needs a
different engine binary that this image does not contain — the launcher refuses
it rather than loading it with the GLM engine. Build those from an upstream
checkout. Converting original weights yourself also happens upstream: the
converter needs `torch` and is out of scope here.

## Quick start

```bash
cp .env.example .env
# edit .env and set MODEL_DIR to the model directory on this host

docker compose up -d
docker compose logs -f colibri     # the first load takes several minutes
```

This pulls `ghcr.io/smitra-visma/colibri-docker:latest`. If the pull fails,
Compose builds the image from source instead.

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
| `COLIBRI_IMAGE` | `ghcr.io/smitra-visma/colibri-docker:latest` | Image to run |
| `COLIBRI_PULL_POLICY` | `missing` | `missing`, `always`, or `never` |

### Exposing the server beyond localhost

The container listens on `0.0.0.0` inside its own network namespace, and Compose
publishes the port on the host. If you reach the server through a hostname or a
reverse proxy, add that hostname to `COLI_ALLOWED_HOSTS` or the DNS-rebinding
guard rejects the request. Set `COLI_API_KEY` before exposing the port to
anything other than the local machine: without it, every endpoint is open to
whoever can reach the port.

## Prebuilt image

`.github/workflows/publish.yml` builds `linux/amd64` with `ARCH=x86-64-v3` and
pushes to GHCR on every push to `main` and on every `v*` tag. Tags published:
`latest`, `main`, `sha-<short>`, and for a version tag `X.Y.Z` and `X.Y`.

Run it without this repository checked out:

```bash
docker run --rm -p 8000:8000 -v /nvme/glm52_i4:/model:ro \
  ghcr.io/smitra-visma/colibri-docker:latest \
  serve --host 0.0.0.0 --port 8000
```

The published image needs a CPU with AVX2. To pin a different upstream engine
revision, run the workflow manually (`workflow_dispatch`) with `colibri_ref`, or
build locally. To always use your own build, set `COLIBRI_IMAGE` to a local tag
and `COLIBRI_PULL_POLICY=never` in `.env`.

### Build for a specific CPU

`ARCH=x86-64-v3` produces a portable AVX2 binary. A more specific ISA level is
faster but only runs on a matching host:

```bash
ARCH=x86-64-v4 docker compose build
```

`ARCH=native` is deliberately not the default: it bakes in the build machine's
instruction set and the binary dies with `SIGILL` on a different CPU.

## ZimaOS / CasaOS

`zimaos/docker-compose.zimaos.yml` is a self-contained variant for ZimaOS and
CasaOS: no `.env` interpolation, no build step, plus the `x-casaos` metadata the
app store uses for the title, icon, and port mapping.

Install it from the ZimaOS desktop: **App Store -> + -> Install a customized app
-> Import**, then paste or upload the file. Two values need editing first:

- the model bind mount source, `/DATA/models/glm52_i4` by default;
- `COLI_ALLOWED_HOSTS`, which must list the hostname you browse to.

The API is published on port 8000 and the Swagger UI on 8081.

Check the hardware before installing. The published image is built for
`x86-64-v3`, so the CPU needs AVX2: ZimaBoard 2, ZimaBlade, and ZimaCube qualify,
ZimaBoard 1 (Apollo Lake) does not. Keep the model on an internal NVMe or SATA
SSD — a USB disk or an SMB/NFS share makes generation unusably slow.

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
