# Infra Services: Deploy via Helmfile

## Цель

Развернуть инфраструктурные сервисы (PostgreSQL, Redis, RabbitMQ, MinIO) и Vault для управления секретами в Kubernetes-кластере через Helmfile, чтобы подготовить платформу для микросервисов приложения.

---

## 1. Структура директории `infra-services/`

```
infra-services/
├── helmfile.sh                 # Обёртка для запуска helmfile с нужным kubeconfig
├── helmfile.yaml               # Главный helmfile — описывает все releases
├── helmfile.lock               # Лок зависимостей (генерируется)
├── values/                     # Переопределения значений для каждого чарта
│   ├── postgresql.yaml
│   ├── redis.yaml
│   ├── rabbitmq.yaml
│   ├── minio.yaml
│   ├── vault.yaml
│   └── external-secrets.yaml
└── bootstrap/
    └── vault-init.sh           # Однократный скрипт: инициализация Vault + запись секретов
```

### Назначение файлов

| Файл | Роль |
|---|---|
| `helmfile.yaml` | Декларация всех Helm-релизов: какой чарт, namespace, version, values |
| `helmfile.sh` | Простая обёртка — передаёт `--kubeconfig ~/.kube/clusters/pet-project-cluster.yaml` |
| `values/*.yaml` | Переопределения дефолтов чарта (storage, ресурсы, пароли, настройки) |

Почему **не** `helmfile.d/` и **не** gotmpl-шаблоны: договорились держать минималистичную конфигурацию — один `helmfile.yaml` вместо разбивки по файлам.

---

## 2. Выбор Helm-чартов

Вместо operator-ов (CRDs, лишняя сложность для пет-проекта) используем **битнамовские** чарты — стабильные, настраиваемые, стандартные:

| Сервис | Чарт | Репозиторий | Минимальная версия |
|---|---|---|---|
| PostgreSQL | `bitnami/postgresql` | `https://charts.bitnami.com/bitnami` | 15.x |
| Redis | `bitnami/redis` | `https://charts.bitnami.com/bitnami` | 7.x |
| RabbitMQ | `bitnami/rabbitmq` | `https://charts.bitnami.com/bitnami` | 3.13.x |
| MinIO | `bitnami/minio` | `https://charts.bitnami.com/bitnami` | 2024.x |

### Почему Bitnami, а не:
- **CloudNativePG (Postgres)**: оператор, CRD, требует `kubectl apply` перед helm install — лишнее телодвижение. Для продакшена он лучше (бэкапы, PITR), для пет-проекта Bitnami проще.
- **RabbitMQ Cluster Operator**: аналогично — оператор, CRD, сложнее. Bitnami даёт standalone или clustered без оператора.
- **Redis Operator**: избыточен для одного инстанса.

Если в будущем понадобится HA — Bitnami-чарты умеют кластеризацию через `replication.enabled=true`.

---

## 3. Пространство имён

Все инфра-сервисы деплоим в namespace `infra`:

```bash
kubectl create namespace infra
```

Это отделяет системные сервисы от будущих микросервисов приложения (`default` или `apps`).

---

## 4. Storage

В кластере уже работает `local-path-provisioner` (Kind-овский дефолт). Он автоматически создаёт PVC на ноде. Для пет-проекта этого достаточно.

Для каждого сервиса потребуется PVC:

| Сервис | Размер PVC | Назначение |
|---|---|---|---|
| PostgreSQL | 8 Gi | Данные БД |
| Redis | 1 Gi | RDB/AOF снимки |
| RabbitMQ | 1 Gi | Очереди (если нужно > memory limit) |
| MinIO | 10 Gi | S3-совместимое объектное хранилище (видео, конвертированные файлы, QR-коды) |

---

## 5. Состав `helmfile.yaml` — построчно

### Repositories

```yaml
repositories:
  - name: bitnami
    url: https://charts.bitnami.com/bitnami
```

Блок `repositories` добавляет Helm-репозиторий. Это аналог `helm repo add bitnami ...`. Helmfile выполнит `helm repo update` перед install/upgrade.

### Releases

