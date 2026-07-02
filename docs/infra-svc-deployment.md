# Развёртывание инфраструктурных сервисов: Media Downloader (MVP)

## Цель

Описать процесс интеграции всех инфраструктурных и прикладных сервисов в Kubernetes-кластер через `helmfile.sh`.

## Принципиальные требования

1. **Все сервисы** — инфраструктурные (PostgreSQL, RabbitMQ, MinIO, Redis), мониторинговые (Prometheus, Grafana, Loki), прикладные (Bot Service, Downloader Worker, Converter Worker, Cleanup CronJob) — устанавливаются строго через `helmfile.sh`.
2. **werf** используется **только** для сборки и публикации Docker-образов. werf-конвергенция как метод деплоя **не применяется**. Вместо этого werf-собранные образы указываются в values helm-чартов, которые раскатываются helmfile.
3. **Vault конфигурируется до всех сервисов**, которым нужны секреты.
4. **External Secrets Operator** устанавливается после Vault и до всех сервисов, использующих Kubernetes Secrets.
5. **Сервисы стартуют только после того**, как External Secrets создал Kubernetes Secrets.

---

## 1. Общая архитектура развёртывания

### 1.1 Стратегия деплоя

```
Vagrant + Ansible → Kubernetes cluster
                         ↓
              helmfile install         ← Vault (stage 1)
              helmfile install         ← External Secrets (stage 2)
              helmfile install         ← инфраструктурные сервисы (stage 3)
              helmfile install         ← мониторинг (stage 4)
              helmfile install         ← прикладные сервисы (stage 5)
```

### 1.2 Компоненты

| Компонент | Версия (рекомендуемая) | Helm-чарт | Назначение |
|---|---|---|---|
| **Vault** | 1.18+ | hashicorp/vault (official) | Хранилище секретов |
| **External Secrets Operator** | 0.10+ | external-secrets/external-secrets | Синхронизация Vault → K8s Secrets |
| **PostgreSQL** | 16 | bitnami/postgresql (или cloudnative-pg) | Основная БД |
| **RabbitMQ** | 4.0 | bitnami/rabbitmq | Очередь задач |
| **MinIO** | RELEASE.2024 | minio/minio (или bitnami/minio) | S3-объектное хранилище |
| **Redis** | 7.4 | bitnami/redis | Кэш (опционально в MVP) |
| **Prometheus Stack** | latest | prometheus-community/kube-prometheus-stack | Мониторинг + AlertManager |
| **Loki Stack** | latest | grafana/loki-stack | Агрегация логов |
| **Bot Service** | — | собственный helm-чарт | Telegram-бот (aiogram) |
| **Downloader Worker** | — | собственный helm-чарт | Скачивание медиа |
| **Converter Worker** | — | собственный helm-чарт | Конвертация |
| **Cleanup CronJob** | — | собственный helm-чарт | Очистка старых файлов |

### 1.3 Порядок установки (stage-зависимости)

```
Stage 0: kubernetes cluster (Vagrant + Ansible)
  ├─ containerd, kubeadm, kubelet, kubectl
  ├─ Calico (CNI)
  ├─ Longhorn / Rook-Ceph (опциональный PVC)
  └─ kubeconfig → ~/.kube/clusters/pet-project-cluster.yaml

Stage 1: Helm + helmfile bootstrap
  ├─ Установка Helm (если не установлен)
  ├─ Установка helmfile
  └─ Добавление Helm-репозиториев

Stage 2: Vault (установка + инициализация)
  ├─ helmfile install vault
  ├─ vault init + unseal
  ├─ настройка AppRole / Token
  └─ создание секретов в Vault

Stage 3: External Secrets Operator
  ├─ helmfile install external-secrets
  ├─ создание SecretStore (подключение к Vault)
  └─ создание ExternalSecret-ресурсов

Stage 4: Инфраструктурные сервисы (зависимы от K8s Secrets)
  ├─ PostgreSQL
  ├─ RabbitMQ
  ├─ MinIO
  └─ Redis (опционально)

Stage 5: Мониторинг
  ├─ kube-prometheus-stack (Prometheus + Grafana + AlertManager)
  └─ loki-stack (Loki + Promtail)

Stage 6: Прикладные сервисы
  ├─ Bot Service
  ├─ Downloader Worker
  ├─ Converter Worker
  └─ Cleanup CronJob
```

---

## 2. Структура helmfile-конфигурации

### 2.1 Директории

```
infra-services/
├── helmfile.sh                        # точка входа
├── helmfile.yaml                      # головной helmfile
├── helmfile.yaml.gotmpl               # шаблон для общих значений
├── environments/
│   ├── dev.yaml                       # environment-специфичные параметры
│   └── prod.yaml
├── values/
│   ├── vault.yaml
│   ├── external-secrets.yaml
│   ├── postgresql.yaml
│   ├── rabbitmq.yaml
│   ├── minio.yaml
│   ├── redis.yaml
│   ├── kube-prometheus-stack.yaml
│   ├── loki-stack.yaml
│   ├── bot-service.yaml
│   ├── downloader-worker.yaml
│   ├── converter-worker.yaml
│   └── cleanup-cronjob.yaml
├── secrets/
│   └── values.yaml                    # зашифровано (sops / helm-secrets)
└── patches/
    └── postgresql-storage.yaml        # overrides для storage
```

### 2.2 Головной helmfile.yaml

