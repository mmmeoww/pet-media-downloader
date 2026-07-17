# DevOps Infrastructure Project

Репозиторий — самостоятельный DevOps-проект для развёртывания локальной Kubernetes-платформы. В нём создаётся кластер и устанавливаются хранилища, брокер сообщений, управление секретами и наблюдаемость; прикладные сервисы в состав проекта не входят.

## Что разворачивается

```text
Vagrant + Ansible
        │
        └── Kubernetes 1.30 (control-plane + worker, Calico, local-path)
                │
                ├── Vault + External Secrets Operator
                ├── PostgreSQL, RabbitMQ, MinIO, Redis
                └── Prometheus Operator, Prometheus, Grafana,
                    kube-state-metrics и node-exporter
```

Все сервисы данных доступны только внутри кластера через `ClusterIP`. Для локального доступа используйте port-forward.

## Состав репозитория

| Каталог | Содержимое |
| --- | --- |
| `kubernetes/` | Vagrant-конфигурация и Ansible-роли для двухузлового кластера. |
| `infrastructure/` | Helmfile, values, локальные Helm-чарты и патчи сервисов. |
| `infrastructure/vault-bootstrap/` | Инициализация Vault, загрузка секретов и создание токена для ESO. |
| `docs/` | Проектные заметки и исходное описание MVP. |

## Требования

- macOS на ARM64 с Vagrant и провайдером `vagrant-qemu`;
- Ansible;
- `kubectl`, Helm и Helmfile;
- `jq` и `openssl` для bootstrap-скриптов Vault.

Vagrantfile рассчитан на две VM по 2 vCPU и 3 ГиБ RAM: `control_plane` и `worker01`. Запускайте их последовательно — сетевой сокет QEMU должен сначала создать control-plane.

## Быстрый старт

### 1. Создать Kubernetes-кластер

```bash
cd kubernetes
vagrant up --no-parallel
ansible-playbook -i ansible/inventory.ini ansible/playbook.yaml
```

Playbook устанавливает containerd, Kubernetes, Calico и `local-path` StorageClass. После выполнения kubeconfig будет сохранён по адресу `~/.kube/clusters/pet-project-cluster.yaml`.

Проверьте кластер:

```bash
kubectl get nodes --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get storageclass --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
```

### 2. Подготовить секреты Vault

Создайте `infrastructure/vault-bootstrap/secrets.json`. Файл игнорируется Git. Пустые значения скрипт заменит случайными значениями; для логинов и паролей, которые должны быть известны пользователю, укажите значения явно.

```json
{
  "postgres": {
    "POSTGRES_HOST": "postgresql-postgresql.infra.svc.cluster.local",
    "POSTGRES_PORT": "5432",
    "POSTGRES_DB": "application",
    "POSTGRES_USER": "postgres",
    "POSTGRES_PASSWORD": ""
  },
  "rabbitmq": {
    "RABBITMQ_HOST": "rabbitmq-rabbitmq.infra.svc.cluster.local",
    "RABBITMQ_PORT": "5672",
    "RABBITMQ_USER": "rabbitmq_user",
    "RABBITMQ_PASSWORD": "",
    "ERLANG_COOKIE": ""
  },
  "redis": {
    "REDIS_HOST": "redis-client.infra.svc.cluster.local",
    "REDIS_PORT": "6379",
    "REDIS_USER": "default",
    "REDIS_PASSWORD": ""
  },
  "minio": {
    "MINIO_ROOT_USER": "admin",
    "MINIO_ROOT_PASSWORD": ""
  },
  "grafana": {
    "GRAFANA_ADMIN_USER": "admin",
    "GRAFANA_ADMIN_PASSWORD": ""
  }
}
```

Не добавляйте `secrets.json` или созданный при инициализации `init.json` в Git и не выводите их содержимое в терминал или логи CI.

### 3. Развернуть платформу

Выполняйте стадии строго по порядку. Обёртка `helmfile.sh` сама устанавливает `KUBECONFIG` на kubeconfig кластера.

```bash
cd infrastructure

./helmfile.sh sync --selector stage=vault

cd vault-bootstrap
./vault-unseal.sh
./vault-put.sh
cd ..

./helmfile.sh sync --selector stage=secrets
./helmfile.sh sync --selector stage=observability
./helmfile.sh sync --selector stage=infrastructure
```

Если webhook External Secrets ещё не готов, повторите команду для `stage=secrets`. Стадия `observability` должна быть завершена до `stage=infrastructure`: сервисы данных создают `ServiceMonitor`, для которых нужны CRD Prometheus Operator.

## Стадии Helmfile

| Стадия | Релизы |
| --- | --- |
| `vault` | Vault и External Secrets Operator. |
| `secrets` | `ClusterSecretStore` и ExternalSecret-ресурсы для сервисов данных. |
| `observability` | секрет Grafana, CRD и Prometheus Operator, Prometheus, exporters, Grafana. |
| `infrastructure` | PostgreSQL, RabbitMQ, MinIO и Redis. |

Версии чартов, образы, ресурсы, PVC и список Grafana-дашбордов находятся в [infrastructure/environments/default.yaml](infrastructure/environments/default.yaml). Единственная Helmfile-среда — `default`.

## Проверка после установки

```bash
kubectl get pods -n vault --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get pods -n infra --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get pods -n observability --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get externalsecret.external-secrets.io -A --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get servicemonitor -A --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get prometheus -n observability --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
```

## Локальный доступ

Откройте нужный сервис отдельной командой port-forward:

```bash
kubectl port-forward -n observability svc/grafana 3000:80 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n observability svc/prometheus 9090:9090 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml

kubectl port-forward -n infra svc/postgresql-postgresql 15432:5432 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/rabbitmq-rabbitmq 5672:5672 15672:15672 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/redis-client 6379:6379 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/minio 9000:9000 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/minio-console 9001:9001 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
```

Grafana доступна на `http://127.0.0.1:3000`, Prometheus — на `http://127.0.0.1:9090`, MinIO Console — на `http://127.0.0.1:9001`. Учётные данные Grafana берутся из пути `grafana` в Vault. Для PostgreSQL используйте SSL-режим `disable`:

```bash
psql "host=127.0.0.1 port=15432 user=postgres dbname=application sslmode=disable"
```

## Особенности конфигурации

- Постоянные данные хранятся в PVC на `local-path`: Vault 2 ГиБ, PostgreSQL 10 ГиБ, RabbitMQ 5 ГиБ, MinIO 15 ГиБ, Redis 1 ГиБ, Prometheus 10 ГиБ и Grafana 5 ГиБ.
- PostgreSQL, RabbitMQ, Redis и MinIO получают только необходимые ключи через External Secrets из KV v2-монта Vault `infrastructure`.
- RabbitMQ инициализирует очереди и обменники из ConfigMap, входящего в Helm-чарт.
- Prometheus выбирает все `ServiceMonitor` в кластере. Grafana получает datasource Prometheus и заранее закреплённые версии дашбордов из `default.yaml`.
- Stateful-нагрузки запускаются с настроенными security context и точечными init-контейнерами для прав на локальных PVC. Не заменяйте это массовым `chmod 777`.

## Полезные команды

Просмотреть итоговый рендер без применения:

```bash
cd infrastructure
./helmfile.sh template
```

Проверить базы PostgreSQL:

```bash
kubectl exec -n infra postgresql-postgresql-0 \
  --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"'
```

При работе с селектором Helmfile команда `status` может сообщить о зависимости за пределами выбранной стадии. Это ограничение селектора; для предусмотренного поэтапного развёртывания используйте `sync`.