```yaml
releases:
  - name: postgresql
    namespace: infra
    chart: bitnami/postgresql
    version: 15.5.38
    values:
      - values/postgresql.yaml
    installed: true
```

Что здесь важно:
- **`name`** — имя Helm-релиза. В кластере появится deployment `postgresql-postgresql` (префикс имени релиза).
- **`namespace`** — куда деплоить.
- **`chart`** — откуда брать чарт (`bitnami/postgresql` — `<repository>/<chart-name>`).
- **`version`** — фиксированная версия (semver). Без неё при каждом `helmfile apply` будет тянуться latest — риск неожиданных изменений.
- **`values`** — переопределения. Можно указать несколько файлов, они мержатся.
- **`installed: true`** — гарантирует, что релиз существует. Если удалить руками — пересоздаст.

### missingFileHandler

```yaml
missingFileHandler: Error
```

Защита от опечаток в путях values-файлов. Если файл не найден — ошибка, а не silent ignore.

---

## 6. Values-файлы

### 6.1 `values/postgresql.yaml`

Основные переопределения:

```yaml
# Отключаем реплики (для пет-проекта достаточно одного инстанса)
architecture: standalone

# auth
auth:
  postgresPassword: "changeme"        # пароль для суперюзера postgres
  database: mediadownloader            # БД будет создана при инициализации
  username: appuser                    # пользователь приложения
  password: "changemeapp"              # его пароль

# primary ресурсы
primary:
  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "500m"
  persistence:
    size: 8Gi
    storageClass: local-path
    accessModes:
      - ReadWriteOnce

# Инициализационный SQL (если нужно)
initdbScripts:
  create-extensions.sql: |
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

**Важные моменты:**
- `auth.database` — база создаётся автоматически при первом старте. Не нужно ручного `CREATE DATABASE`.
- `initdbScripts` — выполняются при инициализации. Например, `uuid-ossp` для генерации UUID в Go/Python.
- `persistence.storageClass: local-path` — чтобы PVC создавался с local-path-provisioner.
- Пароли **надо будет сменить** и передавать через `--values` с секретами или в будущем через External Secrets / SOPS.

### 6.2 `values/redis.yaml`

```yaml
# standalone mode (без реплик)
architecture: standalone
master:
  count: 1
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "200m"
  persistence:
    size: 1Gi
    storageClass: local-path

auth:
  enabled: true
  password: "redispass"

# Отключаем ACL (совместимость со старыми клиентами)
usePasswordFile: false
```

### 6.4 `values/minio.yaml`

```yaml
# Режим standalone (1 pod) — без распределённого MinIO
mode: standalone

# root credentials
auth:
  rootUser: minio
  rootPassword: "miniosecret"

# Ресурсы
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"

# Персистентность
persistence:
  size: 10Gi
  storageClass: local-path

# Заранее создаём bucket'ы, которые нужны приложению
defaultBuckets: "downloads,converted,thumbnails"

# Включаем MinIO Console (UI)
apiIngress:
  enabled: false    # TODO: включить через Ingress позже

consoleIngress:
  enabled: false

# Service — ClusterIP для доступа из приложения
service:
  type: ClusterIP
```

**Что важно:**
- `mode: standalone` — один StatefulSet с одним pod. Для HA нужно `mode: distributed` (минимум 4 PVC).
- `defaultBuckets` — bucket'ы создаются автоматически при первом старте. Микросервисы сразу смогут писать в `downloads/`, `converted/`, `thumbnails/`.
- `auth.rootUser/rootPassword` — от них будут accessKey/secretKey для S3-клиентов.
- MinIO это **StatefulSet** — стабильный DNS нужен для S3-signature и distributed-режима в будущем.

```yaml
# standalone (single node)
replicaCount: 1

# Учётка по умолчанию
auth:
  username: admin
  password: "rabbitpass"
  erlangCookie: "supersecret-erlang-cookie"

resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"

persistence:
  enabled: true
  size: 1Gi
  storageClass: local-path
  accessModes:
    - ReadWriteOnce

# Включаем Management UI (доступен через NodePort или Ingress)
managementPlugin:
  enabled: true

