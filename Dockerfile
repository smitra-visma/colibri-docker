# colibri — CPU inference image exposing an OpenAI-compatible HTTP API.
#
# The engine source is fetched from the upstream repository at build time and
# compiled here, so this repository stays free of vendored third-party code.
# The model is never baked into the image: it is bind-mounted at /model.
#
#   docker compose build
#   MODEL_DIR=/nvme/glm52_i4 docker compose up

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
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential make && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY --from=src /src/c ./c
RUN make -C c colibri ARCH=${ARCH}

# --------------------------------------------------------------------------
# Stage 2b: the Hugging Face downloader, in its own virtualenv so the runtime
# image keeps no pip, no build tools and no Debian package churn. It is only
# used when COLI_AUTO_DOWNLOAD is set; the engine itself needs none of it.
FROM debian:stable-slim AS hf
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-venv ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m venv /opt/hf && \
    /opt/hf/bin/pip install --no-cache-dir "huggingface_hub[cli,hf_transfer]"

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

COPY --from=build /src/c/colibri ./colibri
COPY --from=src /src/c/coli /src/c/version.py /src/c/openai_server.py \
                /src/c/v4_dsml.py /src/c/family_registry.py /src/c/resource_plan.py \
                /src/c/doctor.py /src/c/autotune.py ./
COPY --from=src /src/c/tools/ ./tools/
COPY --from=hf /opt/hf /opt/hf
COPY entrypoint.sh ./entrypoint.sh

# COLI_AUTO_DOWNLOAD=1 makes the entrypoint fetch COLI_MODEL_REPO into /model
# when that directory holds no model yet; it needs a read-write mount owned by
# uid 1000. The default of 0 keeps startup offline.
# COLI_DOCKER_GLM_ONLY makes the launcher reject a model from another family
# with a clear message instead of feeding it to the GLM engine: this image
# ships one engine binary, built from the `colibri` target.
ENV COLI_MODEL=/model \
    COLI_ENGINE=/app/colibri \
    COLI_DOCKER_GLM_ONLY=1 \
    PYTHONUNBUFFERED=1 \
    COLI_AUTO_DOWNLOAD=0 \
    COLI_MODEL_REPO=mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp

# The bind-mounted model lands here; the VOLUME declares that contract.
VOLUME ["/model"]
# `coli serve` listens on 8000 by default.
EXPOSE 8000

USER colibri
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["info"]
