# Приватный инстанс ComfyUI

Docker-образ с ComfyUI, который не выставлен наружу: веб-интерфейс слушает только
`127.0.0.1`, единственный открытый порт контейнера — SSH с входом по ключу, доступ
к морде идёт через SSH-туннель. Рабочие каталоги, логи и база данных лежат в RAM,
метаданные в результаты не вшиваются.

## Чем это отличается от голого ComfyUI

ComfyUI запускается скриптом [`comfyui.sh`](comfyui.sh) с фиксированным набором флагов:

| Флаг | Что даёт |
|---|---|
| `--listen 127.0.0.1` | сервер доступен только изнутри контейнера |
| `--disable-metadata` | промпты и воркфлоу не попадают в сохранённые файлы |
| `--disable-api-nodes` | ноды, ходящие во внешние API, не регистрируются |
| `--database-url sqlite:///:memory:` | БД ComfyUI живёт в памяти процесса и не пишется на диск |
| `--output-directory`, `--input-directory`, `--temp-directory`, `--user-directory` | все четыре каталога перенесены в `/dev/shm/comfy` |
| `--base-directory /comfy` | всё остальное, включая веса, остаётся на диске |
| `--dont-print-server` | вывод сервера не печатается |

Дополнительно к этому:

- `HF_HUB_DISABLE_TELEMETRY=1` и `DO_NOT_TRACK=1` заданы и в образе, и в самом скрипте запуска;
- `XDG_CACHE_HOME` и `MPLCONFIGDIR` указывают в `/dev/shm/comfy/cache`;
- `PYTHONDONTWRITEBYTECODE=1`, так что рядом с кодом не появляются `.pyc`;
- в интерактивной сессии по SSH выставлены `HISTFILE=/dev/null` и `LESSHISTFILE=/dev/null`
  (`/etc/profile.d/comfy.sh`, см. [Dockerfile](Dockerfile));
- при `COMFY_AUTOSTART=1` вывод ComfyUI уходит в `/dev/shm/comfy/comfyui.log`,
  а не в stdout контейнера.

В образе нет ComfyUI-Manager и других надстроек: ставится только сам ComfyUI нужной версии
и его `requirements.txt`.

## SSH

Хост-ключи удаляются на этапе сборки (`rm -f /etc/ssh/ssh_host_*`), а ed25519-ключ
генерируется при первом старте контейнера — общего для всех инстансов ключа в образе нет.
Фингерпринт печатается в лог при запуске, его можно сверить при первом подключении.

`PUBLIC_KEY` записывается в `/root/.ssh/authorized_keys` (режим 600) и сразу после этого
переменная снимается, так что в окружение sshd она не попадает. Без `PUBLIC_KEY`
[`entrypoint.sh`](entrypoint.sh) отказывается стартовать.

Конфигурация sshd — [`sshd_hardening.conf`](sshd_hardening.conf):

| Директива | |
|---|---|
| `AuthenticationMethods publickey` | единственный допустимый метод |
| `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitEmptyPasswords no` | пароли выключены полностью |
| `PermitRootLogin prohibit-password`, `AllowUsers root` | вход только root и только по ключу |
| `PermitUserEnvironment no` | клиент не может подсунуть переменные окружения |
| `AllowTcpForwarding local` | `ssh -L` работает, обратный проброс `-R` запрещён |
| `GatewayPorts no`, `PermitTunnel no`, `AllowAgentForwarding no`, `X11Forwarding no` | остальные каналы закрыты |
| `HostKey /etc/ssh/ssh_host_ed25519_key` | предлагается единственный тип хост-ключа |
| `LoginGraceTime 20`, `MaxAuthTries 3`, `MaxSessions 4` | лимиты на подбор и на число сессий |
| `ClientAliveInterval 30`, `ClientAliveCountMax 6` | мёртвые сессии закрываются |
| `PrintMotd no`, `PrintLastLog no`, `Banner none` | при входе ничего не печатается |

В [`Dockerfile`](Dockerfile) объявлен ровно один порт — `EXPOSE 22`.

## Сборка

```bash
docker build -t comfy-private .
```

Параметры сборки:

| ARG | По умолчанию |
|---|---|
| `CUDA_IMAGE` | `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04` |
| `COMFYUI_REF` | `v0.36.0` |
| `TORCH_INDEX_URL` | `https://download.pytorch.org/whl/cu128` |

Базовый образ и индекс колёс torch должны быть согласованы по версии CUDA:

```bash
docker build \
  --build-arg CUDA_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04 \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126 \
  -t comfy-private .
```

ComfyUI клонируется по тегу из `COMFYUI_REF`, каталог `.git` удаляется. Обновление версии —
пересборка образа. Python берётся из базового образа (`python3` пакетом Ubuntu 24.04,
то есть 3.12), зависимости ставятся в venv `/opt/venv`.

## Запуск

```bash
docker run -d --name comfy --gpus all \
  -p 127.0.0.1:2222:22 \
  --shm-size=8g \
  -v "$PWD/models:/comfy/models" \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  comfy-private
```

Рабочие каталоги и логи лежат в `/dev/shm`, поэтому его размер задаёт потолок для
результатов и временных файлов. Entrypoint печатает при старте фактический размер
`/dev/shm` и предупреждает, если тот оказался не tmpfs/ramfs.

## Подключение

Сверьте фингерпринт хост-ключа из лога контейнера:

```bash
docker logs comfy
```

Поднимите туннель:

```bash
ssh -i ~/.ssh/id_ed25519 -p 2222 -L 8188:127.0.0.1:8188 root@HOST
```

