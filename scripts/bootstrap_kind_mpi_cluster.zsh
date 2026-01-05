#!/usr/bin/env zsh
set -euo pipefail

# Usage:
#   scripts/bootstrap_kind_mpi_cluster.zsh [--recreate] [--no-operator] [--no-rbac]
#
# Env overrides:
#   CLUSTER_NAME=mpi
#   KIND_CONFIG=/path/to/kind-config.yaml
#   HELM_RELEASE=mpi-operator
#   HELM_NAMESPACE=mpi-operator
#   HELM_CHART=cowboysysop/mpi-operator
#   HELM_CHART_VERSION=1.2.2
#   PYTHON_BIN=/opt/homebrew/Caskroom/miniforge/base/bin/python

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

CLUSTER_NAME="${CLUSTER_NAME:-mpi}"
KIND_CONFIG="${KIND_CONFIG:-$ROOT_DIR/kind-5nodes.yaml}"

HELM_RELEASE="${HELM_RELEASE:-mpi-operator}"
HELM_NAMESPACE="${HELM_NAMESPACE:-mpi-operator}"
HELM_CHART="${HELM_CHART:-cowboysysop/mpi-operator}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-1.2.2}"

INSTALL_OPERATOR=1
PATCH_RBAC=1
RECREATE=0

while (( $# > 0 )); do
  case "$1" in
    --recreate)
      RECREATE=1
      ;;
    --no-operator)
      INSTALL_OPERATOR=0
      ;;
    --no-rbac)
      PATCH_RBAC=0
      ;;
    -h|--help)
      echo "Usage: $0 [--recreate] [--no-operator] [--no-rbac]" >&2
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--recreate] [--no-operator] [--no-rbac]" >&2
      exit 2
      ;;
  esac
  shift
done

# Basic prereqs
for cmd in docker kind kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done
if (( INSTALL_OPERATOR == 1 )); then
  if ! command -v helm >/dev/null 2>&1; then
    echo "Missing required command: helm" >&2
    exit 1
  fi
fi

# Ensure Docker is running.
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker Desktop and re-run." >&2
  exit 1
fi

# (Re)create cluster.
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  if (( RECREATE == 1 )); then
    kind delete cluster --name "$CLUSTER_NAME"
  fi
fi

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  if [[ ! -f "$KIND_CONFIG" ]]; then
    echo "Kind config not found: $KIND_CONFIG" >&2
    exit 1
  fi

  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi

kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# Wait for nodes.
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
kubectl get nodes -o wide

# Install / upgrade MPI Operator.
if (( INSTALL_OPERATOR == 1 )); then
  helm repo add cowboysysop https://cowboysysop.github.io/charts >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install "$HELM_RELEASE" "$HELM_CHART" \
    -n "$HELM_NAMESPACE" \
    --create-namespace \
    --version "$HELM_CHART_VERSION"

  kubectl -n "$HELM_NAMESPACE" rollout status deploy/mpi-operator --timeout=180s
  kubectl -n "$HELM_NAMESPACE" get pods -o wide
fi

# Patch RBAC so mpi-operator can update Role/RoleBinding objects it owns.
# (Some chart versions only grant create/list/watch on roles/rolebindings, which breaks reconciliation.)
if (( PATCH_RBAC == 1 )); then
  PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/Caskroom/miniforge/base/bin/python}"
  if [[ ! -x "$PYTHON_BIN" ]]; then
    PYTHON_BIN="python3"
  fi

  PATCH_JSON="$($PYTHON_BIN - <<'PY'
import json
import subprocess
import sys

doc = json.loads(subprocess.check_output(["kubectl", "get", "clusterrole", "mpi-operator", "-o", "json"]))
rules = doc.get("rules") or []

idx = None
for i, r in enumerate(rules):
    api_groups = set(r.get("apiGroups") or [])
    resources = set(r.get("resources") or [])
    if "rbac.authorization.k8s.io" in api_groups and {"roles", "rolebindings"}.issubset(resources):
        idx = i
        break

if idx is None:
    print("Could not find the rbac.authorization.k8s.io roles/rolebindings rule in ClusterRole/mpi-operator", file=sys.stderr)
    sys.exit(1)

patch = [
    {
        "op": "replace",
        "path": f"/rules/{idx}/verbs",
        "value": ["create", "get", "list", "watch", "update", "patch", "delete"],
    }
]
print(json.dumps(patch))
PY
  )"

  kubectl patch clusterrole mpi-operator --type='json' -p "$PATCH_JSON" >/dev/null

  # Restart operator to ensure it re-reconciles cleanly.
  kubectl -n "$HELM_NAMESPACE" rollout restart deploy/mpi-operator >/dev/null
  kubectl -n "$HELM_NAMESPACE" rollout status deploy/mpi-operator --timeout=180s

  # Create target namespace (for can-i check and later jobs).
  if [[ -f "$ROOT_DIR/k8s/namespace.yaml" ]]; then
    kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml" >/dev/null
  fi

  kubectl auth can-i update roles \
    --as=system:serviceaccount:"$HELM_NAMESPACE":mpi-operator \
    -n news-agent
fi

echo "Bootstrap complete: kind-$CLUSTER_NAME"