```yaml
# infra-services/helmfile.yaml
repositories:
  - name: hashicorp
    url: https://helm.releases.hashicorp.com
  - name: external-secrets
    url: https://charts.external-secrets.io
  - name: bitnami
    url: https://charts.bitnami.com/bitnami
  - name: minio
    url: https://charts.min.io
  - name: prometheus-community
    url: https://prometheus-community.github.io/helm-charts
  - name: grafana
    url: https://grafana.github.io/helm-charts
  - name: media-downloader
    url: oci://ghcr.io/<your-org>/helm-charts  # собственные чарты

context: pet-project-cluster  # kubeconfig context

environments:
  dev:
    values:
      - environments/dev.yaml
  prod:
    values:
      - environments/prod.yaml

---
# Stage 2: Vault
{{ if .Values.vault.enabled }}
releases:
  - name: vault
    namespace: vault
    createNamespace: true
    chart: hashicorp/vault
    version: 0.28.1
    values:
      - values/vault.yaml
    labels:
      stage: vault
      component: secrets
{{ end }}

---
# Stage 3: External Secrets Operator
{{ if .Values.externalSecrets.enabled }}
releases:
  - name: external-secrets
    namespace: external-secrets
    createNamespace: true
    chart: external-secrets/external-secrets
    version: 0.10.0
    values:
      - values/external-secrets.yaml
    labels:
      stage: external-secrets
      component: secrets
    needs:
      - vault/vault
{{ end }}

---
# Stage 4: Infrastructure services
{{ if .Values.postgresql.enabled }}
releases:
  - name: postgresql
    namespace: media-downloader
    createNamespace: true
    chart: bitnami/postgresql
    version: 15.5.30
    values:
      - values/postgresql.yaml
    labels:
      stage: infrastructure
      component: database
    needs:
      - external-secrets/external-secrets
    # Этот release не стартует, пока ExternalSecret не создал Secret
    # Проверка: helmfile template покажет secretRef → он будет отсутствовать → helmfile install упадёт
    # Решение: external-secrets создаёт Secret ДО того, как helmfile переходит к этому release
    # Благодаря needs: запуск postgresql произойдёт только после того,
    # как external-secrets запущен и успел создать Secret (initContainers может ждать)
    hooks:
      - events: ["prepare"]
        showlog: true
        command: "bash"
        args:
          - -c
          - "kubectl get secret postgresql-credentials -n media-downloader || (echo 'Waiting for postgresql-credentials secret...'; exit 1)"
{{ end }}

---
{{ if .Values.rabbitmq.enabled }}
releases:
  - name: rabbitmq
    namespace: media-downloader
    chart: bitnami/rabbitmq
    version: 14.6.6
    values:
      - values/rabbitmq.yaml
    labels:
      stage: infrastructure
      component: messaging
    needs:
      - external-secrets/external-secrets
{{ end }}

---
{{ if .Values.minio.enabled }}
releases:
  - name: minio
    namespace: media-downloader
    chart: minio/minio
    version: 5.2.0
    values:
      - values/minio.yaml
    labels:
      stage: infrastructure
      component: storage
    needs:
      - external-secrets/external-secrets
{{ end }}

---
{{ if .Values.redis.enabled }}
releases:
  - name: redis
    namespace: media-downloader
    chart: bitnami/redis
    version: 19.6.4
    values:
      - values/redis.yaml
    labels:
      stage: infrastructure
      component: cache
    needs:
      - external-secrets/external-secrets
{{ end }}

---
# Stage 5: Monitoring
{{ if .Values.prometheus.enabled }}
releases:
  - name: kube-prometheus-stack
    namespace: monitoring
    createNamespace: true
    chart: prometheus-community/kube-prometheus-stack
    version: 61.7.0
    values:
      - values/kube-prometheus-stack.yaml
    labels:
      stage: monitoring
      component: prometheus
    needs:
      - vault/vault
      - external-secrets/external-secrets
{{ end }}

---
{{ if .Values.loki.enabled }}
releases:
  - name: loki-stack
    namespace: monitoring
    chart: grafana/loki-stack
    version: 2.10.2
    values:
      - values/loki-stack.yaml
    labels:
      stage: monitoring
      component: logging
    needs:
      - vault/vault
      - external-secrets/external-secrets
{{ end }}

---
# Stage 6: Application services
{{ if .Values.botService.enabled }}
releases:
  - name: bot-service
    namespace: media-downloader
    chart: media-downloader/bot-service
    version: 0.1.0
    values:
      - values/bot-service.yaml
    secrets:
      - secrets/values.yaml
    labels:
      stage: application
      component: bot
    needs:
      - media-downloader/postgresql
      - media-downloader/rabbitmq
      - media-downloader/minio
{{ end }}

---
{{ if .Values.downloaderWorker.enabled }}
releases:
  - name: downloader-worker
    namespace: media-downloader
    chart: media-downloader/downloader-worker
    version: 0.1.0
    values:
      - values/downloader-worker.yaml
    secrets:
      - secrets/values.yaml
    labels:
      stage: application
      component: worker
    needs:
      - media-downloader/postgresql
      - media-downloader/rabbitmq
      - media-downloader/minio
{{ end }}

---
{{ if .Values.converterWorker.enabled }}
releases:
  - name: converter-worker
    namespace: media-downloader
    chart: media-downloader/converter-worker
    version: 0.1.0
    values:
      - values/converter-worker.yaml
    secrets:
      - secrets/values.yaml
    labels:
      stage: application
      component: worker
    needs:
      - media-downloader/postgresql
      - media-downloader/rabbitmq
      - media-downloader/minio
{{ end }}

---
{{ if .Values.cleanupCronJob.enabled }}
releases:
  - name: cleanup-cronjob
    namespace: media-downloader
    chart: media-downloader/cleanup-cronjob
    version: 0.1.0
    values:
      - values/cleanup-cronjob.yaml
    secrets:
      - secrets/values.yaml
    labels:
      stage: application
      component: cronjob
    needs:
      - media-downloader/postgresql
      - media-downloader/minio
{{ end }}
```

### 2.3 helmfile.sh (доработанный)

```bash
#!/bin/bash
set -euo pipefail

# Автоматический выбор kubeconfig
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/pet-project-cluster.yaml}"

# Цветной вывод
GREEN='\033[0;32m'
NC='\033[0m'

info() {
  echo -e "${GREEN}[helmfile]${NC} $*"
}

# Дефолтный environment
ENVIRONMENT="${HELMFILE_ENV:-dev}"

case "${1:-}" in
  sync)
    info "Syncing all releases for environment: $ENVIRONMENT"
    helmfile --environment "$ENVIRONMENT" sync
    ;;
  apply)
    info "Applying all releases for environment: $ENVIRONMENT"
    helmfile --environment "$ENVIRONMENT" apply
    ;;
  destroy)
    info "Destroying all releases for environment: $ENVIRONMENT"
    helmfile --environment "$ENVIRONMENT" destroy
    ;;
  diff)
    helmfile --environment "$ENVIRONMENT" diff
    ;;
  lint)
    helmfile --environment "$ENVIRONMENT" lint
    ;;
  template)
    helmfile --environment "$ENVIRONMENT" template
    ;;
  *)
    # Прокидываем все остальные аргументы напрямую в helmfile
    helmfile --environment "$ENVIRONMENT" "$@"
    ;;
esac
```