# Дополнительные очереди и exchanges можно определить через
# extraPlugins, extraConfig
extraConfig: |
  vm_memory_high_watermark.relative = 0.8
```

---

## 7. Пошаговый план деплоя

### Шаг 1. Создать namespace

```bash
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -
```

### Шаг 2. Создать values-файлы

Создать `infra-services/values/postgresql.yaml`, `values/redis.yaml`, `values/rabbitmq.yaml`, `values/minio.yaml` с содержимым выше.

### Шаг 3. Написать `helmfile.yaml`

Поставить `helmfile` в `infra-services/` (содержимое выше).

### Шаг 4. Проверить синтаксис

```bash
./helmfile.sh lint
```

### Шаг 5. Развернуть сервисы

```bash
./helmfile.sh apply
```

Эта команда:
1. Добавит Bitnami repo если нет
2. Обновит кэш репозитория
3. Проверит diff между текущим состоянием и желаемым
4. Запросит подтверждение (можно отключить флагом `--auto-approve`)
5. Выполнит `helm upgrade --install` для каждого релиза

### Шаг 6. Проверить статус

```bash
kubectl get pods -n infra
helmfile status
```

---

## 8. Проверка работоспособности

### PostgreSQL

```bash
kubectl run psql-test --rm -it --restart=Never \
  --image bitnami/postgresql:15 \
  --namespace infra \
  -- psql -h postgresql.infra -U appuser -d mediadownloader -c '\l'
```

Пароль: `changemeapp`.

### Redis

```bash
kubectl run redis-test --rm -it --restart=Never \
  --image bitnami/redis:7 \
  --namespace infra \
  -- redis-cli -h redis-master.infra -a redispass ping
```

### RabbitMQ

```bash
kubectl run rabbit-test --rm -it --restart=Never \
  --image bitnami/rabbitmq:3.13 \
  --namespace infra \
  -- rabbitmqadmin -H rabbitmq.infra -u admin -p rabbitpass list queues
```

Management UI:

```bash
kubectl port-forward -n infra svc/rabbitmq 15672:15672
```

Открыть `http://localhost:15672`.

### MinIO

```bash
# Проверка S3-доступа через aws-cli
kubectl run minio-test --rm -it --restart=Never \
  --image bitnami/minio-client:2024 \
  --namespace infra \
  -- mc alias set myminio http://minio.infra:9000 minio miniosecret && \
     mc ls myminio/
```

Console UI:

```bash
kubectl port-forward -n infra svc/minio 9001:9001
```

Открыть `http://localhost:9001` (логин: `minio`, пароль: `miniosecret`).

Внутри будут три bucket: `downloads/`, `converted/`, `thumbnails/` — созданы автоматически через `defaultBuckets`.

---

## 9. Vault + External Secrets Operator

### 9.1 Зачем Vault

Пароли от Postgres, Redis, RabbitMQ, MinIO сейчас хардкодом в values-файлах. Для пет-проекта это ок на старте, но при добавлении микросервисов понадобятся:

- JWT secret для Auth Service
- OAuth клиентские ID/секреты (Google, TikTok API)
- API ключи для YouTube/TikTok
- Сертификаты для Ingress

Vault — центральное хранилище secrets + policy + audit. Внешние приложения не хранят секреты в коде и не знают, где они лежат.

### 9.2 Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│                     Vault (bitnami/vault)                    │
│  standalone, file backend, unseal вручную для dev            │
│  secret/infra/postgresql, secret/infra/redis, ...            │
│  secret/app/jwt, secret/app/oauth-google, ...                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│              External Secrets Operator                       │
│  читает из Vault, создаёт/обновляет K8s Secret              │
│  CRD: ExternalSecret → SecretStore → Vault                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│              K8s Secret (namespace: infra / default)          │
│  postgresql-creds, redis-creds, rabbitmq-creds,              │
│  minio-creds, jwt-secret, oauth-google                       │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│              Pod (приложение / инфра-сервис)                  │
│  envFrom / volumeMount — стандартный K8s Secret             │
│  код НЕ меняется, Vault прозрачен                           │
└─────────────────────────────────────────────────────────────┘
```

### 9.3 Что добавляем в helmfile

```yaml
releases:
  # ... postgresql, redis, rabbitmq, minio ...

  - name: vault
    namespace: infra
    chart: bitnami/vault
    version: 1.18.x
    values:
      - values/vault.yaml
    installed: true

  - name: external-secrets
    namespace: infra
    chart: external-secrets/external-secrets
    version: 0.14.x
    values:
      - values/external-secrets.yaml
    installed: true
    needs:
      - vault                    # дожидается vault перед установкой
