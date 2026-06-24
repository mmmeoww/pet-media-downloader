# DevOps Pet Project: Media Downloader

## Описание

Pet-проект для демонстрации навыков DevOps: поднятие Kubernetes-кластера с нуля (Vagrant + Ansible), развёртывание микросервисного приложения для скачивания медиа из YouTube/TikTok/других платформ, организация полноценного CI/CD через werf и GitOps-подход.

---

## 1. Архитектура приложения

### Микросервисы

| Сервис | Назначение | Стек |
|---|---|---|
| **API Gateway** | Единая точка входа, rate limiting, маршрутизация | nginx / Kong |
| **Auth Service** | JWT-аутентификация, OAuth2, управление пользователями | Go / FastAPI |
| **Web App** | Основной фронтенд (ввод ссылки, просмотр статуса/истории) | React / Vue |
| **Downloader Worker** | Загрузка видео (тяжёлый CPU/traffic) | Python + yt-dlp |
| **Converter Worker** | Конвертация в формат/качество | Python + ffmpeg |
| **Notification Service** | WebSocket/SSE — уведомление о готовности | Node.js / Go |
| **Cleanup CronJob** | Удаление старых/просроченных файлов | Go / Python |

### Инфраструктурные сервисы

| Сервис | Назначение |
|---|---|
| **PostgreSQL** | Основная БД (пользователи, задачи, метаданные) |
| **Redis** | Кэш, Pub/Sub для уведомлений, Rate Limiter |
| **RabbitMQ** | Очередь задач (download → convert → notify) |
| **MinIO** | S3-совместимое объектное хранилище (видео, конвертированные файлы, QR-коды) |
| **Prometheus + Grafana** | Мониторинг, алерты, дашборды |
| **Loki + Promtail** | Агрегация логов |

### Схема трафика

```
User → Gateway API → API Gateway
                       ├→ Auth Service (JWT)
                       ├→ Web App (React SPA)
                       ├→ Downloader Worker (через RabbitMQ)
                       ├→ Converter Worker (через RabbitMQ)
                       └→ Notification Service (WebSocket)
```

### Data flow

1. Пользователь вводит ссылку → Web App.
2. Web App отправляет запрос → API Gateway → Auth (проверка JWT) → создаётся запись в таблице `tasks` в PostgreSQL → публикуется сообщение в RabbitMQ (`downloads`).
3. **Downloader Worker** забирает задачу из очереди, скачивает видео через yt-dlp, сохраняет файл в MinIO (bucket: `downloads/`), обновляет статус задачи в БД, публикует новую задачу в `conversions`.
4. **Converter Worker** забирает задачу, конвертирует (если нужно), сохраняет результат в MinIO (bucket: `converted/`), обновляет статус в БД, публикует в `notifications`.
5. **Notification Service** получает событие, отправляет WebSocket клиенту → пользователь видит «Готово» и presigned-ссылку на скачивание.
6. **Cleanup CronJob** раз в час удаляет файлы старше N дней из MinIO + чистит записи в БД.

**Какие файлы хранятся в MinIO:**

| Bucket | Содержимое | Пример |
|---|---|---|
| `downloads/` | Исходные скачанные видео | `user_42/abc123_original.mp4` |
| `converted/` | Сконвертированные файлы | `user_42/abc123_audio.mp3`, `user_42/abc123_720p.mp4` |
| `thumbnails/` | Превью/обложки | `user_42/abc123_thumb.jpg` |

**Альтернатива без MinIO (для упрощения):**
Воркер пишет напрямую на PVC (например, `hostPath` на выделенной worker-ноде), раздача через nginx sidecar. MinIO даёт presigned-ссылки и отделение storage от compute, но для пет-проекта можно начать с PVC и мигрировать на MinIO позже.

---

## 2. Инфраструктура (Vagrant + Ansible)

### Состав кластера

| Нода | Роль | Спецификация |
|---|---|---|
| `kube-control` | Control Plane | 2 CPU, 4 GB RAM |
| `kube-worker-1` | Worker | 2 CPU, 4 GB RAM |
| `kube-worker-2` | Worker | 2 CPU, 4 GB RAM |
| `kube-worker-3` | Worker | 2 CPU, 4 GB RAM (опционально, для HPA тестов) |

### Что накатывает Ansible