### 2.4 environment/dev.yaml

```yaml
# infra-services/environments/dev.yaml
environment: dev
namespace: media-downloader

vault:
  enabled: true
  mode: dev  # dev или ha

externalSecrets:
  enabled: true

postgresql:
  enabled: true
  storageClass: longhorn
  storageSize: 10Gi

rabbitmq:
  enabled: true
  storageClass: longhorn
  storageSize: 5Gi

minio:
  enabled: true
  storageClass: longhorn
  storageSize: 50Gi

redis:
  enabled: true
  storageClass: longhorn
  storageSize: 1Gi

prometheus:
  enabled: true

loki:
  enabled: true

botService:
  enabled: true
  imageTag: latest

downloaderWorker:
  enabled: true
  imageTag: latest

converterWorker:
  enabled: true
  imageTag: latest

cleanupCronJob:
  enabled: true
  imageTag: latest
```

### 2.5 environments/prod.yaml

```yaml
# infra-services/environments/prod.yaml
environment: prod
namespace: media-downloader

vault:
  enabled: true
  mode: ha
  replicas: 3

externalSecrets:
  enabled: true
  replicas: 2

postgresql:
  enabled: true
  storageClass: longhorn
  storageSize: 100Gi
  replicas: 3  # Patroni / cloudnative-pg кластер

rabbitmq:
  enabled: true
  storageClass: longhorn
  storageSize: 20Gi
  replicas: 3

minio:
  enabled: true
  storageClass: longhorn
  storageSize: 500Gi
  replicas: 4  # MinIO distributed mode
  mode: distributed

redis:
  enabled: true
  storageClass: longhorn
  storageSize: 5Gi
  replicas: 3  # Redis Cluster

prometheus:
  enabled: true
  retention: 30d

loki:
  enabled: true
  retention: 14d

botService:
  enabled: true
  imageTag: stable
  replicas: 2

downloaderWorker:
  enabled: true
  imageTag: stable
  minReplicas: 2
  maxReplicas: 10

converterWorker:
  enabled: true
  imageTag: stable
  minReplicas: 2
  maxReplicas: 5

cleanupCronJob:
  enabled: true
  imageTag: stable
```

---

## 3. Vault: установка, инициализация и конфигурация

### 3.1 Установка Vault через helmfile

```yaml
# infra-services/values/vault.yaml
global:
  enabled: true

server:
  # Режим разработки — 1 pod, авто-unseal (dev).
  # Для HA: mode: ha, replicas: 3, haBackend: raft
  dev:
    enabled: true

  # Для standalone/HA (без dev mode):
  standalone:
    enabled: false

  # Настройки persistent storage
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: longhorn

  # Service
  service:
    enabled: true
    type: ClusterIP
    port: 8200

  # Включить Vault Agent Injector (для sidecar-режима, опционально)
  agentInjector:
    enabled: false

ui:
  enabled: true
  serviceType: ClusterIP
```

### 3.2 Инициализация Vault (первый запуск)

Выполняется **один раз** после установки Vault. Не автоматизируется через helmfile — это ручной или CI-шаг.

```bash
# 1. Дождаться, пока Vault pod станет Ready
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=120s

# 2. Инициализация Vault (dev mode — пропускается)
# Для standalone/HA:
# kubectl exec -n vault vault-0 -- vault operator init \
#   -key-shares=5 \
#   -key-threshold=3 \
#   -format=json > vault-keys.json

# 3. Unseal Vault (dev mode — unseal автоматический)
# Для standalone/HA (3 из 5 ключей):
# for i in $(seq 3); do
#   kubectl exec -n vault vault-0 -- vault operator unseal \
#     $(jq -r ".unseal_keys_b64[$((i-1))]" vault-keys.json)
# done

# 4. Login
kubectl exec -n vault vault-0 -- vault login root  # dev mode: root токен

# 5. Включить KV Secrets Engine v2
kubectl exec -n vault vault-0 -- vault secrets enable -path=media-downloader kv-v2

# 6. Создать политику для чтения секретов
kubectl exec -n vault vault-0 -- sh -c '
cat <<EOF | vault policy write media-downloader-reader -
path "media-downloader/data/*" {
  capabilities = ["read", "list"]
}
EOF
'

# 7. Создать AppRole для External Secrets
kubectl exec -n vault vault-0 -- vault auth enable approle

kubectl exec -n vault vault-0 -- vault write auth/approle/role/media-downloader \
  token_policies="media-downloader-reader" \
  token_ttl=24h \
  token_max_ttl=72h

# 8. Получить RoleID и SecretID
ROLE_ID=$(kubectl exec -n vault vault-0 -- vault read -field=role_id auth/approle/role/media-downloader/role-id)
SECRET_ID=$(kubectl exec -n vault vault-0 -- vault write -f -field=secret_id auth/approle/role/media-downloader/secret-id)

echo "RoleID: $ROLE_ID"
echo "SecretID: $SECRET_ID"

# 9. Создать Kubernetes Secret для External Secrets (на время bootstrap)
kubectl create secret generic vault-approle -n external-secrets \
  --from-literal=roleId="$ROLE_ID" \
  --from-literal=secretId="$SECRET_ID" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3.3 Создание секретов в Vault

После инициализации Vault в него записываются все секреты, которые будут использоваться сервисами.

```bash
# Секреты PostgreSQL
kubectl exec -n vault vault-0 -- vault kv put media-downloader/postgresql \
  username=media_downloader \
  password="$(openssl rand -base64 32)" \
  database=media_downloader \
  replication_password="$(openssl rand -base64 32)"

