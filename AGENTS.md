# AGENTS.md — Инструкции для AI агентов

## Проект: pet-media-downloader

### KUBECONFIG
Всегда используй `~/.kube/clusters/pet-project-cluster.yaml` для kubectl/helm/helmfile.

### Helmfile
Работа ведётся в `infra-services/`.
- `stage=vault` — Vault, External Secrets Operator
- `stage=infrastructure` — PostgreSQL, RabbitMQ, MinIO, Redis

### Порядок развёртывания
1. `helmfile sync --selector stage=vault`
2. Если упало на eso-resources (webhook), повторить
3. `./scripts/vault-init.sh`
4. `helmfile sync --selector stage=infrastructure`

### Скрипты
- `infra-services/scripts/vault-init.sh` — ручная инициализация: init vault, unseal, запись секретов, создание K8s Secret `vault-token`

### Vault
- Standalone, не dev, PVC 10Gi, storageClass: local-path
- Путь секретов: `media-downloader/<service>`
- Единственный ключ на сервис: `password`
- RabbitMQ: `username` + `password` (username фиксированный `media_downloader`, erlangCookie рандомный)
- MinIO: `rootPassword`
- Подключение External Secrets: `vault-token` K8s Secret в ns vault

### HelmForge (официальные чарты вместо bitnami)
- `helmforge/postgresql` 2.0.4 — uses `docker.io/library/postgres:16`
- `helmforge/rabbitmq` 1.6.1 — uses `docker.io/library/rabbitmq:4.3.2-alpine`
- `helmforge/redis` 1.6.19 — uses `docker.io/library/redis:7-alpine`

### External Secrets
- ClusterSecretStore: `vault-backend` → `http://vault.vault:8200`, path `media-downloader`, auth by token
- ExternalSecrets: postgresql-credentials, rabbitmq-credentials (только password), minio-credentials, redis-credentials

### RabbitMQ definitions
ConfigMap `rabbitmq-definitions` в ns infra с queues/exchanges/bindings.