- containerd (CRI)
- kubeadm + kubelet + kubectl
- Инициализация control-plane
- Подключение worker-нод
- CNI: Calico (с Network Policies)
- Gateway API CRDs + controller (nginx / Cilium)
- Longhorn / Rook-Ceph (Persistent Storage, опционально)
- Node Feature Discovery (для тэгирования нод с GPU/большим диском)

### Gateway API

Вместо классического Ingress используется **Gateway API**:

```
Gateway (nginx) → HTTPRoute (auth.domain.com)       → Auth Service
                → HTTPRoute (api.domain.com/*)      → API Gateway
                → HTTPRoute (ws.domain.com/*)       → Notification Service (WebSocket)
                → HTTPRoute (domain.com/*)          → Web App
```

Политики: retry, timeout, mirror трафика для canary.

---

## 3. CI/CD (GitHub Actions + werf)

### Схема

```
Git push → GitHub
          ↓
GitHub Actions Runner (Ubuntu) | GitLab Runner (pod в кластере)
          ↓
werf build-and-publish → сборка Docker-образа + пуш в Container Registry
          ↓
werf converge → применяет изменения в кластер через ServiceAccount / kubeconfig
          ↓
GitOps: состояние в Git = состояние в кластере
```

### Принцип: независимый деплой каждого сервиса

```
.github/workflows/
├── deploy-auth.yml         # срабатывает только при изменениях в services/auth-service/
├── deploy-web.yml          # срабатывает только при изменениях в services/web-app/
├── deploy-downloader.yml   # срабатывает только при изменениях в services/downloader-worker/
├── deploy-converter.yml    # аналогично
├── deploy-notification.yml # аналогично
├── deploy-infra.yml        # Vagrant / Ansible / k8s инфраструктура
└── deploy-monitoring.yml   # Prometheus / Grafana / Loki
```

**Пример воркфлоу (`deploy-auth.yml`):**

```yaml
name: Deploy Auth Service
on:
  push:
    branches: [main]
    paths:
      - 'services/auth-service/**'
      - 'werf.yaml'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: werf/actions/build-and-publish@v2
        with:
          context: services/auth-service
      - uses: werf/actions/converge@v2
        with:
          env: dev
          kube-config-base64: ${{ secrets.KUBE_CONFIG }}
```

Или через **reusable workflow** при повторении паттерна:

```yaml
.github/workflows/
├── deploy-service.yml       # reusable (caller: service-name, context)
├── deploy-auth.yml          # просто вызывает reusable с параметрами
├── deploy-web.yml           # ...
└── deploy-infra.yml
```

### Пайплайн для каждого сервиса

| Стадия | Действие |
|---|---|
| `lint` | ruff / golangci-lint / eslint |
| `test` | unit-тесты |
| `build` | `werf build-and-publish` |
| `deploy-dev` | `werf converge` в namespace `dev` |
| `deploy-prod` | `werf converge` в namespace `prod` (с manual approval) |
| `cleanup` | `werf cleanup` — удаление старых образов |

### Компоненты CI/CD

- **GitHub Actions** / **GitLab Runner** (pod в кластере)
- **ServiceAccount** отдельный для каждого namespace (dev/prod) с RBAC-ограничениями
- **Werf**: сборка + деплой c Git-аннотациями
- **Path filter**: CI запускается только для изменённого сервиса

### Почему werf

- Один инструмент вместо Docker + Helm + ArgoCD
- Герметичные сборки (воспроизводимые)
- Автоматический diff и converge
- Встроенная очистка registry
- Не пересобирает сервисы, которые не менялись (по git diff)

---

## 4. Управление секретами

### Стратегия (без Vault)

**2 слоя хранения секретов:**

| Слой | Где хранится | Какие секреты | Шифрование |
|---|---|---|---|
| CI/CD (GitHub) | GitHub Actions Secrets | `KUBE_CONFIG`, `REGISTRY_PASSWORD`, `DOCKER_HUB_TOKEN` | Зашифровано GitHub (AES-256) |
| Кластер | Kubernetes Secrets (etcd) | JWT_SECRET, DB_PASSWORD, API_KEYS (YouTube, TikTok) | etcd encrypted at rest + RBAC |
| Git (werf) | `werf-secret.yaml` | Чувствительные файлы/строки в репозитории | age-шифрование (N曲線) |

**Схема доступа:**

