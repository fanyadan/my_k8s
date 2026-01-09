#!/usr/bin/env zsh
set -euo pipefail

# Usage:
#   scripts/bootstrap_kind_mpi_cluster.zsh [--recreate] [--no-operator] [--no-rbac] [--cluster-rbac] [--namespaced-rbac]
#
# Env overrides:
#   CLUSTER_NAME=mpi
#   KIND_CONFIG=/path/to/kind-config.yaml
#   HELM_RELEASE=mpi-operator
#   HELM_NAMESPACE=mpi-operator
#   HELM_CHART=cowboysysop/mpi-operator
#   HELM_CHART_VERSION=1.2.2
#   TARGET_NAMESPACE=news-agent
#   RBAC_MODE=namespaced   # namespaced (default), cluster (chart RBAC, no patch), or none
#   SERVICE_ACCOUNT=mpi-operator

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

CLUSTER_NAME="${CLUSTER_NAME:-mpi}"
KIND_CONFIG="${KIND_CONFIG:-$ROOT_DIR/kind-5nodes.yaml}"

HELM_RELEASE="${HELM_RELEASE:-mpi-operator}"
HELM_NAMESPACE="${HELM_NAMESPACE:-mpi-operator}"
HELM_CHART="${HELM_CHART:-cowboysysop/mpi-operator}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-1.2.2}"

INSTALL_OPERATOR=1
RECREATE=0
TARGET_NAMESPACE="${TARGET_NAMESPACE:-news-agent}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-mpi-operator}"

# RBAC_MODE: namespaced (default, multi-tenant friendly), cluster (use chart RBAC as-is), or none.
RBAC_MODE="${RBAC_MODE:-namespaced}"
# Backward compatibility: PATCH_RBAC previously triggered a ClusterRole patch; now it just toggles RBAC_MODE.
if [[ -n "${PATCH_RBAC:-}" ]]; then
  if [[ "$PATCH_RBAC" -eq 1 ]]; then
    RBAC_MODE="cluster"
  else
    RBAC_MODE="none"
  fi
fi

while (( $# > 0 )); do
  case "$1" in
    --recreate)
      RECREATE=1
      ;;
    --no-operator)
      INSTALL_OPERATOR=0
      ;;
    --no-rbac)
      RBAC_MODE="none"
      ;;
    --cluster-rbac)
      RBAC_MODE="cluster"
      ;;
    --namespaced-rbac)
      RBAC_MODE="namespaced"
      ;;
    -h|--help)
      echo "Usage: $0 [--recreate] [--no-operator] [--no-rbac] [--cluster-rbac] [--namespaced-rbac]" >&2
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--recreate] [--no-operator] [--no-rbac] [--cluster-rbac] [--namespaced-rbac]" >&2
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

# Ensure target namespace exists before RBAC bindings or job creation.
if [[ -f "$ROOT_DIR/k8s/namespace.yaml" ]]; then
  kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml" >/dev/null
else
  kubectl get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$TARGET_NAMESPACE" >/dev/null
fi

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

case "$RBAC_MODE" in
  cluster)
    echo "Using chart-provided cluster RBAC (no patch applied)."
    kubectl auth can-i update roles \
      --as=system:serviceaccount:"$HELM_NAMESPACE":"$SERVICE_ACCOUNT" \
      -n "$TARGET_NAMESPACE"
    ;;
  namespaced)
    # Namespace-scoped RBAC for multi-tenant clusters: allow the operator serviceaccount to manage
    # Roles/RoleBindings it owns only in the target namespace.
    cat <<EOF | kubectl -n "$TARGET_NAMESPACE" apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mpi-operator-rbac
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF

    cat <<EOF | kubectl -n "$TARGET_NAMESPACE" apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mpi-operator-rbac
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: mpi-operator-rbac
subjects:
- kind: ServiceAccount
  name: "$SERVICE_ACCOUNT"
  namespace: "$HELM_NAMESPACE"
EOF

    kubectl auth can-i update roles \
      --as=system:serviceaccount:"$HELM_NAMESPACE":"$SERVICE_ACCOUNT" \
      -n "$TARGET_NAMESPACE"
    ;;
  none)
    echo "Skipping RBAC adjustments (RBAC_MODE=none)"
    ;;
  *)
    echo "Unknown RBAC_MODE: $RBAC_MODE" >&2
    exit 2
    ;;
esac

echo "Bootstrap complete: kind-$CLUSTER_NAME"
