# Приватный ComfyUI-под на RunPod

Шаблон RunPod Pod с ComfyUI, собранный под требование: минимум записи на диск,
никаких метаданных в выводе, единственный открытый порт — SSH по ключу.
Образ собирается и публикуется в GHCR через GitHub Actions.

## Модель угроз: что достижимо, а что нет

| Угроза | Статус |
|---|---|
| Посторонний в интернете находит ваш ComfyUI | Закрыто: ComfyUI слушает `127.0.0.1`, HTTP-порты не проброшены, доступ только через SSH-туннель |
| Подбор пароля по SSH | Закрыто: `AuthenticationMethods publickey`, пароли выключены |
| Промпты и воркфлоу утекают в логи RunPod | Закрыто: вывод ComfyUI уходит в файл в RAM, а не в stdout контейнера |
| Промпты и воркфлоу вшиты в сохранённые картинки | Закрыто: `--disable-metadata` |
| Фронтенд и ноды ходят наружу | Закрыто: `--disable-api-nodes`, `--disable-all-custom-nodes`, телеметрия HF выключена |
| Результаты и входные файлы остаются на диске | Ослаблено: они лежат в `/dev/shm` (RAM); на диск попадают только веса моделей |
| Данные переживают под | Закрыто: Volume disk = 0 ГБ, container disk стирается при остановке |
| **Оператор хоста читает контейнер или VRAM** | **Не закрыто** |

Последняя строка — принципиальная. Защита от подглядывания со стороны хостера у RunPod
**договорная**: их ToS запрещает хостам инспектировать данные пода, но технических гарантий
(confidential computing, TEE-аттестация GPU) RunPod не предоставляет. Ничто внутри контейнера
это не меняет. Secure Cloud даёт лучший ЦОД и стабильный IP, но не делает провайдера слепым.

Отдельно: удаление контейнера не равно криптографическому стиранию. Container disk
освобождается, но гарантии перезаписи блоков нет.

## Почему не готовый образ

`runpod/worker-comfyui` — образ для Serverless, а не для Pod. Популярные Pod-образы с ComfyUI
тянут Jupyter, web-терминал `ttyd` и ComfyUI-Manager, пишут всё в stdout и открывают HTTP-порты
по умолчанию. Вычищать это через поле «Start command» поверх чужого образа ненадёжно.

## Почему не прокси-SSH RunPod

У RunPod два способа SSH:

1. **Basic SSH** через `ssh.runpod.io` — проксируется RunPod, не требует public IP,
   но **не поддерживает проброс портов** (`ssh -L` падает с
   `channel 2: open failed: unknown channel type: unsupported channel type`) и не умеет SCP/SFTP.
2. **Full SSH** — прямое TCP-подключение на public IP пода, требует проброшенного TCP-порта 22
   и работающего sshd внутри контейнера. Умеет всё.

Туннель к ComfyUI возможен только со вторым. Поэтому TCP 22 — единственный проброшенный порт.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml), две джобы.

`smoke-test` гоняется всегда, включая pull request:

- `shellcheck` по рантайм-скриптам и по самому тесту;
- `docker build --check` по Dockerfile;
- сборка облегчённого двойника на `ubuntu:22.04` ([`ci/Dockerfile.sshtest`](ci/Dockerfile.sshtest)) —
  тот же `entrypoint.sh`, тот же `sshd_hardening.conf`, без CUDA-слоя — и семь проверок на нём
  ([`ci/smoke-test.sh`](ci/smoke-test.sh)): вход по ключу проходит, вход без ключа отбивается,
  `sshd -T` отдаёт ожидаемую конфигурацию, `ssh -L` пробрасывается, в образе нет вшитых
  хост-ключей, фингерпринт печатается в лог, без `PUBLIC_KEY` контейнер осознанно падает.

Джоба укладывается в полминуты против девяти на реальный образ, а ломается в CI ровно тот
класс ошибок, который иначе запирает вас снаружи оплаченного GPU-пода.

`publish` идёт только после зелёного теста и только не на pull request. Первым шагом
освобождается место на раннере: GitHub даёт **14 ГБ**, а сборка разворачивает 25–35 ГБ,
так что без `free-disk-space` она падает на `no space left on device`.

Замеры первого холодного прогона: `smoke-test` 0:33, `publish` 9:34 — из них 1:41 на
очистку диска и 7:37 на сборку с пушем.

