#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/pet-project-cluster.yaml}"
NAMESPACE="${NAMESPACE:-vault}"
VAULT_SERVICE="${VAULT_SERVICE:-vault}"
VAULT_LOCAL_PORT="${VAULT_LOCAL_PORT:-18200}"
SECRETS_FILE="${SECRETS_FILE:-$SCRIPT_DIR/secrets.json}"
INIT_FILE="${INIT_FILE:-$SCRIPT_DIR/init.json}"
VAULT_MOUNT="${VAULT_MOUNT:-infrastructure}"
POLICY_NAME="${POLICY_NAME:-external-secrets-read}"
TOKEN_SECRET_NAME="${TOKEN_SECRET_NAME:-vault-token}"

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG")
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""

cleanup() {
  if [ -n "$PORT_FORWARD_PID" ] && kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$PORT_FORWARD_LOG" ]; then
    rm -f "$PORT_FORWARD_LOG"
  fi
}
trap cleanup EXIT

start_vault_port_forward() {
  if [ -n "${VAULT_ADDR:-}" ]; then
    return
  fi

  export VAULT_ADDR="http://127.0.0.1:${VAULT_LOCAL_PORT}"
  PORT_FORWARD_LOG="$(mktemp)"

  "${KUBECTL[@]}" port-forward -n "$NAMESPACE" "svc/$VAULT_SERVICE" \
    "${VAULT_LOCAL_PORT}:8200" >"$PORT_FORWARD_LOG" 2>&1 &
  PORT_FORWARD_PID="$!"

  for _ in {1..30}; do
    if curl -sS "$VAULT_ADDR/v1/sys/init" >/dev/null 2>&1; then
      return
    fi

    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      echo "ERROR: failed to start Vault port-forward"
      cat "$PORT_FORWARD_LOG"
      exit 1
    fi

    sleep 1
  done

  echo "ERROR: Vault API is not reachable at $VAULT_ADDR"
  cat "$PORT_FORWARD_LOG"
  exit 1
}

vault_get() {
  local path="$1"
  curl -fsS \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    "$VAULT_ADDR/v1/$path"
}

vault_post() {
  local path="$1"
  local payload="$2"
  curl -fsS \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    --request POST \
    --data "$payload" \
    "$VAULT_ADDR/v1/$path"
}

start_vault_port_forward

ROOT_TOKEN=$(jq -r '.root_token' "$INIT_FILE")

if ! vault_get "sys/mounts" | jq -e "has(\"${VAULT_MOUNT}/\")" > /dev/null; then
  echo "Enabling KV engine at $VAULT_MOUNT..."
  vault_post "sys/mounts/$VAULT_MOUNT" \
    '{"type":"kv","options":{"version":"2"}}' > /dev/null
else
  echo "KV already enabled at $VAULT_MOUNT"
fi

for service in $(jq -r 'keys[]' "$SECRETS_FILE"); do
  keys=$(jq -r --arg s "$service" '.[$s] | keys[]' "$SECRETS_FILE")
  service_data="{}"

  for key in $keys; do
    value=$(jq -r --arg s "$service" --arg k "$key" '.[$s][$k] // ""' "$SECRETS_FILE")
    if [ -z "$value" ]; then
      value=$(openssl rand -base64 32)
    fi
    service_data=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<< "$service_data")
  done

  echo "Writing $VAULT_MOUNT/$service..."
  payload=$(jq -nc --argjson data "$service_data" '{data: $data}')
  vault_post "$VAULT_MOUNT/data/$service" "$payload" > /dev/null
done

echo "Creating Vault policy $POLICY_NAME..."
POLICY=$(cat <<EOF
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
)
vault_post "sys/policies/acl/$POLICY_NAME" \
  "$(jq -nc --arg policy "$POLICY" '{policy: $policy}')" > /dev/null

echo "Creating limited token for External Secrets..."
ESO_TOKEN=$(vault_post "auth/token/create" \
  "$(jq -nc --arg policy "$POLICY_NAME" '{policies: [$policy], no_default_policy: true, orphan: true}')" |
  jq -r '.auth.client_token')

echo "Writing Kubernetes Secret $TOKEN_SECRET_NAME..."
"${KUBECTL[@]}" create secret generic "$TOKEN_SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=token="$ESO_TOKEN" \
  --dry-run=client \
  -o yaml | "${KUBECTL[@]}" apply -f - > /dev/null

echo "=== All infrastructure secrets written to Vault and External Secrets token created ==="