# Секреты RabbitMQ
kubectl exec -n vault vault-0 -- vault kv put media-downloader/rabbitmq \
  username=media_downloader \
  password="$(openssl rand -base64 32)" \
  erlang_cookie="$(openssl rand -base64 32)"

# Секреты MinIO
kubectl exec -n vault vault-0 -- vault kv put media-downloader/minio \
  rootUser=admin \
  rootPassword="$(openssl rand -base64 32)"

# Секреты Redis
kubectl exec -n vault vault-0 -- vault kv put media-downloader/redis \
  password="$(openssl rand -base64 32)"

# Секреты приложений
kubectl exec -n vault vault-0 -- vault kv put media-downloader/bot-service \
  botToken="YOUR_TELEGRAM_BOT_TOKEN" \
  adminIds="123456789,987654321"

# Секреты для API (YouTube, TikTok)
kubectl exec -n vault vault-0 -- vault kv put media-downloader/api-keys \
  youtube="YOUR_YOUTUBE_API_KEY" \
  tiktok="YOUR_TIKTOK_API_KEY"

# Секреты для мониторинга
kubectl exec -n vault vault-0 -- vault kv put media-downloader/grafana \
  adminUser=admin \
  adminPassword="$(openssl rand -base64 32)"
```

### 3.4 Проверка секретов

```bash
kubectl exec -n vault vault-0 -- vault kv list media-downloader/
kubectl exec -n vault vault-0 -- vault kv get media-downloader/postgresql
```

---

## 4. External Secrets Operator

### 4.1 Установка через helmfile

```yaml
# infra-services/values/external-secrets.yaml
installCRDs: true

serviceAccount:
  create: true
  name: external-secrets

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

### 4.2 Создание SecretStore (подключение к Vault)

После установки External Secrets Operator нужно создать ресурсы `SecretStore` и `ExternalSecret`. Это можно сделать двумя способами:

**Способ A: через helmfile (extra-manifests в чарте)**

```yaml
# infra-services/values/external-secrets.yaml (дополнение)
extraObjects:
  - apiVersion: external-secrets.io/v1beta1
    kind: SecretStore
    metadata:
      name: vault-backend
      namespace: media-downloader
    spec:
      provider:
        vault:
          server: "http://vault.vault:8200"
          path: "media-downloader"
          version: "v2"
          auth:
            # Kubernetes auth (предпочтительный способ)
            kubernetes:
              mountPath: "kubernetes"
              role: "media-downloader"
              serviceAccountRef:
                name: external-secrets

  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: postgresql-credentials
      namespace: media-downloader
    spec:
      refreshInterval: "1h"
      secretStoreRef:
        name: vault-backend
        kind: SecretStore
      target:
        name: postgresql-credentials
        creationPolicy: Owner
      data:
        - secretKey: username
          remoteRef:
            key: postgresql
            property: username
        - secretKey: password
          remoteRef:
            key: postgresql
            property: password
        - secretKey: database
          remoteRef:
            key: postgresql
            property: database

  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: rabbitmq-credentials
      namespace: media-downloader
    spec:
      refreshInterval: "1h"
      secretStoreRef:
        name: vault-backend
        kind: SecretStore
      target:
        name: rabbitmq-credentials
        creationPolicy: Owner
      data:
        - secretKey: username
          remoteRef:
            key: rabbitmq
            property: username
        - secretKey: password
          remoteRef:
            key: rabbitmq
            property: password
        - secretKey: erlangCookie
          remoteRef:
            key: rabbitmq
            property: erlang_cookie

  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: minio-credentials
      namespace: media-downloader
    spec:
      refreshInterval: "1h"
      secretStoreRef:
        name: vault-backend
        kind: SecretStore
      target:
        name: minio-credentials
        creationPolicy: Owner
      data:
        - secretKey: rootUser
          remoteRef:
            key: minio
            property: rootUser
        - secretKey: rootPassword
          remoteRef:
            key: minio
            property: rootPassword

  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: redis-credentials
      namespace: media-downloader
    spec:
      refreshInterval: "1h"
      secretStoreRef:
        name: vault-backend
        kind: SecretStore
      target:
        name: redis-credentials
        creationPolicy: Owner
      data:
        - secretKey: password
          remoteRef:
            key: redis
            property: password

  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: bot-service-secrets
      namespace: media-downloader
    spec:
      refreshInterval: "1h"
      secretStoreRef:
        name: vault-backend
        kind: SecretStore
      target:
        name: bot-service-secrets
        creationPolicy: Owner
      data:
        - secretKey: botToken
          remoteRef:
            key: bot-service
            property: botToken
        - secretKey: adminIds
          remoteRef:
            key: bot-service
            property: adminIds

  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: api-keys
      namespace: media-downloader
    spec:
      refreshInterval: "1h"
      secretStoreRef:
        name: vault-backend
        kind: SecretStore
      target:
        name: api-keys
        creationPolicy: Owner
      data:
        - secretKey: youtube
          remoteRef:
            key: api-keys
            property: youtube
        - secretKey: tiktok
          remoteRef:
            key: api-keys
            property: tiktok

  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: grafana-credentials
      namespace: monitoring
    spec:
      refreshInterval: "1h"
      secretStoreRef:
        name: vault-backend
        kind: SecretStore
      target:
        name: grafana-credentials
        creationPolicy: Owner
      data:
        - secretKey: adminUser
          remoteRef:
            key: grafana
            property: adminUser
        - secretKey: adminPassword
          remoteRef:
            key: grafana
            property: adminPassword
```

**Способ B: отдельные YAML-файлы, накатываемые после helmfile**

```bash
# После установки external-secrets, накатить SecretStore и ExternalSecret
kubectl apply -f infra-services/manifests/secretstore.yaml
kubectl apply -f infra-services/manifests/external-secrets/
```

### 4.3 Проверка, что секреты созданы

```bash
# Дождаться синхронизации
kubectl get externalsecret -n media-downloader
kubectl get secret -n media-downloader | grep -E '(postgresql|rabbitmq|minio|redis|bot-service)'
```

