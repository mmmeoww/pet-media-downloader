# AGENTS.md - instructions for AI agents

## Project and paths

`pet-media-downloader` has two infrastructure layers:

- `kubernetes/ansible/` provisions the Vagrant Kubernetes cluster and its
  `local-path` StorageClass.
- `infrastructure/` deploys platform services with Helmfile.

Always use this kubeconfig:

```bash
~/.kube/clusters/pet-project-cluster.yaml
```

For Helmfile, use the wrapper because it sets `KUBECONFIG` itself:

```bash
cd infrastructure
./helmfile.sh <command>
```

The only Helmfile environment is `default`. Chart versions, images,
persistence settings, resources, and Grafana dashboard definitions are in
`infrastructure/environments/default.yaml`. Environment-dependent values and
patches use the `.gotmpl` extension.

## Helmfile stages

`infrastructure/helmfile.yaml.gotmpl` uses these stages:

- `stage=vault`: Vault and External Secrets Operator.
- `stage=secrets`: `vault-secret-store` and `infra-secrets` charts.
- `stage=observability`: observability secrets, Prometheus Operator CRDs,
  local Prometheus Operator and Prometheus charts, kube-state-metrics,
  node-exporter, and Grafana.
- `stage=infrastructure`: PostgreSQL, RabbitMQ, MinIO, and Redis.

Deploy stages explicitly in this order:

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

If the External Secrets webhook is not ready immediately after installation,
repeat the `stage=secrets` sync. Do not deploy `stage=infrastructure` before
observability: its charts now create `ServiceMonitor` resources and therefore
need the Prometheus Operator CRDs installed.

When using a selector, Helmfile `status` may complain about a `needs` release
outside the selector. This is a selector limitation, not necessarily a failed
release. Use `sync` for the documented staged rollout.

## Vault and external secrets

- Vault chart: `hashicorp/vault` `0.28.1`, standalone mode in namespace
  `vault`.
- Vault storage: `2Gi`, `local-path`; service is `vault.vault:8200`.
- KV v2 mount: `infrastructure`.
- `ClusterSecretStore/vault-backend` authenticates with the `vault-token`
  Secret in namespace `vault`.
- ESO policy `external-secrets-read` has only `read`/`list` access to the
  `infrastructure` mount and `auth/token/lookup-self`.

Vault bootstrap scripts are in `infrastructure/vault-bootstrap/`:

- `vault-unseal.sh`: initializes and unseals through the Vault HTTP API.
- `vault-put.sh`: enables the KV mount, uploads `secrets.json`, creates the
  ESO policy/token, and updates the Kubernetes `vault-token` Secret.

Without an explicit `VAULT_ADDR`, the scripts use `kubectl port-forward` to
`svc/vault` at `127.0.0.1:18200`. Do not suggest `kubectl exec` for routine
Vault operations. `init.json` and `secrets.json` are sensitive: never print or
commit their values.

Vault paths under `infrastructure`:

- `postgres`: `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`,
  `POSTGRES_USER`, `POSTGRES_PASSWORD`.
- `rabbitmq`: `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USER`,
  `RABBITMQ_PASSWORD`, `ERLANG_COOKIE`.
- `redis`: `REDIS_HOST`, `REDIS_PORT`, `REDIS_USER`, `REDIS_PASSWORD`.
- `minio`: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`.

`infra-secrets` maps only chart-required fields into Kubernetes Secrets:

- `postgresql-credentials`: `POSTGRES_PASSWORD`.
- `rabbitmq-credentials`: `RABBITMQ_USER`, `RABBITMQ_PASSWORD`,
  `ERLANG_COOKIE`.
- `redis-credentials`: `REDIS_PASSWORD`.
- `minio-credentials`: `rootUser`, `rootPassword`, mapped from the two MinIO
  Vault fields.

## Observability

Do not add `kube-prometheus-stack` back. Observability is intentionally split
into releases:

- `prometheus-community/prometheus-operator-crds` owns the Operator CRDs.
- `charts/prometheus-operator` runs the Operator and its RBAC.
- `charts/prometheus-instance` creates the `Prometheus` custom resource,
  service account, discovery RBAC, service, and self `ServiceMonitor`.
- Upstream charts run kube-state-metrics, node-exporter, and Grafana.

Prometheus selects all `ServiceMonitor`, `PodMonitor`, and `PrometheusRule`
resources in all namespaces with empty selectors (`{}`). A monitor does not
need `release: prometheus`.

There are two separate label selections:

1. Prometheus selects `ServiceMonitor` objects. In this project all are
   selected because its selector is empty.
2. Each `ServiceMonitor.spec.selector.matchLabels` selects the target
   `Service`. Those labels must be present on that Service.

A `ServiceMonitor` does not automatically scrape every Service in the cluster.
It only makes its matching Service endpoints scrapeable.

The data-service charts enable both metrics/exporters and their
`ServiceMonitor` resources:

- PostgreSQL: `postgres_exporter` and `pg_up`.
- RabbitMQ: built-in Prometheus plugin.
- Redis: `redis_exporter` and `redis_up`.
- MinIO: node metrics at `/minio/v2/metrics/node` via `ServiceMonitor`.

Prometheus uses PVC storage and runs as non-root `1000:2000`. Its local chart
has a narrowly privileged `volume-permissions` init-container which chowns
only `/prometheus` before the main container starts. Keep the main container
non-root; do not solve the PVC issue by running Prometheus as root.

Grafana:

- Uses `grafana-admin-credentials` (`admin-user`, `admin-password`) from
  `observability-secrets`.
- Has the `Prometheus` datasource at
  `http://prometheus.observability.svc.cluster.local:9090`.