```

### 9.4 `values/vault.yaml`

```yaml
# standalone: один pod без HA (Consul не нужен)
server:
  standalone:
    enabled: true
    config: |
      ui = true
      listener "tcp" {
        address     = "0.0.0.0:8200"
        tls_disable = true
      }
      storage "file" {
        path = "/vault/data"
      }
      api_addr = "http://vault.infra:8200"

  # Ресурсы
  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "500m"

  # PVC для data
  dataStorage:
    enabled: true
    size: 1Gi
    storageClass: local-path

  # Отключаем HA-специфичные компоненты
  ha:
    enabled: false

# Включаем Vault UI (доступен через port-forward)
ui:
  enabled: true
  serviceType: ClusterIP
```

**Важно:** `tls_disable = true` только для dev/пет-проекта. В production — сертификаты.

### 9.5 `values/external-secrets.yaml`

```yaml
# Меньше ресурсов — оператор лёгкий
resources:
  requests:
    memory: "64Mi"
    cpu: "50m"
  limits:
    memory: "128Mi"
    cpu: "100m"

# Один инстанс, HA не нужен
replicas: 1

# Отключаем ненужные провайдеры (оставляем только vault, если есть)
# По умолчанию все включены — это ок для пет-проекта
```

### 9.6 Процесс инициализации Vault

Vault после установки запечатан (sealed). Нужно:

1. **Инициализация** — `vault operator init` → получаем 5 ключей unseal + root token
2. **Распечатывание** — `vault operator unseal` (3 из 5 ключей)
3. **Логин** — `vault login <root-token>`
4. **Включение KV-движка** — `vault secrets enable -path=secret kv-v2`
5. **Запись секретов** — `vault kv put secret/infra/postgresql password=...`
6. **Создание policy + токена для External Secrets**

Для пет-проекта всё это делается однократным скриптом:

```bash
# bootstrap/vault-init.sh — запускается один раз после helmfile apply

set -euo pipefail

VAULT_POD=$(kubectl get pod -n infra -l app.kubernetes.io/name=vault -o name | head -1)

# 1. Инициализация (если ещё не инициализирован)
INIT_STATUS=$(kubectl exec -n infra "$VAULT_POD" -- vault status --format=json 2>/dev/null || echo '{"initialized":false}')
if echo "$INIT_STATUS" | grep -q '"initialized": false'; then
  echo "→ Initializing Vault..."
  kubectl exec -n infra "$VAULT_POD" -- vault operator init \
    -key-shares=5 -key-threshold=3 \
    -format=json > .vault-keys.json

  UNSEAL_KEYS=$(cat .vault-keys.json | jq -r '.unseal_keys_b64[]' | head -3)
  ROOT_TOKEN=$(cat .vault-keys.json | jq -r '.root_token')

  echo "→ Unsealing Vault..."
  for key in $UNSEAL_KEYS; do
    kubectl exec -n infra "$VAULT_POD" -- vault operator unseal "$key"
  done

  # 2. Логин + настройка
  kubectl exec -n infra "$VAULT_POD" -- vault login "$ROOT_TOKEN"
  kubectl exec -n infra "$VAULT_POD" -- vault secrets enable -path=secret kv-v2

  # 3. Запись секретов инфра-сервисов
  kubectl exec -n infra "$VAULT_POD" -- \
    vault kv put secret/infra/postgresql password="$(openssl rand -base64 32)"
  kubectl exec -n infra "$VAULT_POD" -- \
    vault kv put secret/infra/redis password="$(openssl rand -base64 32)"
  kubectl exec -n infra "$VAULT_POD" -- \
    vault kv put secret/infra/rabbitmq password="$(openssl rand -base64 32)"
  kubectl exec -n infra "$VAULT_POD" -- \
    vault kv put secret/infra/minio rootPassword="$(openssl rand -base64 32)"

  # 4. Policy + token для External Secrets
  kubectl exec -n infra "$VAULT_POD" -- sh -c "
    cat <<'POL' | vault policy write external-secrets -
