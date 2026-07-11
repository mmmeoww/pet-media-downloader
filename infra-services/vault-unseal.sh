#!/bin/bash
set -euo pipefail

KUBECONFIG="$HOME/.kube/clusters/pet-project-cluster.yaml"
NAMESPACE="vault"
VAULT_POD="vault-0"
KUBECTL="kubectl --kubeconfig $KUBECONFIG"

SECRETS_DIR="vault-credentials"
INIT_FILE="$SECRETS_DIR/init.json"

INITIALIZED=$($KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault status -format=json | jq -r '.initialized // false')

mkdir -p "$SECRETS_DIR"

if [ "$INITIALIZED" = "true" ]; then
  echo "Vault already initialized, unsealing with saved keys..."
  if [ ! -f "$INIT_FILE" ]; then
    echo "ERROR: init.json not found at $INIT_FILE"
    echo "Cannot unseal without keys. Delete PVC and re-init, or provide keys manually."
    exit 1
  fi
  UNSEAL_KEYS=$(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
else
  echo "=== 1. Init Vault ==="
  INIT_JSON=$($KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault operator init -format=json -key-shares=5 -key-threshold=3)

  echo "$INIT_JSON" > "$INIT_FILE"
  echo "Init saved to $INIT_FILE"

  UNSEAL_KEYS=$(echo "$INIT_JSON" | jq -r '.unseal_keys_b64[]')
fi

echo "=== 2. Unseal Vault ==="
for key in $(echo "$UNSEAL_KEYS" | head -3); do
  $KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault operator unseal "$key" > /dev/null
done

echo "=== 3. Check seal status ==="
SEALED=$($KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault status -format=json | jq -r '.sealed')
if [ "$SEALED" = "false" ]; then
  echo "Vault is unsealed"
else
  echo "ERROR: Vault is still sealed"
  exit 1
fi