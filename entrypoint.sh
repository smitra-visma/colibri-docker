#!/bin/sh
# Optionally fetch the model before handing control to the colibri launcher.
#
# Off by default: with COLI_AUTO_DOWNLOAD unset, this is a plain exec and the
# image behaves exactly as if the launcher were the entrypoint. Set
# COLI_AUTO_DOWNLOAD=1 to have the container download COLI_MODEL_REPO into
# /model when the directory does not already hold a model.
set -eu

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
  echo "colibri: downloading $REPO into $MODEL_DIR (this takes a long time)"
  HF_HOME="${HF_HOME:-$MODEL_DIR/.hf-home}" \
  HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}" \
    /opt/hf/bin/hf download "$REPO" --local-dir "$MODEL_DIR"
  echo "colibri: download complete"
fi

exec python3 /app/coli "$@"
