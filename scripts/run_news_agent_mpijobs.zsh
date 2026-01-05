#!/usr/bin/env zsh
set -euo pipefail

# Usage:
#   scripts/run_news_agent_mpijobs.zsh [--rerun] [--no-sync] [--no-image]
#
# This script:
# - syncs Python sources from ../my_agent/ into news-agent-image/app/ (so the image runs your latest code)
# - (optionally) rebuilds the news-agent-mpi:local image and loads it into the kind cluster
# - sources ~/.zshrc to load NEWS_API_KEY and HF_TOKEN
# - upserts the `news-agent-secrets` Secret in the `news-agent` namespace
# - applies the MPIJob manifests
# - optionally deletes+recreates the MPIJobs (--rerun) to force a new run

NAMESPACE="${NAMESPACE:-news-agent}"
SECRET_NAME="${SECRET_NAME:-news-agent-secrets}"

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

SYNC_CODE=1
BUILD_IMAGE=1
RERUN=0

while (( $# > 0 )); do
  case "$1" in
    --rerun)
      RERUN=1
      ;;
    --no-sync)
      SYNC_CODE=0
      ;;
    --no-image)
      BUILD_IMAGE=0
      ;;
    -h|--help)
      echo "Usage: $0 [--rerun] [--no-sync] [--no-image]" >&2
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--rerun] [--no-sync] [--no-image]" >&2
      exit 2
      ;;
  esac
  shift
done

if (( SYNC_CODE == 1 )); then
  MY_AGENT_DIR="$ROOT_DIR/../my_agent"
  APP_DIR="$ROOT_DIR/news-agent-image/app"

  if [[ ! -d "$MY_AGENT_DIR" ]]; then
    echo "Expected my_agent at: $MY_AGENT_DIR" >&2
    exit 1
  fi

  if [[ -L "$APP_DIR" ]]; then
    echo "Refusing to sync into symlinked app dir: $APP_DIR" >&2
    echo "Remove the symlink and re-run (we keep app/ as a real directory for Docker builds)." >&2
    exit 1
  fi

  mkdir -p "$APP_DIR"

  # Sanity check: entrypoints we expect the MPIJobs to run.
  REQUIRED_FILES=(dist_utils.py news_agent_hf_toolcall.py news_agent_langchain.py)
  for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$MY_AGENT_DIR/$f" ]]; then
      echo "Missing required file: $MY_AGENT_DIR/$f" >&2
      exit 1
    fi
  done

  # Sync *all* Python sources so you don't need to keep REQUIRED_FILES updated when
  # you refactor into multiple modules/packages.
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.git/' \
      --exclude 'k8s/' \
      --exclude '__pycache__/' \
      --exclude '*.pyc' \
      --include '*/' \
      --include '*.py' \
      --exclude '*' \
      "$MY_AGENT_DIR/" "$APP_DIR/"
  else
    PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/Caskroom/miniforge/base/bin/python}"
    if [[ ! -x "$PYTHON_BIN" ]]; then
      PYTHON_BIN="python3"
    fi

    MY_AGENT_DIR="$MY_AGENT_DIR" APP_DIR="$APP_DIR" "$PYTHON_BIN" - <<'PY'
import os
import shutil
from pathlib import Path

src = Path(os.environ["MY_AGENT_DIR"]).resolve()
dst = Path(os.environ["APP_DIR"]).resolve()

exclude_dirs = {".git", "k8s", "__pycache__"}

# Clean out existing .py tree in dst (best-effort)
for p in list(dst.rglob("*.py")):
    try:
        p.unlink()
    except FileNotFoundError:
        pass

for p in src.rglob("*.py"):
    if any(part in exclude_dirs for part in p.parts):
        continue
    rel = p.relative_to(src)
    (dst / rel).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, dst / rel)
PY
  fi
fi

if (( BUILD_IMAGE == 1 )); then
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found in PATH" >&2
    exit 1
  fi
  if ! command -v kind >/dev/null 2>&1; then
    echo "kind not found in PATH" >&2
    exit 1
  fi

  docker build -t news-agent-mpi:local "$ROOT_DIR/news-agent-image"

  if [[ -z "${KIND_CLUSTER:-}" ]]; then
    if kind get clusters | grep -qx 'mpi'; then
      KIND_CLUSTER='mpi'
    else
      CLUSTERS="$(kind get clusters)"
      if [[ "$(echo "$CLUSTERS" | grep -c .)" -eq 1 ]]; then
        KIND_CLUSTER="$CLUSTERS"
      else
        echo "Multiple kind clusters found; set KIND_CLUSTER=<name>" >&2
        echo "$CLUSTERS" >&2
        exit 1
      fi
    fi
  fi

  kind load docker-image --name "$KIND_CLUSTER" news-agent-mpi:local
fi

# Load local tokens (best-effort). Kubernetes pods cannot read your ~/.zshrc directly;
# this script bridges local -> cluster by writing/updating a k8s Secret.
if [[ -f "$HOME/.zshrc" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/.zshrc"
fi

if [[ -z "${NEWS_API_KEY:-}" || "${NEWS_API_KEY:-}" == "REPLACE_ME" ]]; then
  echo "NEWS_API_KEY is not set. Add it to ~/.zshrc (export NEWS_API_KEY=...) and re-run." >&2
  exit 1
fi
if [[ -z "${HF_TOKEN:-}" || "${HF_TOKEN:-}" == "REPLACE_ME" ]]; then
  echo "HF_TOKEN is not set. Add it to ~/.zshrc (export HF_TOKEN=...) and re-run." >&2
  exit 1
fi

# Ensure namespace exists.
kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml" >/dev/null

# Upsert Secret from a temp env-file (avoids placing secret values directly in argv).
TMP_ENV_FILE="$(mktemp)"
chmod 600 "$TMP_ENV_FILE"
{
  printf 'NEWS_API_KEY=%s\n' "$NEWS_API_KEY"
  printf 'HF_TOKEN=%s\n' "$HF_TOKEN"
} > "$TMP_ENV_FILE"

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-env-file="$TMP_ENV_FILE" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

rm -f "$TMP_ENV_FILE"

# Apply or rerun jobs.
if (( RERUN == 1 )); then
  kubectl -n "$NAMESPACE" delete mpijob news-agent-hf news-agent-langchain --ignore-not-found
fi

kubectl apply -f "$ROOT_DIR/k8s/mpijob-hf.yaml"
kubectl apply -f "$ROOT_DIR/k8s/mpijob-langchain.yaml"

kubectl -n "$NAMESPACE" get mpijob
kubectl -n "$NAMESPACE" get pods -o wide