### 4.4 Критически важное замечание: Kubernetes Auth в Vault

Для External Secrets Operator рекомендуется использовать **Kubernetes auth method** вместо AppRole. Это позволяет не создавать отдельный Kubernetes Secret для RoleID/SecretID.

```bash
# На стороне Vault: включить kubernetes auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/media-downloader \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=media-downloader \
  policies=media-downloader-reader \
  ttl=24h
```

---

## 5. Инфраструктурные сервисы (PostgreSQL, RabbitMQ, MinIO, Redis)

### 5.1 PostgreSQL (bitnami/postgresql)

```yaml
# infra-services/values/postgresql.yaml
global:
  postgresql:
    auth:
      existingSecret: postgresql-credentials
      secretKeys:
        userPasswordKey: password
        adminPasswordKey: password
        replicationPasswordKey: replication_password

architecture: replication  # standalone для dev, replication для prod

primary:
  persistence:
    enabled: true
    size: {{ .Values.postgresql.storageSize | default "10Gi" }}
    storageClass: {{ .Values.postgresql.storageClass | default "longhorn" }}
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
  initContainers:
    - name: wait-for-secret
      image: bitnami/kubectl:latest
      command:
        - sh
        - -c
        - |
          until kubectl get secret postgresql-credentials -n media-downloader; do
            echo "Waiting for postgresql-credentials secret..."
            sleep 5
          done
          echo "Secret found!"

readReplicas:
  replicaCount: 1
  persistence:
    enabled: true
    size: {{ .Values.postgresql.storageSize | default "10Gi" }}
    storageClass: {{ .Values.postgresql.storageClass | default "longhorn" }}

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

### 5.2 RabbitMQ (bitnami/rabbitmq)

```yaml
# infra-services/values/rabbitmq.yaml
auth:
  existingPasswordSecret: rabbitmq-credentials
  existingErlangSecret: rabbitmq-credentials
  secretKeys:
    passwordKey: password
    erlangCookieKey: erlangCookie

persistence:
  enabled: true
  size: {{ .Values.rabbitmq.storageSize | default "5Gi" }}
  storageClass: {{ .Values.rabbitmq.storageClass | default "longhorn" }}

replicaCount: 1  # 3 для prod

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi

extraPlugins: "rabbitmq_management"

service:
  type: ClusterIP
  ports:
    amqp: 5672
    manager: 15672

metrics:
  enabled: true
  serviceMonitor:
    enabled: true

extraContainer:
  - name: wait-for-secret
    image: bitnami/kubectl:latest
    command:
      - sh
      - -c
      - |
        until kubectl get secret rabbitmq-credentials -n media-downloader; do
          echo "Waiting for rabbitmq-credentials secret..."
          sleep 5
        done
        echo "Secret found!"

# Настройка очередей (через rabbitmq-definitions.json)
rabbitmq:
  extraConfiguration: |-
    load_definitions = /app/definitions.json

extraVolumes:
  - name: definitions
    configMap:
      name: rabbitmq-definitions

extraVolumeMounts:
  - name: definitions
    mountPath: /app/definitions.json
    subPath: definitions.json
```

**ConfigMap с определениями RabbitMQ:**

```yaml
# infra-services/manifests/rabbitmq-definitions.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rabbitmq-definitions
  namespace: media-downloader
data:
  definitions.json: |
    {
      "queues": [
        {"name": "downloads", "durable": true, "arguments": {}},
        {"name": "conversions", "durable": true, "arguments": {}},
        {"name": "notifications", "durable": true, "arguments": {}}
      ],
      "exchanges": [
        {"name": "media.direct", "type": "direct", "durable": true},
        {"name": "media.dlx", "type": "direct", "durable": true}
      ],
      "bindings": [
        {"source": "media.direct", "vhost": "/", "destination": "downloads", "destination_type": "queue", "routing_key": "download"},
        {"source": "media.direct", "vhost": "/", "destination": "conversions", "destination_type": "queue", "routing_key": "convert"},
        {"source": "media.direct", "vhost": "/", "destination": "notifications", "destination_type": "queue", "routing_key": "notify"}
      ]
    }
```

### 5.3 MinIO (minio/minio)

```yaml
# infra-services/values/minio.yaml
mode: standalone  # distributed для prod

rootUser: ""     # берётся из secret
rootPassword: "" # берётся из secret

existingSecret: minio-credentials

persistence:
  enabled: true
  size: {{ .Values.minio.storageSize | default "50Gi" }}
  storageClass: {{ .Values.minio.storageClass | default "longhorn" }}

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi

service:
  type: ClusterIP
  port: 9000
  consolePort: 9001

metrics:
  enabled: true
  serviceMonitor:
    enabled: true

buckets:
  - name: downloads
    policy: private
  - name: converted
    policy: private
  - name: thumbnails
    policy: private
```

> **Важно:** В чарте `minio/minio` нельзя передать `auth.rootUser` пустыми строками, если используется `existingSecret`. Нужно убедиться, что секрет `minio-credentials` содержит ключи `rootUser` и `rootPassword`. Если чарт требует значения, можно использовать `.Values.rootUser` и `.Values.rootPassword` из секрета через `extraEnvVarsSecret`.

### 5.4 Redis (bitnami/redis)

```yaml
# infra-services/values/redis.yaml
architecture: standalone  # replication для prod

auth:
  existingSecret: redis-credentials
  existingSecretPasswordKey: password

master:
  persistence:
    enabled: true
    size: {{ .Values.redis.storageSize | default "1Gi" }}
    storageClass: {{ .Values.redis.storageClass | default "longhorn" }}
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

---

## 6. Мониторинг и Observability

### 6.1 kube-prometheus-stack

