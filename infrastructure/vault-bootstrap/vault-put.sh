#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/pet-project-cluster.yaml}"
NAMESPACE="${NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
KUBECTL="kubectl --kubeconfig $KUBECONFIG"
SECRETS_FILE="${SECRETS_FILE:-$SCRIPT_DIR/secrets.json}"
INIT_FILE="${INIT_FILE:-$SCRIPT_DIR/init.json}"
VAULT_MOUNT="${VAULT_MOUNT:-infrastructure}"
POLICY_NAME="${POLICY_NAME:-external-secrets-read}"
TOKEN_SECRET_NAME="${TOKEN_SECRET_NAME:-vault-token}"

ROOT_TOKEN=$(jq -r '.root_token' "$INIT_FILE")
$KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault login "$ROOT_TOKEN" > /dev/null

if ! $KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault secrets list -format=json | jq -e "has(\"${VAULT_MOUNT}/\")" > /dev/null; then
  echo "Enabling KV engine at $VAULT_MOUNT..."
  $KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault secrets enable -path="$VAULT_MOUNT" kv-v2
else
  echo "KV already enabled at $VAULT_MOUNT"
fi

for service in $(jq -r 'keys[]' "$SECRETS_FILE"); do
  keys=$(jq -r --arg s "$service" '.[$s] | keys[]' "$SECRETS_FILE")
  args=()
  for key in $keys; do
    value=$(jq -r --arg s "$service" --arg k "$key" '.[$s][$k] // ""' "$SECRETS_FILE")
    if [ -z "$value" ]; then
      value=$(openssl rand -base64 32)
    fi
    args+=("$key=$value")
  done

  echo "Writing $VAULT_MOUNT/$service..."
  $KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- vault kv put "$VAULT_MOUNT/$service" "${args[@]}" > /dev/null
done

echo "Creating Vault policy $POLICY_NAME..."
$KUBECTL exec -i -n "$NAMESPACE" "$VAULT_POD" -- vault policy write "$POLICY_NAME" - <<EOF
path "$VAULT_MOUNT/data/*" {
  capabilities = ["read"]
}

path "$VAULT_MOUNT/metadata/*" {
  capabilities = ["list", "read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOF

echo "Creating limited token for External Secrets..."
ESO_TOKEN=$($KUBECTL exec -n "$NAMESPACE" "$VAULT_POD" -- \
  vault token create -policy="$POLICY_NAME" -no-default-policy=true -orphan -format=json | jq -r '.auth.client_token')

echo "Writing Kubernetes Secret $TOKEN_SECRET_NAME..."
$KUBECTL create secret generic "$TOKEN_SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=token="$ESO_TOKEN" \
  --dry-run=client \
  -o yaml | $KUBECTL apply -f - > /dev/null

echo "=== All infrastructure secrets written to Vault and External Secrets token created ==="
