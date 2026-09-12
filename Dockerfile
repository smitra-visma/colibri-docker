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
# Stage 3: runtime. The launcher and the HTTP gateway use only the Python
# standard library, so there is nothing to pip install. libgomp1 provides the
# OpenMP runtime the engine links against.
FROM debian:stable-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 libgomp1 && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 colibri
WORKDIR /app

COPY --from=build /src/c/colibri ./colibri
COPY --from=src /src/c/coli /src/c/version.py /src/c/openai_server.py \
                /src/c/v4_dsml.py /src/c/family_registry.py /src/c/resource_plan.py \
                /src/c/doctor.py /src/c/autotune.py ./
COPY --from=src /src/c/tools/ ./tools/

# COLI_DOCKER_GLM_ONLY makes the launcher reject a model from another family
# with a clear message instead of feeding it to the GLM engine: this image
# ships one engine binary, built from the `colibri` target.
ENV COLI_MODEL=/model \
    COLI_ENGINE=/app/colibri \
    COLI_DOCKER_GLM_ONLY=1 \
    PYTHONUNBUFFERED=1

# The bind-mounted model lands here; the VOLUME declares that contract.
VOLUME ["/model"]
# `coli serve` listens on 8000 by default.
EXPOSE 8000

USER colibri
ENTRYPOINT ["python3", "/app/coli"]
CMD ["info"]