```yaml
# infra-services/values/kube-prometheus-stack.yaml
alertmanager:
  enabled: true
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['namespace', 'severity']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'default'
      routes:
        - receiver: 'null'
          matchers:
            - severity =~ "info|none"
    receivers:
      - name: 'default'
        # Настройка уведомлений (email, slack, webhook)
      - name: 'null'

grafana:
  enabled: true
  admin:
    existingSecret: grafana-credentials
    userKey: adminUser
    passwordKey: adminPassword
  service:
    type: ClusterIP
  persistence:
    enabled: true
    size: 10Gi
    storageClass: longhorn
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://kube-prometheus-stack-prometheus.monitoring:9090
          access: proxy
          isDefault: true
        - name: Loki
          type: loki
          url: http://loki-stack.monitoring:3100
          access: proxy
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: default
          orgId: 1
          folder: ''
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/default
  dashboards:
    default:
      rabbitmq:
        url: https://raw.githubusercontent.com/grafana/grafana-dashboards/master/rabbitmq/rabbitmq.json
        datasource: Prometheus

prometheus:
  prometheusSpec:
    retention: 15d
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    resources:
      requests:
        cpu: 300m
        memory: 1Gi
      limits:
        cpu: 1000m
        memory: 2Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

kube-state-metrics:
  enabled: true
```

### 6.2 Loki + Promtail

```yaml
# infra-services/values/loki-stack.yaml
loki:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi
    storageClass: longhorn
  config:
    limits_config:
      retention_period: 168h  # 7 дней

promtail:
  enabled: true
  config:
    lokiAddress: http://loki-stack.monitoring:3100/loki/api/v1/push
```

---

## 7. Прикладные сервисы (собственные helm-чарты)

### 7.1 Структура собственного helm-чарта

```
services/
└── <service-name>/
    ├── Dockerfile
    ├── src/
    ├── helm/
    │   └── <service-name>/
    │       ├── Chart.yaml
    │       ├── values.yaml
    │       └── templates/
    │           ├── deployment.yaml
    │           ├── service.yaml
    │           ├── hpa.yaml
    │           ├── pdb.yaml
    │           ├── serviceaccount.yaml
    │           ├── configmap.yaml
    │           └── _helpers.tpl
    └── werf.yaml
```

### 7.2 Пример: Bot Service

**Chart.yaml:**
```yaml
apiVersion: v2
name: bot-service
description: Telegram Bot for Media Downloader
type: application
version: 0.1.0
appVersion: "1.0.0"
```

**values.yaml:**
```yaml
image:
  repository: ghcr.io/<your-org>/media-downloader/bot-service
  tag: latest
  pullPolicy: Always

replicaCount: 1

env:
  # Параметры БД
  dbHost: postgresql-primary.media-downloader.svc.cluster.local
  dbPort: 5432
  dbName: media_downloader
  # Параметры RabbitMQ
  rabbitmqHost: rabbitmq.media-downloader.svc.cluster.local
  rabbitmqPort: 5672
  # MinIO
  minioHost: minio.media-downloader.svc.cluster.local
  minioPort: 9000
  minioBucketDownloads: downloads
  minioBucketConverted: converted
  minioUseSSL: false

existingSecret: bot-service-secrets
secretKeys:
  botToken: botToken
  adminIds: adminIds

dbExistingSecret: postgresql-credentials
dbSecretKeys:
  username: username
  password: password

rabbitmqExistingSecret: rabbitmq-credentials
rabbitmqSecretKeys:
  username: username
  password: password

minioExistingSecret: minio-credentials
minioSecretKeys:
  username: rootUser
  password: rootPassword

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

service:
  type: ClusterIP
  port: 8080

hpa:
  enabled: false  # Bot Service не HPA, т.к. не HTTP

pdb:
  enabled: false
```

**templates/deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "bot-service.fullname" . }}
  labels:
    {{- include "bot-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "bot-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
      labels:
        {{- include "bot-service.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "bot-service.serviceAccountName" . }}
      initContainers:
        - name: wait-for-secrets
          image: bitnami/kubectl:latest
          command:
            - sh
            - -c
            - |
              for secret in {{ .Values.existingSecret }} {{ .Values.dbExistingSecret }} {{ .Values.rabbitmqExistingSecret }} {{ .Values.minioExistingSecret }}; do
                until kubectl get secret $secret -n {{ .Release.Namespace }}; do
                  echo "Waiting for $secret..."
                  sleep 5
                done
              done
              echo "All secrets found!"
        - name: wait-for-dependencies
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              for svc in postgresql-primary media-downloader rabbitmq media-downloader minio media-downloader; do
                until nslookup $svc; do
                  echo "Waiting for $svc..."
                  sleep 5
                done
              done
              echo "All services resolved!"
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          envFrom:
            - configMapRef:
                name: {{ include "bot-service.fullname" . }}-config
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.dbExistingSecret }}
                  key: {{ .Values.dbSecretKeys.password }}
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.dbExistingSecret }}
                  key: {{ .Values.dbSecretKeys.username }}
            - name: RABBITMQ_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.rabbitmqExistingSecret }}
                  key: {{ .Values.rabbitmqSecretKeys.password }}
            - name: RABBITMQ_USERNAME
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.rabbitmqExistingSecret }}
                  key: {{ .Values.rabbitmqSecretKeys.username }}
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.minioExistingSecret }}
                  key: {{ .Values.minioSecretKeys.username }}
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.minioExistingSecret }}
                  key: {{ .Values.minioSecretKeys.password }}
            - name: BOT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret }}
                  key: {{ .Values.secretKeys.botToken }}
            - name: ADMIN_IDS
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret }}
                  key: {{ .Values.secretKeys.adminIds }}
          ports:
            - containerPort: {{ .Values.service.port }}
              name: http
          livenessProbe:
            exec:
              command:
                - python
                - -c
                - "import requests; requests.get('http://localhost:{{ .Values.service.port }}/health')"
            initialDelaySeconds: 30
            periodSeconds: 15
          readinessProbe:
            exec:
              command:
                - python
                - -c
                - |
                  import os, psycopg2, pika
                  # Проверка подключения к БД
                  conn = psycopg2.connect(
                    host=os.environ['DB_HOST'],
                    port=os.environ['DB_PORT'],
                    dbname=os.environ['DB_NAME'],
                    user=os.environ['DB_USERNAME'],
                    password=os.environ['DB_PASSWORD']
                  )
                  conn.close()
                  # Проверка подключения к RabbitMQ
                  params = pika.URLParameters(
                    f"amqp://{os.environ['RABBITMQ_USERNAME']}:{os.environ['RABBITMQ_PASSWORD']}@{os.environ['RABBITMQ_HOST']}:{os.environ['RABBITMQ_PORT']}/%2F"
                  )
                  conn = pika.BlockingConnection(params)
                  conn.close()
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          securityContext:
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 1000
            capabilities:
              drop: ["ALL"]
      securityContext:
        fsGroup: 1000