### Теги образа

| Триггер | Теги |
|---|---|
| push в `main` | `latest`, `comfy-<версия ComfyUI>`, `sha-<коммит>` |
| тег `v1.2.3` | `1.2.3`, `comfy-<версия ComfyUI>`, `sha-<коммит>` |

Версия ComfyUI в теге берётся из `ARG COMFYUI_REF` самого Dockerfile — он остаётся
единственным источником правды. `workflow_dispatch` позволяет разово переопределить
`COMFYUI_REF`, `CUDA_IMAGE` и `TORCH_INDEX_URL`, не трогая файл; пустое поле означает
«взять из Dockerfile».

Слой с torch занимает большую часть сборки, поэтому кэш пишется в `:buildcache` рядом
с образом — правка `entrypoint.sh` пересобирает образ за минуту вместо восьми.

### Версии под вашу карту

Два ARG в [Dockerfile](Dockerfile) нужно свести между собой — это единственное место,
где сборка может сломаться:

- `CUDA_IMAGE` — тег с [hub.docker.com/r/nvidia/cuda](https://hub.docker.com/r/nvidia/cuda/tags)
- `TORCH_INDEX_URL` — индекс колёс с [pytorch.org](https://pytorch.org/get-started/locally/),
  версия CUDA должна совпадать с образом

Для Blackwell (RTX 5090, B200) нужен `cu128` или новее; для более старых карт можно взять
`cu126` и соответствующий образ CUDA.

## Как подключить RunPod к GHCR

Пакет приватный, поэтому RunPod нужны свои учётные данные.

1. GitHub → Settings → Developer settings → **Personal access tokens (classic)**,
   единственная галка `read:packages`.

   Именно classic: в документации GitHub Packages прямо сказано, что
   «GitHub Packages only supports authentication using a personal access token (classic)».
   Fine-grained токен к `ghcr.io` не пустят, и по сообщению об ошибке это не диагностируется.

2. RunPod → Settings → **Container Registry Auth** → New: имя произвольное,
   username — ваш GitHub-логин, password — этот токен.

3. В шаблоне выбрать созданную запись в «Select registry authentication».

Первый пуш создаёт пакет приватным. Проверить — на странице пакета,
Package settings → Change visibility.

## Проверено на живом поде

RunPod Secure Cloud, RTX PRO 6000 Blackwell Server Edition (97 ГБ VRAM), драйвер 595.91.07,
`/dev/shm` 132 ГБ, overlay 150 ГБ:

| | |
|---|---|
| Хост-ключ | предлагается только ed25519, генерируется под |
| Вход по ключу / без ключа | проходит / `Permission denied (publickey)` |
| `sshd -T` | совпадает с [sshd_hardening.conf](sshd_hardening.conf) |
| torch | 2.11.0+cu128, `cuda.is_available()` → True, карта определилась |
| ComfyUI | 0.36.0, стартует с заданными флагами, custom nodes пропущены |
| Слушающие сокеты | `127.0.0.1:8188` и `0.0.0.0:22`, больше ничего |
| ComfyUI через `ssh -L` | HTTP 200 |
| Порт 8188 снаружи | `Connection refused` |

Известное: база `ubuntu22.04` даёт Python 3.10, у которого EOL 31 октября 2026 — ComfyUI
предупреждает об этом при старте. Переход на `ubuntu24.04` даст 3.12, но потребует учесть
переименования пакетов `t64` (`libglib2.0-0` → `libglib2.0-0t64`).

## Настройки шаблона RunPod

| Поле | Значение |
|---|---|
| Template type | Pods |
| Compute type | NVIDIA GPU |
| Container image | `ghcr.io/USER/REPO:comfy-v0.36.0` |
| Start command | **пусто** — всё в `ENTRYPOINT` образа |
| Container disk | 40–80 ГБ (образ ~12–15 ГБ распакованным + веса моделей) |
| Persistent storage | Volume disk, **0 ГБ** |
| Expose HTTP Ports | **пусто** — удалить всё, что там стоит по умолчанию |
| Expose TCP Ports | `22` |
| Environment variables | `PUBLIC_KEY` = содержимое вашего `id_ed25519.pub` |

Дефолтные 5 ГБ container disk не подойдут — образ не влезет.

Тег лучше фиксировать явно, а не `latest`: под тянет образ при каждом старте, и `latest`
означает, что очередной коммит в `main` молча меняет то, что поднимется в следующий раз.

### Переменные окружения

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `PUBLIC_KEY` | — | обязательна, иначе контейнер осознанно падает на старте |
| `COMFY_AUTOSTART` | `1` | `0` — поднять только sshd, ComfyUI запускать руками командой `comfyui` |
| `COMFY_ALLOW_CUSTOM_NODES` | `0` | `1` — разрешить загрузку custom nodes |
| `SSHD_LOG_TO_CONSOLE` | `0` | `1` — отправить лог sshd в консоль RunPod, для разбора проблем с входом |
| `COMFY_PORT` | `8188` | |

Значения переменных хранятся в БД RunPod. Публичный ключ там держать безопасно; приватные
токены (например, `HF_TOKEN`) — нет, их лучше экспортировать в сессии по SSH.

## Подключение

При запуске пода в логах RunPod печатается фингерпринт хост-ключа — он генерируется заново
на каждый под, поэтому образ не содержит общего для всех ключа. Сверьте его при первом входе.

```bash
ssh root@POD_IP -p TCP_PORT -i ~/.ssh/id_ed25519 -L 8188:127.0.0.1:8188
```

IP и порт — в меню Connect → Direct TCP Ports. Дальше ComfyUI открывается локально
на `http://127.0.0.1:8188`.

Логи внутри пода:

```
tail -f /dev/shm/comfy/comfyui.log
tail -f /dev/shm/comfy/sshd.log
```

## Куда что пишется

| Путь | Носитель | Содержимое |
|---|---|---|
| `/dev/shm/comfy/output` | RAM | результаты |
| `/dev/shm/comfy/input` | RAM | входные изображения |
| `/dev/shm/comfy/temp` | RAM | превью, промежуточные тензоры |
| `/dev/shm/comfy/user` | RAM | настройки фронтенда, сохранённые воркфлоу |
| `/dev/shm/comfy/*.log` | RAM | логи ComfyUI и sshd |
| `/comfy/models` | container disk | веса |
| `sqlite:///:memory:` | RAM | БД ComfyUI (ассеты, миграции alembic) |

Размер `/dev/shm` печатается в лог при старте. RunPod выдаёт его по объёму RAM хоста —
на проверенном поде это 132 ГБ, так что вывод в RAM ничем не стеснён. Но если попадётся
хост с докеровским дефолтом в 64 МБ, места хватит на десяток картинок: смотрите лог.

Своя `tmpfs` через `mount` внутри пода не поднимется — RunPod не даёт `CAP_SYS_ADMIN`.
Поэтому используется `/dev/shm`, который всегда tmpfs.

## Рабочий цикл с данными

Веса моделей публичны — их можно качать прямо в под с HF. Приватные LoRA, входные изображения
и результаты гоняются через тот же SSH:

```bash
rsync -e "ssh -p TCP_PORT -i ~/.ssh/id_ed25519" -av ./my_lora.safetensors root@POD_IP:/comfy/models/loras/
```

```bash
rsync -e "ssh -p TCP_PORT -i ~/.ssh/id_ed25519" -av root@POD_IP:/dev/shm/comfy/output/ ./out/
```

Если приватные LoRA не должны касаться диска — кладите их в `/dev/shm/comfy/` и подключайте
через `extra_model_paths.yaml`, ценой оперативной памяти.

## Локальная сборка

```bash
docker build -t comfy-private:dev .
```

```bash
docker build -f ci/Dockerfile.sshtest -t comfy-sshtest . && ci/smoke-test.sh comfy-sshtest
```

## Что осталось за кадром

- Custom nodes выключены по умолчанию. Любая включённая нода может игнорировать
  `--disable-metadata` и ходить в сеть самостоятельно — включать по одной и осознанно.
- ComfyUI-Manager намеренно не установлен: он регулярно опрашивает внешние реестры.
- Версия ComfyUI закреплена (`COMFYUI_REF`). Обновление — пересборка образа, не `git pull`
  внутри пода: иначе содержимое пода перестаёт соответствовать образу.
- Egress-фильтрации нет. Если нужно запретить поду исходящие соединения после загрузки
  моделей — это `iptables` внутри контейнера, но `CAP_NET_ADMIN` RunPod тоже не даёт.
