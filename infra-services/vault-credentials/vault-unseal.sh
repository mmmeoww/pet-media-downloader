#!/bin/bash
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/pet-project-cluster.yaml}"
NAMESPACE="${NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
SECRETS_DIR="${SECRETS_DIR:-.}"
INIT_FILE="$SECRETS_DIR/init.json"

KUBECTL="kubectl --kubeconfig $KUBECONFIG"

mkdir -p "$SECRETS_DIR"

echo -e "UNSEALING VAULT\nGetting Vault status"

STATUS_JSON=$($KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- \
  /bin/vault status -format=json 2>/dev/null || true)

if ! echo "$STATUS_JSON" | jq empty >/dev/null 2>&1; then
  echo "Vault not ready or status unavailable — trying init anyway"
  INITIALIZED="false"
else
  INITIALIZED=$(echo "$STATUS_JSON" | jq -r '.initialized')
fi

echo "Initialized: ${INITIALIZED:-unknown}"

if [ "$INITIALIZED" != "true" ]; then
  echo -e "\nInitializing Vault"

  INIT_JSON=$($KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- \
    /bin/vault operator init -format=json \
    -key-shares=5 -key-threshold=3)

  echo "$INIT_JSON" > "$INIT_FILE"
  chmod 600 "$INIT_FILE"

  echo "Init saved to: $INIT_FILE"
else
  echo -e "\nVault already initialized"

  if [ ! -f "$INIT_FILE" ]; then
    echo "ERROR: init.json not found"
    exit 1
  fi

  INIT_JSON=$(cat "$INIT_FILE")
fi

echo -e "\nUnsealing Vault"

SEALED=$($KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- \
  vault status -format=json | jq -r '.sealed')

if [ "$SEALED" = "false" ]; then
  echo -e "Vault already unsealed\nSkipping unseal step"
else
  mapfile -t UNSEAL_KEYS < <(echo "$INIT_JSON" | jq -r '.unseal_keys_b64[]')

  if [ "${#UNSEAL_KEYS[@]}" -lt 3 ]; then
    echo "ERROR: not enough unseal keys"
    exit 1
  fi

  for i in 0 1 2; do
    echo "Applying unseal key $((i+1))/3"

    $KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- \
      /bin/vault operator unseal "${UNSEAL_KEYS[$i]}"
  done
fi

echo -e "\nFinal status"

until $KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault status -format=json | jq -e '.sealed == false' >/dev/null; do
  echo "waiting for vault..."
  sleep 1
done

echo "✅ Vault is READY (unsealed)"