```

### 7.3 Пример: Downloader Worker

```yaml
# services/downloader-worker/helm/values.yaml
image:
  repository: ghcr.io/<your-org>/media-downloader/downloader-worker
  tag: latest
  pullPolicy: Always

replicaCount: 1

env:
  rabbitmqHost: rabbitmq.media-downloader.svc.cluster.local
  rabbitmqPort: 5672
  rabbitmqQueueDownloads: downloads
  rabbitmqQueueConversions: conversions
  dbHost: postgresql-primary.media-downloader.svc.cluster.local
  dbPort: 5432
  dbName: media_downloader
  minioHost: minio.media-downloader.svc.cluster.local
  minioPort: 9000
  minioBucketDownloads: downloads
  minioUseSSL: false

existingSecret: bot-service-secrets
dbExistingSecret: postgresql-credentials
rabbitmqExistingSecret: rabbitmq-credentials
minioExistingSecret: minio-credentials

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi

hpa:
  enabled: true
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: rabbitmq_queue_depth
        target:
          type: AverageValue
          averageValue: 5

pdb:
  enabled: true
  minAvailable: 1
```

### 7.4 Как публиковать собственные чарты

```bash
# 1. Упаковать чарт
helm package services/bot-service/helm/bot-service/ -d charts/

# 2. Создать OCI-репозиторий (GitHub Container Registry)
helm push charts/bot-service-0.1.0.tgz oci://ghcr.io/<your-org>/helm-charts

# 3. Или добавить чарты в git-репозиторий и указать локальный путь
# infra-services/values/helmfile.yaml — использовать chart: ./charts/bot-service
```

---

## 8. Полный CI/CD пайплайн деплоя

### 8.1 GitHub Actions: сборка + публикация Docker-образа + деплой через helmfile

```yaml
# .github/workflows/deploy-bot.yml
name: Build & Deploy Bot Service

on:
  push:
    branches: [main]
    paths:
      - 'services/bot-service/**'
      - 'services/bot-service/werf.yaml'

env:
  WERF_REPO: ghcr.io/${{ github.repository_owner }}/media-downloader

jobs:
  build-and-publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup werf
        uses: werf/actions/install@v2

      - name: Login to Container Registry
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Build and Publish
        run: |
          werf build-and-publish \
            --context services/bot-service \
            --repo $WERF_REPO

  deploy:
    needs: build-and-publish
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup helmfile
        run: |
          curl -fsSL https://github.com/helmfile/helmfile/releases/download/v0.168.0/helmfile_0.168.0_linux_amd64.tar.gz | tar xz
          sudo mv helmfile /usr/local/bin/

      - name: Configure kubeconfig
        run: |
          mkdir -p ~/.kube/clusters
          echo "${{ secrets.KUBE_CONFIG }}" > ~/.kube/clusters/pet-project-cluster.yaml

      - name: Deploy via helmfile
        env:
          HELMFILE_ENV: dev
        run: |
          # Обновить image.tag в values
          sed -i "s/imageTag: latest/imageTag: ${{ github.sha }}/" infra-services/environments/dev.yaml

          # Запустить helmfile sync (только bot-service)
          ./infra-services/helmfile.sh --selector component=bot sync
```

### 8.2 Проблема: helmfile не умеет ждать ExternalSecret

helmfile `needs:` гарантирует, что release-зависимость установлена, но **не гарантирует**, что ExternalSecret уже создал Kubernetes Secret.

**Решение: initContainers в каждом сервисе**

```yaml
initContainers:
  - name: wait-for-secrets
    image: bitnami/kubectl:latest
    command:
      - sh
      - -c
      - |
        for secret in postgresql-credentials rabbitmq-credentials minio-credentials; do
          until kubectl get secret $secret -n media-downloader; do
            echo "Waiting for $secret..."
            sleep 5
          done
        done
        echo "All secrets found!"
```

Этот initContainer гарантирует, что pod не запустится, пока секреты не созданы.

### 8.3 Альтернатива: helmfile hooks + wait

```yaml
# В helmfile.yaml для postgresql
hooks:
  - events: ["presync"]
    command: "bash"
    args:
      - -c
      - |
        echo "Waiting for postgresql-credentials secret..."
        while ! kubectl get secret postgresql-credentials -n media-downloader 2>/dev/null; do
          sleep 5
        done
```

---

## 9. Пошаговая инструкция развёртывания (с нуля)

### 9.1 Этап 0: Подготовка

```bash
# Установить зависимости
sudo apt-get install -y curl git vagrant virtualbox

# Клонировать репозиторий
git clone <repo-url> ~/pet-media-downloader
cd ~/pet-media-downloader

# Установить Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Установить helmfile
curl -fsSL https://github.com/helmfile/helmfile/releases/download/v0.168.0/helmfile_0.168.0_linux_amd64.tar.gz | tar xz
sudo mv helmfile /usr/local/bin/

# Установить kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Установить werf
curl -sSL https://werf.io/install.sh | bash
```

### 9.2 Этап 1: Kubernetes кластер

```bash
# Поднять кластер через Vagrant + Ansible
cd kubernetes
vagrant up

# После успешного развёртывания:
export KUBECONFIG=~/.kube/clusters/pet-project-cluster.yaml
kubectl get nodes
kubectl get pods -A
```

### 9.3 Этап 2: Добавление Helm-репозиториев

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add external-secrets https://charts.external-secrets.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add minio https://charts.min.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### 9.4 Этап 3: Установка Vault

```bash
# Установка Vault
./infra-services/helmfile.sh --selector component=secrets sync

# Проверка
kubectl get pods -n vault

