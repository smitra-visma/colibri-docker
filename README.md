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

### Let the server container download it

The image can fetch the model itself on first start, into the same mounted
directory it serves from. In `.env`:

```ini
COLI_AUTO_DOWNLOAD=1
MODEL_MOUNT_MODE=rw
COLI_START_PERIOD=12h     # the healthcheck must outlast the download
```

Then `docker compose up -d`. The entrypoint downloads `MODEL_REPO` into
`/model` when `tokenizer.json` is not already there, and starts the server
afterwards. With the model already present it skips straight to serving, and
with `COLI_AUTO_DOWNLOAD=0` (the default) it never touches the network.

The container runs as uid 1000, so the host directory has to be writable by it:

```bash
sudo mkdir -p /nvme/glm52_i4 && sudo chown 1000:1000 /nvme/glm52_i4
```

Without that, startup stops with a message naming the directory rather than
failing halfway through a 372 GB transfer. Set `MODEL_MOUNT_MODE` back to `ro`
once the model is in place.

### With Compose, straight into the mounted directory

Set `MODEL_DIR` in `.env` first; the downloader writes into that same directory,
mounted read-write, so nothing lands in a container layer:

```bash
docker compose --profile download run --rm model-download
```

Change `MODEL_REPO` in `.env` to fetch a different repository, and set
`HF_TOKEN` if it is gated. Setting `HF_TOKEN` also lifts the
unauthenticated rate limit, which makes a large download noticeably faster. The download resumes: re-run the command after an
interruption and it continues from what is already on disk.

Without a Compose file — on ZimaOS, for instance — the same thing as one
command:

```bash
docker run --rm -v /DATA/models/glm52_i4:/model \
  -e HF_XET_HIGH_PERFORMANCE=1 -e HF_HOME=/model/.hf-home \
  python:3.12-slim sh -eu -c \
  'pip install --no-cache-dir -q "huggingface_hub[cli]" &&
   hf download mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp --local-dir /model'
```

The weights end up owned by root; the server mounts them read-only and reads
them as uid 1000, which works because the files are world-readable.

### On the host instead

```bash
python3 -m pip install -U "huggingface_hub[cli]"

export HF_XET_HIGH_PERFORMANCE=1        # Xet fast path
hf download mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp \
  --local-dir /nvme/glm52_i4
```

On an older `huggingface_hub`, the command is
`huggingface-cli download …` with the same arguments. Point `--local-dir` at the
directory you will set as `MODEL_DIR`, on a local NVMe filesystem.

Then verify the directory before starting the server:

```bash
docker run --rm -v /nvme/glm52_i4:/model:ro \
  ghcr.io/smitra-visma/colibri-docker:latest info
```

`info` prints the model layout it detected; `doctor` checks it more strictly.

A model from another family (Qwen3.6, Inkling, Kimi K3, DeepSeek V4) needs a
different engine binary that neither image contains — the launcher refuses
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
curl http://localhost:18000/v1/chat/completions \
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

client = OpenAI(base_url="http://localhost:18000/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="glm-5.2",
    messages=[{"role": "user", "content": "Hello"}],
).choices[0].message.content)
```

## API documentation

`docs/openapi.yaml` describes every endpoint. To browse it:

```bash
docker compose --profile docs up -d swagger-ui
open http://localhost:18080
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
| `MODEL_REPO` | `mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp` | Repository fetched by the downloader and by auto-download |
| `COLI_AUTO_DOWNLOAD` | `0` | `1` makes the server container download the model on first start |
| `COLI_CONVERT` | image default: `1` in the olmoe images, `0` in the GLM one | `1` converts the source checkpoint instead of downloading a prepared one; set it in the service's `environment` to override |
| `MODEL_MOUNT_MODE` | `ro` | Mount mode for `/model`; must be `rw` for auto-download |
| `COLI_START_PERIOD` | `10m` | Healthcheck grace period; raise it past the download time |
| `COLI_DOWNLOAD_WORKERS` | *(empty, hub default 8)* | Parallel download workers; set `2` on a low-memory host |
| `HF_TOKEN` | *(empty)* | Hugging Face token, for a gated or private repository |
| `COLI_MODEL_ID` | `glm-5.2` | Model name reported by the API and expected in requests |
| `COLI_PORT` | `18000` | Host port for the API; the container always listens on 8000 |
| `DOCS_PORT` | `18080` | Host port for the Swagger UI |
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

## Image variants

| Tag | Engine | Model | RAM |
| --- | --- | --- | --- |
| `latest` | GLM-5.2/5.3 | `mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp`, ~372 GB | 16 GB minimum, 24 GB comfortable |
| local build | Qwen3.6-35B-A3B | `Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64`, ~20 GB | 24 GB, full residency |
| `olmoe` | OLMoE 1B-7B | converted from `allenai/OLMoE-1B-7B-0125-Instruct`, ~7 GB int8 | 8 GB minimum |
| `olmoe-baseline` | OLMoE 1B-7B | same | same |

Each image ships exactly one engine binary and refuses a model from another
family. Pick the variant to match the hardware:

```ini
# .env — small machine
COLIBRI_IMAGE=ghcr.io/smitra-visma/colibri-docker:olmoe
MODEL_REPO=allenai/OLMoE-1B-7B-0125-Instruct
COLI_AUTO_DOWNLOAD=1
MODEL_MOUNT_MODE=rw
```