- Provisioned Grafana.com dashboards are declared as a list under
  `dashboards` in `environments/default.yaml`. Each item has `key`, `gnetId`,
  `revision`, and `datasource`; the template ranges over this list. Add a new
  dashboard only in the environment file and pin its revision.
- Dashboard provider `folder: ""` keeps dashboards at Grafana's root. The
  provider filesystem path remains `/var/lib/grafana/dashboards/default`.
- `patches/grafana-volume-permissions.yaml.gotmpl` replaces the upstream
  recursive Grafana `chown` with a non-recursive ownership change of the data
  root. Do not revert it to `chown -R`: Grafana-created `csv`, `png`, and
  `pdf` directories made the upstream init-container fail on restart.

Useful checks:

```bash
kubectl get pods -n observability --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get servicemonitor -A --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl get prometheus -n observability --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n observability svc/prometheus 9090:9090 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
```

## Data services

All data services are in namespace `infra`, use `ClusterIP`, and have no
direct external exposure.

### PostgreSQL

- Chart `helmforge/postgresql` `2.0.4`; image `postgres:16`.
- Database `application`, user `postgres`, password from
  `postgresql-credentials/POSTGRES_PASSWORD`.
- Persistence `10Gi` on `local-path`.
- Main container is non-root UID/GID `999`; do not enable
  `allowPrivilegeEscalation`.
- `patches/postgresql-volume-permissions.yaml.gotmpl` prepares the PVC.

### RabbitMQ

- Chart `helmforge/rabbitmq` `1.6.1`; image `rabbitmq:4.3.2-alpine`.
- Credentials come from `rabbitmq-credentials`.
- Queue, exchange, and binding definitions are an in-chart ConfigMap created
  by `values/data-services/rabbitmq.yaml.gotmpl` and loaded from
  `/app/definitions.json`.
- Do not move RabbitMQ definitions into External Secrets.

### MinIO

- Chart `minio/minio` `5.2.0`, standalone mode.
- Existing Secret `minio-credentials`; persistence `15Gi`.
- The chart hook job creates buckets. `minio-post-job` with `Completed` status
  is normal.
- `patches/minio-volume-permissions.yaml.gotmpl` prepares its PVC.

### Redis

- Chart `helmforge/redis` `1.6.19`; image `redis:7-alpine`.
- Auth uses `redis-credentials/REDIS_PASSWORD`; persistence `1Gi`.

## Local storage

The Vagrant cluster provisions `local-path` through
`kubernetes/ansible/roles/storage-provisioner`. Its helper setup script creates
new volume directories as `root:root` with mode `0750`. This is why non-root
stateful workloads may require a scoped permission init-container.

Do not broadly change volumes to `0777` for production-style configuration.
Prefer this order:

1. Run the application non-root and set its `fsGroup`.
2. Use `fsGroupChangePolicy: OnRootMismatch` when the storage driver supports
   it.
3. Use a minimal root init-container for only the application PVC when needed.

Changing the local-path provisioner affects only future PVCs; existing PVCs
retain their current ownership and mode. A CSI driver can be introduced in the
Ansible storage role later, but validate its `CSIDriver.fsGroupPolicy` before
removing application-level permission handling.

## External access and checks

Use port-forward for local access:

```bash
kubectl port-forward -n infra svc/postgresql-postgresql 15432:5432 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/rabbitmq-rabbitmq 5672:5672 15672:15672 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/redis-client 6379:6379 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/minio 9000:9000 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
kubectl port-forward -n infra svc/minio-console 9001:9001 --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml
```

For PostgreSQL from the local machine, use a separate port and disable SSL:

```bash
psql "host=127.0.0.1 port=15432 user=postgres dbname=application sslmode=disable"
```

Basic checks:

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
