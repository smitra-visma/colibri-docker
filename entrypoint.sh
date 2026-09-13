#!/bin/sh
# Optionally fetch the model before handing control to the colibri launcher.
#
# Off by default: with COLI_AUTO_DOWNLOAD unset, this is a plain exec and the
# image behaves exactly as if the launcher were the entrypoint. Set
# COLI_AUTO_DOWNLOAD=1 to have the container download COLI_MODEL_REPO into
# /model when the directory does not already hold a model.
set -eu

# The gateway runs the engine as a child process and only sees its pipe close,
# so an engine killed by the kernel surfaces as "colibri engine exited
# unexpectedly" with nothing above it. The most common cause is an illegal
# instruction: the x86-64-v3 images need AVX2, which no CPU older than Haswell
# (2013) has. Running the binary with no arguments costs milliseconds and turns
# that into a message that says what to do. Set COLI_SKIP_PREFLIGHT=1 to skip.
if [ "${COLI_SKIP_PREFLIGHT:-0}" != "1" ]; then
  engine_bin=""
  if [ -n "${COLI_ENGINE:-}" ] && [ -x "${COLI_ENGINE}" ]; then
    engine_bin="${COLI_ENGINE}"
  else
    for candidate in colibri olmoe qwen36 qwen38 glm53 inkling kimi_k3; do
      if [ -x "/app/$candidate" ]; then engine_bin="/app/$candidate"; break; fi
    done
  fi
  if [ -n "$engine_bin" ]; then
    "$engine_bin" >/dev/null 2>&1 || engine_status=$?
    # 132 = 128 + SIGILL. The binary prints usage and exits 1 when it is fine.
    if [ "${engine_status:-0}" = "132" ]; then
      echo "colibri: the engine cannot run on this CPU (illegal instruction)." >&2
      echo "  This image is built for x86-64-v3, which requires AVX2." >&2
      echo "  Check the host with: grep -o avx2 /proc/cpuinfo | head -1" >&2
      echo "  No output means no AVX2. Use a baseline build instead, for" >&2
      echo "  example ghcr.io/smitra-visma/colibri-docker:olmoe-baseline," >&2
      echo "  or rebuild with --build-arg ARCH=x86-64." >&2
      exit 1
    fi
  fi
fi

case "${COLI_AUTO_DOWNLOAD:-0}" in
  1|true|True|TRUE|yes|on) ;;
  *) exec python3 /app/coli "$@" ;;
esac

MODEL_DIR="${COLI_MODEL:-/model}"
REPO="${COLI_MODEL_REPO:-mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp}"

# tokenizer.json is what the launcher itself checks for, so it is the honest
# test of "is there already a model here". A partial download leaves the
# huggingface_hub cache in place and resumes on the next run.
if [ -f "$MODEL_DIR/tokenizer.json" ]; then
  echo "colibri: model present in $MODEL_DIR, skipping download"
else
  if [ ! -w "$MODEL_DIR" ]; then
    echo "colibri: COLI_AUTO_DOWNLOAD is set but $MODEL_DIR is not writable." >&2
    echo "  Mount it read-write (drop the :ro flag) and make it writable by" >&2
    echo "  uid 1000, for example: chown -R 1000:1000 <host model dir>" >&2
    exit 1
  fi
  if [ "${COLI_CONVERT:-0}" = "1" ]; then
    # OLMoE has no published colibri container, so the image converts the
    # original checkpoint itself. The converter streams one source shard at a
    # time, so peak extra disk is one shard and peak RAM stays bounded.
    if [ ! -x /opt/conv/bin/python ]; then
      echo "colibri: COLI_CONVERT=1 but this image has no converter." >&2
      echo "  Use the olmoe image, or convert from an upstream checkout." >&2
      exit 1
    fi
    echo "colibri: converting $REPO into $MODEL_DIR (this takes a while)"
    HF_HOME="${HF_HOME:-$MODEL_DIR/.hf-home}" \
    HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}" \
      /opt/conv/bin/python /app/tools/convert_olmoe_merged.py \
        --repo "$REPO" --out "$MODEL_DIR"
    echo "colibri: conversion complete"
    exec python3 /app/coli "$@"
  fi
  # Each worker holds chunks in memory, so eight of them can outgrow a small
  # VM and the kernel kills the process with SIGKILL (exit 137). Cap them with
  # COLI_DOWNLOAD_WORKERS on a memory-constrained host.
  workers=""
  if [ -n "${COLI_DOWNLOAD_WORKERS:-}" ]; then
    workers="--max-workers ${COLI_DOWNLOAD_WORKERS}"
  fi
  echo "colibri: downloading $REPO into $MODEL_DIR (this takes a long time)"
  # Xet is the current fast transfer path; hf_transfer is deprecated and its
  # variable now only prints a warning.
  HF_HOME="${HF_HOME:-$MODEL_DIR/.hf-home}" \
  HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}" \
    /opt/hf/bin/hf download "$REPO" --local-dir "$MODEL_DIR" $workers
  echo "colibri: download complete"
fi

exec python3 /app/coli "$@"
