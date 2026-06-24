# DevOps Pet Project: Media Downloader — MVP (Telegram Bot)

## Идея

Начать с **Telegram-бота** как единственного пользовательского интерфейса, полностью убрав Web App, API Gateway, Auth Service, Notification Service и Gateway API. Это позволяет сфокусироваться на core-логике (скачивание + конвертация + DevOps-инфра) и получить работающий продукт за минимальное время.

Бот остаётся параллельным каналом при апгрейде до Full Stack — пользователь может как зайти на сайт, так и кинуть ссылку в Telegram.

---

## Архитектура MVP

```
Telegram → Telegram Bot API → Bot Service
                                ├── PostgreSQL (задачи, users)
                                ├── RabbitMQ (downloads)
                                ├── Downloader Worker
                                ├── Converter Worker
                                └── RabbitMQ (notifications) → Bot Service → Telegram
```

### Микросервисы

| Сервис | Назначение | Стек |
|---|---|---|
| **Bot Service** | Принимает ссылки, шлёт файлы/статус | Python (aiogram) |
| **Downloader Worker** | Скачивание видео | Python + yt-dlp |
| **Converter Worker** | Конвертация (mp3, качество) | Python + ffmpeg |
| **Cleanup CronJob** | Удаление старых файлов | Go / Python |

### Инфраструктура

| Сервис | Назначение |
|---|---|
| **PostgreSQL** | Пользователи (telegram_id), задачи, metadata |
| **RabbitMQ** | Очереди: `downloads` → `conversions` → `notifications` |
| **MinIO** (или PVC) | Хранение скачанных/сконвертированных файлов |
| **Prometheus + Grafana** | Мониторинг |

### Что отвалилось (сознательно)

| Компонент | Почему не нужен в MVP |
|---|---|
| **Web App (React/Vue)** | Весь UI — в Telegram |
| **API Gateway** | Bot Service ходит напрямую в сервисы |
| **Auth Service** | Аутентификация = telegram_id + secret chat |
| **Notification Service** | Bot API сам шлёт сообщения |
| **Gateway API / HTTPRoute** | Нет внешнего HTTP-трафика |
| **Redis** | Нет WebSocket / rate limit пока не критично |

---

## Data Flow

1. User → Telegram → команда `/download <url>` → Bot Service
2. Bot Service создаёт запись в `users` (если новый), запись в `tasks`, публикует в `downloads`
3. **Downloader Worker** → скачивает → сохраняет в MinIO → публикует в `conversions`
4. **Converter Worker** → конвертирует → сохраняет в MinIO → публикует в `notifications`
5. Bot Service получает уведомление → шлёт пользователю файл (или presigned-ссылку, если >50MB)
6. **Cleanup CronJob** → раз в N часов чистит старые файлы и записи

---

## Раздача файлов

| Размер | Способ |
|---|---|
| ≤ 2 GB | Прямая отправка через Bot API (`sendDocument`) |
| > 2 GB | Presigned-ссылка из MinIO |

---

## Инфраструктура (Vagrant + Ansible)

### Состав кластера

| Нода | Роль | Спецификация |
|---|---|---|
| `kube-control` | Control Plane | 2 CPU, 4 GB RAM |
| `kube-worker-1` | Worker | 2 CPU, 4 GB RAM |
| `kube-worker-2` | Worker | 2 CPU, 4 GB RAM |

### Что накатывает Ansible

- containerd (CRI)
- kubeadm + kubelet + kubectl
- Инициализация control-plane
- Подключение worker-нод
- CNI: Calico (с Network Policies)
- Longhorn / Rook-Ceph (Persistent Storage, опционально)
- Node Feature Discovery (для тэгирования нод с GPU/большим диском)

### Сеть

Внешний HTTP-трафик не требуется. Сервисы общаются через ClusterIP внутри кластера. Bot Service инициирует outbound-соединения к Telegram Bot API.

### CI/CD Runner

| Вариант | Плюсы | Минусы |
|---|---|---|
| **GitHub-hosted runner** | Не нужно поддерживать, бесплатно 2000 мин/мес | Нужен external kubeconfig, кластер должен быть доступен извне |
| **Self-hosted runner в кластере** (рекомендуется) | Не нужен внешний kubeconfig, полный контроль, навык для резюме | Надо обновлять runner, потребляет ресурсы кластера |