path \"secret/data/infra/*\" {
  capabilities = [\"read\"]
}
path \"secret/data/app/*\" {
  capabilities = [\"read\"]
}
POL"

  ES_TOKEN=$(kubectl exec -n infra "$VAULT_POD" -- \
    vault token create -policy=external-secrets -format=json \
    | jq -r '.auth.client_token')

  # 5. Создаём K8s Secret с токеном для External Secrets
  kubectl create secret generic vault-token \
    -n infra \
    --from-literal=token="$ES_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "✓ Vault initialized and secrets written"
  echo "⚠ Root token: $ROOT_TOKEN — сохрани в .vault-keys.json"
else
  echo "Vault already initialized, skipping bootstrap"
fi
```

### 9.7 `SecretStore` и `ExternalSecret` CRD

После инициализации Vault создаём ресурсы для синхронизации:

**SecretStore** — указывает, как подключаться к Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: infra
spec:
  provider:
    vault:
      server: "http://vault.infra:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token        # K8s Secret с токеном (создан в скрипте)
          key: token
```

**ExternalSecret** для postgres:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgresql-creds
  namespace: infra
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: postgresql-creds
  data:
    - secretKey: password
      remoteRef:
        key: infra/postgresql
        property: password
```

### 9.8 Подключение к Bitnami-чартам через `existingSecret`

После того как ExternalSecret создаст K8s Secret `postgresql-creds`, обновляем values:

```yaml
# values/postgresql.yaml
auth:
  existingSecret: postgresql-creds   # вместо postgresPassword / password
```

```yaml
# values/redis.yaml
auth:
  existingSecret: redis-creds
  existingSecretPasswordKey: password
```

```yaml
# values/rabbitmq.yaml
auth:
  existingSecret: rabbitmq-creds
  existingSecretPasswordKey: password
```

```yaml
# values/minio.yaml
auth:
  existingSecret: minio-creds
```

### 9.9 Итоговый порядок деплоя

```
1. helmfile apply                     # ставит всё: postgres, redis, ..., vault, external-secrets
2. ./bootstrap/vault-init.sh          # инициализация Vault + запись секретов + создание vault-token
3. kubectl apply -f secretstore.yaml  # SecretStore → infra/vault-backend
4. kubectl apply -f external-secrets/ # ExternalSecret → создаёт postgresql-creds, redis-creds, ...
5. helmfile apply                     # перекатывает postgres/redis/... с existingSecret (читает созданные K8s Secret)
```

**Начиная со второго запуска:** шаги 2-4 не нужны (vault уже инициализирован, ExternalSecret уже синхронизирует). Только `helmfile apply`.

### 9.10 Vault UI

```bash
kubectl port-forward -n infra svc/vault 8200:8200
```

Открыть `http://localhost:8200`, войти с root-токеном (лежит в `.vault-keys.json` после `vault-init.sh`).

---

## 10. Что дальше (следующие шаги)

После развёртывания инфра-сервисов:

1. **Ingress Controller** — установить nginx-ingress или traefik для доступа к сервисам приложения снаружи.
2. **Cert-manager** — Let's Encrypt сертификаты для ingress.
3. **Мониторинг** — Prometheus + Grafana (kube-prometheus-stack).
4. **Логи** — Loki + Promtail.
5. **GitOps** — перенести helmfile в GitLab CI / ArgoCD.

---

## 11. Шпаргалка по Helmfile

```bash
# Показать что будет сделано (dry-run)
./helmfile.sh diff

# Применить
./helmfile.sh apply

# Удалить всё
./helmfile.sh destroy

# Список релизов
./helmfile.sh list

# Статус релизов
./helmfile.sh status

# Добавить/обновить репозитории
./helmfile.sh repos

# Линтер
./helmfile.sh lint
```