ComfyUI открывается локально на `http://127.0.0.1:8188`.

Логи внутри контейнера:

```bash
tail -f /dev/shm/comfy/comfyui.log
tail -f /dev/shm/comfy/sshd.log
```

Если ComfyUI не запускался автоматически, в SSH-сессии доступна команда `comfyui` —
это тот же скрипт, и любые дополнительные аргументы он передаёт в `main.py`.

## Переменные окружения

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `PUBLIC_KEY` | — | обязательна; при пустом значении entrypoint завершается с ошибкой |
| `COMFY_AUTOSTART` | `1` | любое другое значение — поднять только sshd, ComfyUI запускать вручную |
| `COMFY_ALLOW_CUSTOM_NODES` | `1` | любое другое значение добавляет `--disable-all-custom-nodes` |
| `SSHD_LOG_TO_CONSOLE` | `0` | `1` — sshd логирует в консоль контейнера вместо файла в RAM |
| `COMFY_PORT` | `8188` | порт ComfyUI на `127.0.0.1` |

Пути тоже задаются переменными окружения образа: `COMFY_HOME=/opt/comfyui`,
`COMFY_DATA_ROOT=/comfy`, `COMFY_RAM_ROOT=/dev/shm/comfy`.

## Куда что пишется

| Путь | Носитель | Содержимое |
|---|---|---|
| `/dev/shm/comfy/output` | RAM | результаты |
| `/dev/shm/comfy/input` | RAM | входные файлы |
| `/dev/shm/comfy/temp` | RAM | превью и промежуточные файлы |
| `/dev/shm/comfy/user` | RAM | пользовательский каталог ComfyUI: настройки, сохранённые воркфлоу |
| `/dev/shm/comfy/cache` | RAM | `XDG_CACHE_HOME`, `MPLCONFIGDIR` |
| `/dev/shm/comfy/comfyui.log`, `/dev/shm/comfy/sshd.log` | RAM | логи |
| `sqlite:///:memory:` | RAM | база данных ComfyUI |
| `/comfy/models` | диск | веса |
| `/comfy/huggingface`, `/comfy/torch` | диск | `HF_HOME` и `TORCH_HOME`, если не переопределены |

Каталог в RAM создаётся с режимом 700, как и все подкаталоги внутри него.

## Custom nodes

Включены по умолчанию: `--disable-all-custom-nodes` добавляется только тогда, когда
`COMFY_ALLOW_CUSTOM_NODES` не равна `1`. Перечисленные выше флаги — это аргументы
самого ComfyUI и на код сторонних нод не распространяются.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml), две джобы.

`smoke-test` выполняется на push в `main`, на теги `v*` и на pull request
(правки только в `*.md` сборку не запускают):

- `actionlint` по самому workflow;
- `shellcheck` по [`entrypoint.sh`](entrypoint.sh), [`comfyui.sh`](comfyui.sh)
  и [`ci/smoke-test.sh`](ci/smoke-test.sh);
- `docker build --check` по Dockerfile;
- сборка облегчённого двойника [`ci/Dockerfile.sshtest`](ci/Dockerfile.sshtest):
  `ubuntu:24.04` с теми же `entrypoint.sh`, `comfyui.sh` и `sshd_hardening.conf`, но без CUDA
  и torch;
- запуск [`ci/smoke-test.sh`](ci/smoke-test.sh) на этом двойнике.

Смоук-тест поднимает контейнер с одноразовым ключом и проверяет семь вещей:

1. entrypoint печатает в лог фингерпринт хост-ключа;
2. в образе нет вшитых хост-ключей;
3. вход по ключу проходит;
4. вход без ключа (пароль, keyboard-interactive) отбивается;
5. `sshd -T` отдаёт `passwordauthentication no`, `authenticationmethods publickey`,
   `permitrootlogin without-password`, `permitemptypasswords no`, `x11forwarding no`,
   `allowtcpforwarding local`;
6. через `ssh -L` проходит соединение и приходит SSH-баннер;
7. без `PUBLIC_KEY` контейнер не стартует.

`publish` идёт после зелёного смоук-теста и только не на pull request: собирает
`linux/amd64` и пушит в `ghcr.io/<owner>/<repo>`. Значения build args берутся из
`ARG`-дефолтов Dockerfile, а `workflow_dispatch` позволяет разово переопределить
`COMFYUI_REF`, `CUDA_IMAGE` и `TORCH_INDEX_URL`, не трогая файл. Кэш слоёв пишется
в `:buildcache` рядом с образом.

| Триггер | Теги |
|---|---|
| push в `main` | `latest`, `comfy-<COMFYUI_REF>`, `sha-<коммит>` |
| тег `v1.2.3` | `1.2.3`, `comfy-<COMFYUI_REF>`, `sha-<коммит>` |

## Локальная проверка

```bash
docker build -f ci/Dockerfile.sshtest -t comfy-sshtest . && ci/smoke-test.sh comfy-sshtest
```

Порты теста настраиваются переменными `SMOKE_SSH_PORT` (по умолчанию 2222)
и `SMOKE_FWD_PORT` (9999).

## Чего образ не делает

Всё перечисленное — про сеть и про файловую систему внутри контейнера. Тот, у кого
root на хост-машине, видит процессы контейнера, его память, VRAM и содержимое `/dev/shm`;
настройками внутри образа это не меняется. Точно так же освобождение диска после удаления
контейнера не является гарантированным стиранием данных.

Исходящий трафик не фильтруется: контейнер может обращаться в сеть, и ограничить это
средствами самого образа нельзя.
