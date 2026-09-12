#!/bin/sh
# Build and start the Qwen3.6 stack with podman (or docker).
#
#   ./run-qwen.sh --model-dir ~/models/qwen36
#
# Everything it does can be done by hand; see --help. The script exists to make
# the three easy mistakes impossible: forgetting MODEL_DIR, pointing it at a
# path the podman VM cannot see, and reading "unhealthy" as a failure while the
# model is still downloading.
set -eu

MODEL_DIR="${MODEL_DIR:-}"
PORT="${COLI_PORT:-18000}"
ARCH_ARG="${ARCH:-native}"
COMPOSE_FILE="$(dirname "$0")/docker-compose.qwen.yml"
ENGINE_ARG="${ENGINE:-qwen36}"
DO_BUILD=1
FOLLOW=1

usage() {
  cat <<USAGE
usage: $0 [--model-dir DIR] [--port PORT] [--arch ARCH] [--engine NAME]
          [--no-build] [--no-follow] [--down]

  --model-dir DIR  where the model lives, and is downloaded to if absent.
                   Defaults to \$MODEL_DIR.
  --port PORT      host port for the API (default $PORT).
  --arch ARCH      CPU target for the engine build (default $ARCH_ARG).
                   Use x86-64-v3 for a portable AVX2 binary, x86-64 for a
                   pre-Haswell CPU without AVX2.
  --engine NAME    upstream make target (default $ENGINE_ARG; qwen38 for
                   Qwen3.8-Flash-Next).
  --no-build       skip the image build, use the existing one.
  --no-follow      start and return instead of following the logs.
  --down           stop the stack and exit.
USAGE
}

DOWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model-dir) MODEL_DIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --arch) ARCH_ARG="$2"; shift 2 ;;
    --engine) ENGINE_ARG="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --no-follow) FOLLOW=0; shift ;;
    --down) DOWN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# podman is the default; docker works unchanged if that is what is installed.
if command -v podman >/dev/null 2>&1; then
  ENGINE_CMD=podman
elif command -v docker >/dev/null 2>&1; then
  ENGINE_CMD=docker
else
  echo "neither podman nor docker is installed" >&2
  exit 1
fi

compose() { "$ENGINE_CMD" compose -f "$COMPOSE_FILE" "$@"; }

if [ "$DOWN" = 1 ]; then
  MODEL_DIR="${MODEL_DIR:-/nonexistent}" compose down
  exit 0
fi

if [ -z "$MODEL_DIR" ]; then
  echo "set --model-dir (or MODEL_DIR) to the directory that holds the model" >&2
  exit 2
fi

mkdir -p "$MODEL_DIR"
# Resolve to an absolute path: a relative one confuses the bind mount, and the
# podman machine only shares a few host directories (\$HOME among them).
MODEL_DIR="$(cd "$MODEL_DIR" && pwd)"

if ! compose version >/dev/null 2>&1; then
  echo "$ENGINE_CMD compose is not available." >&2
  echo "  podman delegates to docker-compose: brew install docker-compose" >&2
  exit 1
fi

export MODEL_DIR COLI_PORT="$PORT" ARCH="$ARCH_ARG" ENGINE="$ENGINE_ARG"

if [ "$DO_BUILD" = 1 ]; then
  echo "building the $ENGINE_ARG engine for $ARCH_ARG (several minutes)"
  compose build
fi

echo "starting; model directory: $MODEL_DIR"
compose up -d

cat <<INFO

API:   http://localhost:$PORT/v1/chat/completions
check: curl -s http://localhost:$PORT/health

The first start downloads about 20 GB when the directory is empty, so the
container stays "starting" for a long while before it answers. Try:

  curl -s http://localhost:$PORT/v1/chat/completions \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"qwen3.6","messages":[{"role":"user","content":"Hi"}]}'

Stop it with: $0 --down
INFO

if [ "$FOLLOW" = 1 ]; then
  echo
  echo "following logs; Ctrl-C detaches and leaves it running"
  compose logs -f colibri
fi
