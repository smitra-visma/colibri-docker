# colibri — CPU inference image exposing an OpenAI-compatible HTTP API.
#
# The engine source is fetched from the upstream repository at build time and
# compiled here, so this repository stays free of vendored third-party code.
# The model is never baked into the image: it is bind-mounted at /model.
#
#   docker compose build
#   MODEL_DIR=/nvme/glm52_i4 docker compose up
#
# Which engine the image contains is a build-time choice. ENGINE selects the
# upstream make target and the binary that ships:
#
#   ENGINE=colibri  GLM-5.2/5.3, ~372 GB model, 16 GB RAM minimum (default)
#   ENGINE=olmoe    OLMoE 1B-7B, ~7 GB int8 model, 8 GB RAM minimum
#
# The OLMoE build also carries a converter, because no prebuilt colibri
# container exists for that family: set CONVERTER=torch to include it.

# CONVERTER selects which converter stage the runtime copies from, so it has to
# be global: an ARG used in a FROM line must be declared before the first FROM.
ARG CONVERTER=none

# --------------------------------------------------------------------------
# Stage 1: fetch the engine sources at a pinned revision.
FROM debian:stable-slim AS src
ARG COLIBRI_REPO=https://github.com/JustVugg/colibri.git
ARG COLIBRI_REF=main
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git init -q . && \
    git remote add origin "${COLIBRI_REPO}" && \
    git fetch --depth 1 origin "${COLIBRI_REF}" && \
    git checkout -q FETCH_HEAD && \
    rm -rf .git

# --------------------------------------------------------------------------
# Stage 2: build the engine. ARCH defaults to x86-64-v3 (portable AVX2) rather
# than native: a native build bakes in the builder CPU's ISA and dies with
# SIGILL on a host with a different one. Override ARCH to target a known CPU.
FROM debian:stable-slim AS build
ARG ARCH=x86-64-v3
ARG ENGINE=colibri
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential make && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY --from=src /src/c ./c
RUN make -C c ${ENGINE} ARCH=${ARCH}

# --------------------------------------------------------------------------
# Stage 2b: the Hugging Face downloader, in its own virtualenv so the runtime
# image keeps no pip, no build tools and no Debian package churn. It is only
# used when COLI_AUTO_DOWNLOAD is set; the engine itself needs none of it.
FROM debian:stable-slim AS hf
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-venv ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m venv /opt/hf && \
    /opt/hf/bin/pip install --no-cache-dir "huggingface_hub[cli]"

# --------------------------------------------------------------------------
# Stage 2d: the web dashboard. `coli web` and the static handler in the gateway
# both serve web/dist next to openai_server.py, and that directory only exists
# once the React app is built, so build it here rather than shipping an image
# whose dashboard 404s.
FROM node:22-slim AS web
WORKDIR /build
COPY --from=src /src/web ./web
RUN cd web && npm ci && npm run build

# --------------------------------------------------------------------------
# Stage 2c: the checkpoint converter, used by the OLMoE image. OLMoE has no
# published colibri container, so the image has to be able to build one from
# the original weights. torch is pulled from the CPU wheel index: the GPU
# wheels are gigabytes of CUDA this image can never use. `conv-none` is the
# empty alternative, so the GLM image carries none of this.
FROM debian:stable-slim AS conv-none
RUN mkdir -p /opt/conv

FROM debian:stable-slim AS conv-torch
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-venv ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m venv /opt/conv && \
    /opt/conv/bin/pip install --no-cache-dir \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      torch numpy safetensors huggingface_hub

FROM conv-${CONVERTER} AS conv

# --------------------------------------------------------------------------
# Stage 3: runtime. The launcher and the HTTP gateway use only the Python
# standard library, so there is nothing to pip install. libgomp1 provides the
# OpenMP runtime the engine links against.
FROM debian:stable-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 libgomp1 ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 colibri
WORKDIR /app

ARG ENGINE=colibri
COPY --from=build /src/c/${ENGINE} ./${ENGINE}
COPY --from=src /src/c/coli /src/c/version.py /src/c/openai_server.py \
                /src/c/v4_dsml.py /src/c/family_registry.py /src/c/resource_plan.py \
                /src/c/doctor.py /src/c/autotune.py ./
COPY --from=src /src/c/tools/ ./tools/
COPY --from=web /build/web/dist ./web/dist
COPY --from=hf /opt/hf /opt/hf
COPY --from=conv /opt/conv /opt/conv
COPY entrypoint.sh ./entrypoint.sh

# COLI_AUTO_DOWNLOAD=1 makes the entrypoint fetch COLI_MODEL_REPO into /model
# when that directory holds no model yet; it needs a read-write mount owned by
# uid 1000. The default of 0 keeps startup offline.
#
# COLI_ENGINE pins the engine binary for the GLM image, where it pairs with
# COLI_DOCKER_GLM_ONLY=1 so a model of another family is rejected with a clear
# message instead of being fed to the GLM engine. Both are empty in the OLMoE
# image: with COLI_ENGINE unset the launcher resolves the engine from the
# model's own config, and finds /app/olmoe.
ARG COLI_ENGINE_PATH=/app/colibri
ARG GLM_ONLY=1
ARG MODEL_REPO=mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp
ARG CONVERT=0
ENV COLI_MODEL=/model \
    COLI_ENGINE=${COLI_ENGINE_PATH} \
    COLI_DOCKER_GLM_ONLY=${GLM_ONLY} \
    PYTHONUNBUFFERED=1 \
    COLI_AUTO_DOWNLOAD=0 \
    COLI_MODEL_REPO=${MODEL_REPO} \
    COLI_CONVERT=${CONVERT}

# The bind-mounted model lands here; the VOLUME declares that contract.
VOLUME ["/model"]
# `coli serve` listens on 8000 by default.
EXPOSE 8000

USER colibri
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["info"]