No colibri container is published for OLMoE, so the `olmoe` images carry a
converter and build one from the original weights on first start: with
`COLI_AUTO_DOWNLOAD=1` and `COLI_CONVERT=1` (the image default) the entrypoint
runs `convert_olmoe_merged.py` into `/model` instead of downloading. The
converter streams one source shard at a time, so it does not need to hold the
checkpoint in RAM.

`olmoe-baseline` is compiled for plain `x86-64` rather than `x86-64-v3`. Use it
on CPUs without AVX2 — anything older than Haswell (2013), which covers most
DDR3-era machines. Check with `grep -o avx2 /proc/cpuinfo | head -1`: no output
means the `x86-64-v3` images will die with `SIGILL`.

## Qwen3.6, built locally

No Qwen variant is published, so `docker-compose.qwen.yml` compiles the engine
on the machine that will run it:

```bash
cp .env.example .env                                   # set MODEL_DIR
docker compose -f docker-compose.qwen.yml build
docker compose -f docker-compose.qwen.yml up -d
```

Or use the wrapper, which picks podman or docker, resolves the model path, and
explains the long "starting" phase:

```bash
./run-qwen.sh --model-dir ~/models/qwen36
./run-qwen.sh --down
```

That file downloads the model itself on first start: `COLI_AUTO_DOWNLOAD`
defaults to `1` and `/model` is mounted read-write, because the Qwen container
is ~20 GB rather than GLM's 372 GB. The download runs only when `/model` holds
no `tokenizer.json`, so later restarts go straight to serving. Set
`COLI_AUTO_DOWNLOAD=0` to keep startup offline and use the `download` profile
instead.

It builds with `ENGINE=qwen36` and `ARCH=native`, which is safe because the
image never leaves this host; set `ARCH=x86-64-v3` in `.env` to keep it
portable. The model is the prebuilt int4-gs64 container
`Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64`, about 20 GB.

Qwen3.6 differs from GLM in one way that matters: it wants the container fully
resident, so **24 GB of RAM is the working minimum** rather than a comfort
figure. In exchange it is far faster than GLM on the same box — upstream
measures 1.44 tok/s on CPU, and 10.05 tok/s with the CUDA expert tier on two
8 GB cards.

`ENGINE=qwen38` in `.env` switches the build to Qwen3.8-Flash-Next instead;
that checkpoint is ~185 GB and CPU-only.

## Prebuilt image

`.github/workflows/publish.yml` builds `linux/amd64` for each variant in its
matrix and pushes to GHCR on every push to `main` and on every `v*` tag. Tags
published: `latest`, `main`, `sha-<short>` (and `X.Y.Z`, `X.Y` for a version
tag) for the GLM image; `olmoe` and `olmoe-sha-<short>`, `olmoe-baseline` and
`olmoe-baseline-sha-<short>` for the others.

Run it without this repository checked out:

```bash
docker run --rm -p 18000:8000 -v /nvme/glm52_i4:/model:ro \
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

That file runs the container as root (`user: "0:0"`) and mounts `/model`
read-write, because ZimaOS creates the model directory owned by root and an
external exFAT or NTFS disk fixes ownership at mount time, where `chown` does
nothing. Drop the `user` line if you keep the model on ext4 and chown it to uid
1000 yourself.

The API is published on host port 18000 and the Swagger UI on 18080. Both
avoid 8000/8080, which commonly collide with other services.

Check the hardware before installing. The published image is built for
`x86-64-v3`, so the CPU needs AVX2: ZimaBoard 2, ZimaBlade, and ZimaCube qualify,
ZimaBoard 1 (Apollo Lake) does not. Keep the model on an internal NVMe or SATA
SSD — a USB disk or an SMB/NFS share makes generation unusably slow.

## Ollama on ZimaOS

`zimaos/docker-compose.ollama.zimaos.yml` is unrelated to colibri and exists for
the case colibri cannot serve: a box whose RAM is too small for a streamed MoE
model. Ollama runs small dense models instead and exposes the same
OpenAI-compatible shape, on port 11434 under `/v1`.

Import it the same way (App Store -> + -> Install a customized app -> Import).
Edit the bind mount source, and `OLLAMA_MODEL` in the `ollama-pull` service,
which fetches one model once the server is healthy and then exits.

Sizing on a CPU-only NAS:

| Model | Download | Comfortable on |
| --- | --- | --- |
| `llama3.2:1b` | ~1.3 GB | 4 GB RAM |
| `llama3.2:3b` | ~2.0 GB | 8 GB RAM |
| `qwen2.5:7b` | ~4.7 GB | 12 GB RAM |
| `gpt-oss:20b` | ~14 GB | 24 GB RAM, slow without a GPU |

Call it exactly like the colibri stacks:

```bash
curl http://<host>:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"Hello"}]}'
```

## Operating notes

- `exited with code 137` during the download is the kernel OOM-killing it. Each
  download worker buffers chunks, so on a small host set
  `COLI_DOWNLOAD_WORKERS=2`. Under podman on macOS the limit is the VM, not the
  Mac: `podman machine set --memory 8192` (with the machine stopped) raises it.

- The healthcheck has a 10 minute `start_period`, because a cold load of a
  744B model from disk takes minutes. The container reports `starting` until
  then, not `unhealthy`.
- `docker compose down` stops the server; the model directory is untouched.
- Conversion of weights is out of scope for this image — it needs `torch`. Run
  it from an upstream checkout.

## License

This repository is Apache-2.0. The engine it builds is a separate project;
see [upstream's LICENSE](https://github.com/JustVugg/colibri/blob/main/LICENSE).