```
Git push → GitHub Actions → KUBE_CONFIG (из Actions Secrets)
                           ↓
                  kubectl apply -f k8s/secrets.yaml
                           ↓
                  Pod → envFrom: secretRef (K8s Secret)
```

### Vault (опционально)

Добавляется как отдельный слой для демонстрации навыка работы с HashiCorp Vault:

| Возможность | Vault |
|---|---|
| Хранение статичных секретов | KV Secrets Engine (v2) |
| Динамическая генерация паролей БД | Database Secrets Engine |
| Подключение к подам | CSI-провайдер / Agent Sidecar Injector |
| Ротация | AppRole + TTL |
| Audit log | Включён (все операции логируются) |

**Когда Vault оправдан:**
- 10+ микросервисов с ротацией секретов
- Compliance (PCI DSS, SOC2)
- Dynamic secrets (генерация БД-логинов по запросу)

**Вердикт для пет-проекта:**
Базовая стратегия (K8s Secrets + werf-secret + Actions Secrets) покрывает 95% потребностей. Vault добавляется в отдельной ветке `feature/vault` как демонстрация технологии без усложнения основного проекта.

---

## 5. Мониторинг и Observability

| Компонент | Назначение |
|---|---|
| **kube-prometheus-stack** | Prometheus + Grafana + AlertManager |
| **Grafana Loki + Promtail** | Централизованный сбор логов |
| **Grafana Tempo** | Distributed tracing (опционально) |
| **Kube-state-metrics** | Метрики состояния k8s объектов |
| **Custom metrics** | RabbitMQ queue depth, download speed, error rate |

### Дашборды в Grafana

- Cluster overview (CPU/RAM/Pods/Nodes)
- RabbitMQ queues depth + consumer lag
- Downloader Worker: загрузка CPU, скорость скачивания, кол-во ошибок
- Application: RPS, latency (p50/p95/p99), error rate
- HPA: текущая/желаемая репликация

### Алерты (AlertManager)

- Download queue растёт → Worker не справляется → HPA или добавить worker
- Error rate > 5% → смотреть логи
- Disk usage > 80% → очистка или PV expansion
- Pod в CrashLoopBackOff > 5 мин

---

## 6. Kubernetes-специфика

### Манифесты

- **Deployments** с resource requests/limits
- **Services** (ClusterIP, где можно Headless для RabbitMQ/PostgreSQL)
- **ConfigMaps** для конфигов (nginx, werf, приложений)
- **Secrets** для паролей, JWT-ключей
- **PVC** для PostgreSQL, RabbitMQ, временных файлов воркеров
- **HPA** для Downloader Worker (по CPU + custom metric по длине очереди)
- **PodDisruptionBudget** для критичных сервисов
- **Network Policies** — запретить всё, кроме явно разрешённого
- **RBAC** — минимальные права для каждого ServiceAccount
- **CronJob** — cleanup старых файлов
- **Gateway API** ресурсы: Gateway, HTTPRoute, ReferenceGrant

### Init Containers

- Миграции БД перед стартом сервиса (alembic / goose)

### Graceful Shutdown

- Downloader Worker дожидается завершения текущего скачивания через preStop hook + SIGTERM

### Probe-ы

- Liveness — проверка, жив ли процесс
- Readiness — готов ли принимать трафик
- Startup — для долгой инициализации (Downloader Worker поднимает yt-dlp)

### Security Context

- readOnlyRootFilesystem
- runAsNonRoot
- capabilities: drop all, add only нужные (net_bind_service)

---

## 7. Структура репозитория

