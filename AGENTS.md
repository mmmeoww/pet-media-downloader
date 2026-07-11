# AGENTS.md - инструкции для AI агентов

## Проект

`pet-media-downloader`.

Инфраструктурная раскатка находится в `infra-services/` и управляется `helmfile`.

## KUBECONFIG

Всегда используй:

```bash
~/.kube/clusters/pet-project-cluster.yaml
```

Для helmfile предпочитай wrapper:

```bash
cd infra-services
./helmfile.sh <command>
```

`helmfile.sh` сам выставляет нужный `KUBECONFIG`.

## Helmfile Stages

В `infra-services/helmfile.yaml.gotmpl` используются stages:

- `stage=vault` - Vault и External Secrets Operator.
- `stage=secrets` - charts `./charts/vault-secret-store` и `./charts/infra-secrets`: общий `ClusterSecretStore` и infrastructure `ExternalSecret` ресурсы.
- `stage=observability` - charts `./charts/observability-secrets` и `kube-prometheus-stack`.
- `stage=infrastructure` - PostgreSQL, RabbitMQ, MinIO, Redis.

У infrastructure-релизов есть `needs` на `infra/infra-secrets`, но при ручной раскатке все равно применяй stages явно и по порядку.

Единственное Helmfile environment называется `default` и автоматически используется wrapper-скриптом. Версии chart, образы, параметры persistence и resources находятся в `infra-services/environments/default.yaml`. Values и patches, использующие эти параметры, имеют расширение `.gotmpl`.

## Порядок Развертывания

```bash
cd infra-services
./helmfile.sh sync --selector stage=vault
cd vault-bootstrap
./vault-unseal.sh
./vault-put.sh
cd ..
./helmfile.sh sync --selector stage=secrets
./helmfile.sh sync --selector stage=observability
./helmfile.sh sync --selector stage=infrastructure
```

Если External Secrets webhook еще не готов сразу после установки оператора, повтори sync для `stage=secrets`.

## Vault

- Chart: `hashicorp/vault` `0.28.1`.
- Namespace: `vault`.
- Mode: standalone, не dev.
- Storage: PVC `10Gi`, `storageClass: local-path`.
- Service: `ClusterIP`, `vault.vault:8200`.
- Vault KV v2 mount: `infrastructure`.
- External Secrets читает Vault через `ClusterSecretStore/vault-backend`.
- Auth для ESO: Kubernetes Secret `vault-token` в namespace `vault`.
- Policy для ESO: `external-secrets-read`, read/list только для mount `infrastructure` и `auth/token/lookup-self`.

Скрипты Vault лежат в `infra-services/vault-bootstrap/`:

- `vault-unseal.sh` - init/unseal через Vault HTTP API.
- `vault-put.sh` - включает KV mount, пишет данные из `secrets.json`, создает policy/token и обновляет Kubernetes Secret `vault-token`.

Скрипты общаются с Vault через `kubectl port-forward` к `svc/vault` на `127.0.0.1:18200`, если `VAULT_ADDR` не задан. Не возвращай `kubectl exec` для обычных операций с Vault.

`init.json` и `secrets.json` содержат чувствительные данные. Не выводи их значения в ответах и не коммить содержимое секретов.

## Vault Secrets Shape

Vault paths относительно mount `infrastructure`:

- `postgres`
- `rabbitmq`
- `redis`
- `minio`

Ожидаемые поля:

- PostgreSQL: `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`.
- RabbitMQ: `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD`, `ERLANG_COOKIE`.
- Redis: `REDIS_HOST`, `REDIS_PORT`, `REDIS_USER`, `REDIS_PASSWORD`.
- MinIO: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`.

ExternalSecrets сейчас передают в Kubernetes Secrets только поля, нужные chart values:

- `postgresql-credentials`: `POSTGRES_PASSWORD`.
- `rabbitmq-credentials`: `RABBITMQ_USER`, `RABBITMQ_PASSWORD`, `ERLANG_COOKIE`.
- `redis-credentials`: `REDIS_PASSWORD`.
- `minio-credentials`: `rootUser`, `rootPassword`, маппятся из Vault `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, потому что chart MinIO ожидает именно такие ключи.

## Infrastructure Charts

### PostgreSQL

- Chart: `helmforge/postgresql` `2.0.4`.
- Image: `docker.io/library/postgres:16`.
- Namespace: `infra`.
- Database: `application`.
- User: `postgres`.
- Password: из Secret `postgresql-credentials`, key `POSTGRES_PASSWORD`.
- Persistence: `8Gi`.
- Main container запускается non-root: UID/GID `999`, `allowPrivilegeEscalation: false`, capabilities dropped.
- Для прав на PVC используется `strategicMergePatches`:
  `infra-services/patches/postgresql-volume-permissions.yaml.gotmpl`.

Не включай `allowPrivilegeEscalation: true` для PostgreSQL main container.

### RabbitMQ

- Chart: `helmforge/rabbitmq` `1.6.1`.
- Image: `docker.io/library/rabbitmq:4.3.2-alpine`.
- Namespace: `infra`.
- Auth берется из Secret `rabbitmq-credentials`.
- Definitions создаются внутри RabbitMQ release через `values/rabbitmq.yaml.gotmpl`:
  `extraManifests`, `extraVolumes`, `extraVolumeMounts`, `config.extra`.
- ConfigMap: `rabbitmq-definitions`.
- Definitions загружаются из `/app/definitions.json`.

Не выноси RabbitMQ queues/exchanges/bindings в External Secrets.

### MinIO

- Chart: `minio/minio` `5.2.0`.
- Namespace: `infra`.
- Standalone mode.
- Existing Secret: `minio-credentials`.
- Buckets создаются chart hook job из `values/minio.yaml.gotmpl`.
- `minio-post-job` со статусом `Completed` - нормальное состояние hook job.

### Redis

- Chart: `helmforge/redis` `1.6.19`.
- Image: `docker.io/library/redis:7-alpine`.
- Namespace: `infra`.
- Auth включен, password из Secret `redis-credentials`, key `REDIS_PASSWORD`.

## Доступ Снаружи

Сервисы infrastructure сейчас `ClusterIP`; прямого внешнего доступа нет.

Для локальной разработки используй `kubectl port-forward`, например:

```bash
kubectl port-forward -n infra svc/postgresql-postgresql 15432:5432 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/rabbitmq-rabbitmq 5672:5672 15672:15672 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/redis-client 6379:6379 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/minio 9000:9000 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/minio-console 9001:9001 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
```

Для PostgreSQL с локальной машины лучше использовать отдельный порт и отключать SSL:

```bash
psql "host=127.0.0.1 port=15432 user=postgres dbname=application sslmode=disable"
```

## Проверки

Базовые команды:

```bash
kubectl get pods -n vault --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get pods -n infra --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get externalsecret.external-secrets.io -n infra --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get clustersecretstore.external-secrets.io --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
```

PostgreSQL database check:

```bash
kubectl exec -n infra postgresql-postgresql-0 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"'
```
