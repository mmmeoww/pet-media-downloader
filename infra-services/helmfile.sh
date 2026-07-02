#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/pet-project-cluster.yaml}"

helmfile -f "$SCRIPT_DIR/helmfile.yaml" "$@"