**Выбор для MVP:** self-hosted runner подом в кластере (через [actions-runner-controller](https://github.com/actions/actions-runner-controller) или Helm). Развёртывается через тот же werf, секреты — через K8s Secrets (GITHUB_TOKEN, REPO_ACCESS).

---

## CI/CD (GitHub Actions + werf)

### Схема

```
Git push → GitHub → GitHub Actions Runner
                    ↓
          werf build-and-publish → Docker Registry
                    ↓
          werf converge → k8s кластер
```

### Воркфлоу (MVP)

```
.github/workflows/
├── deploy-bot.yml          # path: services/bot-service/**
├── deploy-downloader.yml   # path: services/downloader-worker/**
├── deploy-converter.yml    # path: services/converter-worker/**
├── deploy-infra.yml        # Vagrant / Ansible / k8s infrastructure
└── deploy-monitoring.yml   # Prometheus / Grafana / Loki
```

### Пример (deploy-bot.yml)

```yaml
name: Deploy Bot Service
on:
  push:
    branches: [main]
    paths:
      - 'services/bot-service/**'
      - 'werf.yaml'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: werf/actions/build-and-publish@v2
        with:
          context: services/bot-service
      - uses: werf/actions/converge@v2
        with:
          env: dev
          kube-config-base64: ${{ secrets.KUBE_CONFIG }}
```

---

## Управление секретами

| Слой | Секреты |
|---|---|
| GitHub Actions Secrets | `KUBE_CONFIG`, `REGISTRY_PASSWORD`, `BOT_TOKEN` |
| K8s Secrets | `BOT_TOKEN`, `DB_PASSWORD`, `API_KEYS` (YouTube, TikTok) |
| werf-secret.yaml | age-шифрование для чувствительных строк в репозитории |

---

## Мониторинг

| Компонент | Назначение |
|---|---|
| **kube-prometheus-stack** | Prometheus + Grafana + AlertManager |
| **Grafana Loki + Promtail** | Логи |
| **Custom metrics** | RabbitMQ queue depth, download speed, error rate |

### Алерты

- Download queue растёт → Worker не справляется → HPA
- Error rate > 5%
- Bot Service не отвечает (нет сообщений > 5 мин)

---

## Kubernetes-специфика

- **Deployments** с resource requests/limits
- **Services** (ClusterIP)
- **Secrets** для BOT_TOKEN, DB_PASSWORD
- **PVC** для PostgreSQL, временных файлов воркеров
- **HPA** для Downloader Worker (CPU + длина очереди)
- **Network Policies** — всё запрещено, кроме явных разрешений
- **RBAC** — минимальные права
- **CronJob** — cleanup старых файлов
- **Init Containers** — миграции БД (alembic)
- **Graceful Shutdown** — preStop + SIGTERM для воркеров
- **Probes** — liveness, readiness, startup
- **Security Context** — readOnlyRootFilesystem, runAsNonRoot, drop all capabilities

---

## Структура репозитория

```
media-downloader/
├── .github/
│   └── workflows/
│       ├── deploy-bot.yml
│       ├── deploy-downloader.yml
│       ├── deploy-converter.yml
│       ├── deploy-infra.yml
│       └── deploy-monitoring.yml
├── werf.yaml
├── werf-giterminism.yaml
├── werf-secret.yaml
├── .env.example
├── vagrant/
│   ├── Vagrantfile
│   └── ansible/
│       ├── playbook.yml
│       ├── roles/
│       │   ├── containerd/
│       │   ├── kubernetes/
│       │   └── calico/
│       └── vars/
│           └── main.yml
├── services/
│   ├── bot-service/
│   │   ├── src/
│   │   ├── Dockerfile
│   │   └── helm/
│   ├── downloader-worker/
│   ├── converter-worker/
│   └── cleanup-cronjob/
├── k8s/
│   ├── monitoring/
│   ├── logging/
│   ├── infrastructure/   # PostgreSQL, RabbitMQ, MinIO
│   ├── secrets/
│   ├── policies/          # Network Policies, RBAC, PDB
│   └── ci/                # actions-runner-controller (опционально)
└── docs/
    ├── setup.md
    └── architecture.md
```

---

## werf.yaml

```yaml
configVersion: 1
project: media-downloader

---
image: bot-service
dockerfile: services/bot-service/Dockerfile
context: services/bot-service

---
image: downloader-worker
dockerfile: services/downloader-worker/Dockerfile
context: services/downloader-worker

---
image: converter-worker
dockerfile: services/converter-worker/Dockerfile
context: services/converter-worker

---
image: cleanup-cronjob
dockerfile: services/cleanup-cronjob/Dockerfile
context: services/cleanup-cronjob
```

---

## Development workflow

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

## Путь апгрейда → Full Stack

```
MVP (бот) → Bot Service остаётся как доп. канал → добавляется:
                               ├── Auth Service (та же БД, telegram_id → JWT)
                               ├── API Gateway
                               ├── Web App (React/Vue)
                               ├── Notification Service (SSE/WebSocket)
                               └── Gateway API
```

---

## Что даёт проект для резюме

- **Vagrant + Ansible**: IaC, provisioning bare-metal кластера
- **Kubernetes**: оркестрация, resource management, probes, graceful shutdown
- **GitOps**: werf, Git как source of truth, auto-converge
- **CI/CD**: независимый деплой по path filter, werf build-and-publish + converge
- **RabbitMQ**: очереди задач, ack/nack, retry с exponential backoff
- **Микросервисы**: декомпозиция, межсервисное взаимодействие, async processing
- **Object Storage (MinIO)**: S3-совместимое хранилище, presigned URLs
- **Telegram Bot API**: интеграция с внешними API, long polling / webhook
- **Secrets Management**: K8s Secrets, age-шифрование, Actions Secrets
- **Observability**: Prometheus, Grafana, Loki, AlertManager
- **Security**: RBAC, Network Policies, Security Context
- **HPA + custom metrics**: автоскалинг воркеров по длине очереди RabbitMQ