# Инициализация Vault (см. раздел 3.2)
# ... выполнить скрипт инициализации ...

# Создание секретов (см. раздел 3.3)
# ... выполнить скрипт наполнения секретами ...
```

### 9.5 Этап 4: Установка External Secrets Operator

```bash
# Установка External Secrets
./infra-services/helmfile.sh --selector component=secrets sync

# Проверка: создались ли SecretStore и ExternalSecret
kubectl get secretstore -A
kubectl get externalsecret -A

# Проверка: создались ли Kubernetes Secrets
kubectl get secret -n media-downloader
```

### 9.6 Этап 5: Установка инфраструктурных сервисов

```bash
# Установка всех инфраструктурных сервисов
./infra-services/helmfile.sh --selector stage=infrastructure sync

# Или по одному:
./infra-services/helmfile.sh --selector component=database sync
./infra-services/helmfile.sh --selector component=messaging sync
./infra-services/helmfile.sh --selector component=storage sync
./infra-services/helmfile.sh --selector component=cache sync

# Проверка
kubectl get pods -n media-downloader
kubectl get svc -n media-downloader
kubectl get pvc -n media-downloader
```

### 9.7 Этап 6: Установка мониторинга

```bash
# Установка Prometheus + Grafana + Loki
./infra-services/helmfile.sh --selector stage=monitoring sync

# Проверка
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

### 9.8 Этап 7: Сборка и публикация Docker-образов (через werf)

```bash
# Установить переменные
export WERF_REPO=ghcr.io/<your-org>/media-downloader

# Собрать все сервисы
for svc in bot-service downloader-worker converter-worker cleanup-cronjob; do
  werf build-and-publish \
    --context services/$svc \
    --repo $WERF_REPO \
    --tagging-strategy tag-by-git-branch
done

# Или через GitHub Actions (см. раздел 8.1)
```

### 9.9 Этап 8: Установка прикладных сервисов

```bash
# Установка прикладных сервисов
./infra-services/helmfile.sh --selector stage=application sync

# Проверка
kubectl get pods -n media-downloader
kubectl logs -n media-downloader -l app=bot-service
kubectl logs -n media-downloader -l app=downloader-worker
```

### 9.10 Финальная проверка

```bash
# Проверка всех pods
kubectl get pods -A | grep -v kube-system

# Проверка секретов
kubectl get secrets -n media-downloader

# Проверка логов External Secrets
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets

# Проверка статуса SecretStore
kubectl get secretstore vault-backend -n media-downloader -o yaml

# Проверка, что Vault доступен
kubectl exec -n vault vault-0 -- vault status

# Telegram Bot: отправить команду /start
# ...
```

---

## 10. Rollback и обновление секретов

### 10.1 Rollback сервиса

```bash
# Через helmfile
./infra-services/helmfile.sh --selector component=bot sync  # применит предыдущую версию из values
```

### 10.2 Обновление секретов в Vault

```bash
# Изменить секрет
kubectl exec -n vault vault-0 -- vault kv patch media-downloader/postgresql password=newpassword

# External Secrets Operator подхватит изменение в течение refreshInterval (1h по умолчанию)
# Или форсировать:
kubectl annotate externalsecret postgresql-credentials -n media-downloader \
  force-sync="true" --overwrite
```

### 10.3 Полный destroy

```bash
# Удалить всё (кроме Vault, чтобы не потерять секреты)
./infra-services/helmfile.sh --selector stage=application destroy
./infra-services/helmfile.sh --selector stage=infrastructure destroy
./infra-services/helmfile.sh --selector stage=monitoring destroy

# Для полной очистки:
./infra-services/helmfile.sh destroy
```

---

## 11. Чек-лист проверок перед релизом

- [ ] Vault инициализирован и unsealed
- [ ] SecretStore показывает `Ready: True`
- [ ] Все ExternalSecret ресурсы показывают `Ready: True`
- [ ] Все Kubernetes Secrets созданы в namespace `media-downloader`
- [ ] PostgreSQL pod Ready (initContainer дождался секрета)
- [ ] RabbitMQ pod Ready, очереди созданы
- [ ] MinIO pod Ready, buckets созданы
- [ ] Bot Service может подключиться к БД, RabbitMQ и MinIO
- [ ] Downloader Worker может скачать тестовое видео
- [ ] Converter Worker может сконвертировать тестовый файл
- [ ] Метрики в Prometheus поступают
- [ ] Логи в Loki
- [ ] Дашборды в Grafana отображают данные
- [ ] Network Policies не блокируют нужный трафик

---

## 12. Типовые проблемы и решения

### Проблема: ExternalSecret не может подключиться к Vault

**Причина:** Kubernetes Auth не настроен в Vault или service account не совпадает.

**Решение:**
```bash
# Проверить, что сервис-аккаунт совпадает
kubectl get sa -n media-downloader external-secrets

# Проверить конфигурацию Kubernetes Auth в Vault
kubectl exec -n vault vault-0 -- vault read auth/kubernetes/config

# Проверить роль
kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/media-downloader

# Пересоздать связку:
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/media-downloader \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=media-downloader \
  policies=media-downloader-reader \
  ttl=24h
```

### Проблема: PostgreSQL стартует раньше, чем создан секрет

**Причина:** helmfile `needs:` не гарантирует готовность ExternalSecret.

**Решение:** Добавить initContainer в развёртывание PostgreSQL или настроить helmfile hook (presync) для ожидания секрета. См. раздел 8.2.

### Проблема: werf build-and-publish собрал образ, но helmfile не может его найти

**Причина:** tag не совпадает между werf и helmfile.

**Решение:** Использовать единый идентификатор (git SHA) как tag, передаваемый из CI в helmfile values.

### Проблема: MinIO требует rootUser/rootPassword, но они пустые в values

**Причина:** Чарт `minio/minio` не поддерживает `existingSecret` для auth в старых версиях.

**Решение:** Использовать `bitnami/minio` вместо `minio/minio`, или передавать значения явно через секреты:

```yaml
# infra-services/values/minio.yaml
extraEnvVarsSecret:
  - minio-credentials
```
