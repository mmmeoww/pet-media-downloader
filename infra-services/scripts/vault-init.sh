#!/bin/bash
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/pet-project-cluster.yaml}"
NAMESPACE="vault"
VAULT_POD="vault-0"
SECRETS_DIR="./vault-credentials"

mkdir -p "$SECRETS_DIR"

echo "=== 1. Init Vault ==="
INIT_JSON=$(kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault operator init -format=json -key-shares=5 -key-threshold=3)

ROOT_TOKEN=$(echo "$INIT_JSON" | jq -r '.root_token')
echo "$ROOT_TOKEN" > "$SECRETS_DIR/root-token.txt"

UNSEAL_KEYS=$(echo "$INIT_JSON" | jq -r '.unseal_keys_b64[]')
echo "$UNSEAL_KEYS" > "$SECRETS_DIR/unseal-keys.txt"

echo "Root token: $ROOT_TOKEN"
echo "Unseal keys saved to $SECRETS_DIR/unseal-keys.txt"

echo "=== 2. Unseal Vault ==="
for key in $(echo "$UNSEAL_KEYS" | head -3); do
  kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault operator unseal "$key" > /dev/null
done

echo "=== 3. Login ==="
kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault login "$ROOT_TOKEN" > /dev/null

echo "=== 4. Enable KV v2 ==="
kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault secrets enable -path=media-downloader kv-v2 > /dev/null 2>&1 || true

echo "=== 5. Create secrets ==="
kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault kv put media-downloader/postgresql \
  postgres-password="$(openssl rand -base64 32)" \
  user-password="$(openssl rand -base64 32)" > /dev/null

kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault kv put media-downloader/rabbitmq \
  username="media_downloader" \
  password="$(openssl rand -base64 32)" \
  erlangCookie="$(openssl rand -base64 32)" > /dev/null

kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault kv put media-downloader/minio \
  rootPassword="$(openssl rand -base64 32)" > /dev/null

kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault kv put media-downloader/redis \
  password="$(openssl rand -base64 32)" > /dev/null

echo "=== 6. Create ESO token ==="
EXTERNAL_TOKEN=$(kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- vault token create -policy=root -field=token)
echo "$EXTERNAL_TOKEN" > "$SECRETS_DIR/eso-token.txt"

kubectl create secret generic vault-token -n "$NAMESPACE" --from-literal=token="$EXTERNAL_TOKEN" --dry-run=client -o yaml | kubectl apply -f -

echo "=== DONE ==="
echo "Root token:     $SECRETS_DIR/root-token.txt"
echo "Unseal keys:    $SECRETS_DIR/unseal-keys.txt"
echo "ESO token:      $SECRETS_DIR/eso-token.txt"
echo ""
echo "To unseal later (after restart):"
echo "  kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal \$(head -1 $SECRETS_DIR/unseal-keys.txt)"
echo "  kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal \$(sed -n '2p' $SECRETS_DIR/unseal-keys.txt)"
echo "  kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal \$(sed -n '3p' $SECRETS_DIR/unseal-keys.txt)"
