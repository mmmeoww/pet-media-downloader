#!/bin/bash
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/pet-project-cluster.yaml}"
NAMESPACE="${NAMESPACE:-vault}"
VAULT_SERVICE="${VAULT_SERVICE:-vault}"
VAULT_LOCAL_PORT="${VAULT_LOCAL_PORT:-18200}"
SECRETS_DIR="${SECRETS_DIR:-.}"
INIT_FILE="$SECRETS_DIR/init.json"

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

mkdir -p "$SECRETS_DIR"
start_vault_port_forward

echo -e "UNSEALING VAULT\nGetting Vault status"

STATUS_JSON=$(curl -fsS "$VAULT_ADDR/v1/sys/init" 2>/dev/null || true)

if ! echo "$STATUS_JSON" | jq empty >/dev/null 2>&1; then
  echo "Vault not ready or status unavailable - trying init anyway"
  INITIALIZED="false"
else
  INITIALIZED=$(echo "$STATUS_JSON" | jq -r '.initialized')
fi

echo "Initialized: ${INITIALIZED:-unknown}"

if [ "$INITIALIZED" != "true" ]; then
  echo -e "\nInitializing Vault"

  INIT_JSON=$(curl -fsS \
    -H "Content-Type: application/json" \
    --request POST \
    --data '{"secret_shares":5,"secret_threshold":3}' \
    "$VAULT_ADDR/v1/sys/init")

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

SEALED=$(curl -sS "$VAULT_ADDR/v1/sys/health" | jq -r '.sealed')

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

    curl -fsS \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$(jq -nc --arg key "${UNSEAL_KEYS[$i]}" '{key: $key}')" \
      "$VAULT_ADDR/v1/sys/unseal" > /dev/null
  done
fi

echo -e "\nFinal status"

until curl -sS "$VAULT_ADDR/v1/sys/health" | jq -e '.sealed == false' >/dev/null; do
  echo "waiting for vault..."
  sleep 1
done

echo "Vault is READY (unsealed)"