```
media-downloader/
├── .github/
│   └── workflows/
│       ├── deploy-service.yml      # reusable workflow
│       ├── deploy-auth.yml         # path: services/auth-service/**
│       ├── deploy-web.yml          # path: services/web-app/**
│       ├── deploy-downloader.yml   # path: services/downloader-worker/**
│       ├── deploy-converter.yml    # path: services/converter-worker/**
│       ├── deploy-notification.yml # path: services/notification-service/**
│       ├── deploy-infra.yml        # Vagrant / Ansible / k8s infrastructure
│       └── deploy-monitoring.yml   # Prometheus / Grafana / Loki
├── werf.yaml               # Werf конфиг (сборка всех образов)
├── werf-giterminism.yaml   # Настройки герметичности
├── werf-secret.yaml        # Зашифрованные секреты для werf
├── .env.example            # Шаблон локальных секретов (без значений)
├── vagrant/
│   ├── Vagrantfile
│   └── ansible/
│       ├── playbook.yml
│       ├── roles/
│       │   ├── containerd/
│       │   ├── kubernetes/
│       │   ├── calico/
│       │   ├── gateway-api/
│       │   └── vault/          # опционально
│       └── vars/
│           └── main.yml
├── services/
│   ├── api-gateway/        # nginx.conf + Dockerfile + Helm
│   ├── auth-service/
│   │   ├── src/
│   │   ├── Dockerfile
│   │   ├── helm/           # chart для каждого сервиса
│   │   └── werf.yaml
│   ├── web-app/
│   ├── downloader-worker/
│   ├── converter-worker/
│   ├── notification-service/
│   └── cleanup-cronjob/
├── k8s/
│   ├── gateway-api/        # Gateway + HTTPRoute
│   ├── monitoring/         # kube-prometheus-stack
│   ├── logging/            # Loki + Promtail
│   ├── infrastructure/     # PostgreSQL, Redis, RabbitMQ, MinIO
│   ├── secrets/            # K8s Secret манифесты (без значений)
│   ├── vault/              # опционально: Vault CRDs + CSI
│   ├── policies/           # Network Policies, RBAC, PDB
│   └── helm/
│       └── media-downloader/  # umbrella chart (опционально)
└── docs/
    ├── architecture.md
    ├── setup.md
    ├── secrets.md
    └── ci-cd.md
```

---

## 8. Структура werf.yaml (пример)

```yaml
configVersion: 1
project: media-downloader

---
image: auth-service
dockerfile: services/auth-service/Dockerfile
context: services/auth-service

---
image: web-app
dockerfile: services/web-app/Dockerfile
context: services/web-app

---
image: downloader-worker
dockerfile: services/downloader-worker/Dockerfile
context: services/downloader-worker

---
image: converter-worker
dockerfile: services/converter-worker/Dockerfile
context: services/converter-worker

---
image: notification-service
dockerfile: services/notification-service/Dockerfile
context: services/notification-service

---
image: cleanup-cronjob
dockerfile: services/cleanup-cronjob/Dockerfile
context: services/cleanup-cronjob
```

---

## 9. Development workflow

```bash
# Поднять кластер
cd vagrant && vagrant up

# Пролить инфраструктурные сервисы
werf converge --env infra

# Пролить приложение
werf converge --env dev

# Просмотр статуса
werf plan --env dev

# Логи
werf logs --env dev
```

---

## 10. Что даёт проект для резюме

- **Vagrant + Ansible**: IaC, provisioning bare-metal кластера
- **Kubernetes**: оркестрация, resource management, probes, graceful shutdown
- **GitOps**: werf, Git как source of truth, auto-converge
- **CI/CD**: независимый деплой по path filter, matrix build, werf build-and-publish + converge
- **Gateway API**: современная маршрутизация (HTTPRoute, retry, timeout, canary weight)
- **RabbitMQ**: очереди задач, ack/nack, retry с exponential backoff
- **Микросервисы**: декомпозиция, межсервисное взаимодействие, async processing
- **Object Storage (MinIO)**: S3-совместимое хранилище, presigned URLs, bucketing
- **Secrets Management**: K8s Secrets, age-шифрование (werf-secret), Actions Secrets, Vault (опционально)
- **Observability**: Prometheus, Grafana, Loki, AlertManager
- **Security**: RBAC, Network Policies, Security Context, readOnlyRootFilesystem
- **HPA + custom metrics**: автоскалинг воркеров по длине очереди RabbitMQ

---

## 11. Возможные расширения

- Vault: dynamic secrets, audit log, CSI-провайдер (ветка `feature/vault`)
- Kyverno / OPA: политики безопасности (validate/mutate images, labels)
- Cluster Autoscaler: Vagrant-провайдер динамически добавляет worker-ноды
- Canary deployments: Gateway API weight-based split для нового релиза
- Distributed tracing: Tempo / Jaeger + OpenTelemetry SDK в сервисах
- Load testing: k6 / Locust в CI, графики в Grafana
- Service Mesh: Istio / Linkerd для mTLS, traffic mirror, fault injection
- Мультирегион: развернуть зеркало кластера в Yandex Cloud / Selectel
- ArgoCD: как альтернатива werf для GitOps-подхода (сравнить опыт)
