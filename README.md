# Private ComfyUI instance

A Docker image that runs ComfyUI without exposing it: the web UI listens on `127.0.0.1`
only, the container's single open port is SSH with key-based login, and you reach the UI
through an SSH tunnel. Scratch directories, logs and the database live in RAM, and no
metadata is embedded in the results.

## How this differs from stock ComfyUI

ComfyUI is launched by [`comfyui.sh`](comfyui.sh) with a fixed set of flags:

| Flag | Effect |
|---|---|
| `--listen 127.0.0.1` | the server is reachable only from inside the container |
| `--disable-metadata` | prompts and workflows are not embedded in saved files |
| `--disable-api-nodes` | nodes that call external APIs are not registered |
| `--database-url sqlite:///:memory:` | the ComfyUI database lives in process memory and never reaches disk |
| `--output-directory`, `--input-directory`, `--temp-directory`, `--user-directory` | all four directories are moved to `/dev/shm/comfy` |
| `--base-directory /comfy` | everything else, model weights included, stays on disk |
| `--dont-print-server` | server output is not printed |

On top of that:

- `HF_HUB_DISABLE_TELEMETRY=1` and `DO_NOT_TRACK=1` are set both in the image and in the
  launch script itself;
- `XDG_CACHE_HOME` and `MPLCONFIGDIR` point into `/dev/shm/comfy/cache`;
- `PYTHONDONTWRITEBYTECODE=1`, so no `.pyc` files pile up next to the code;
- interactive SSH sessions get `HISTFILE=/dev/null` and `LESSHISTFILE=/dev/null`
  (`/etc/profile.d/comfy.sh`, see the [Dockerfile](Dockerfile));
- with `COMFY_AUTOSTART=1`, ComfyUI output goes to `/dev/shm/comfy/comfyui.log` instead of
  the container's stdout.

The image carries no ComfyUI-Manager and no other add-ons: only ComfyUI at the pinned
version and its `requirements.txt` are installed.

## SSH

Host keys are deleted at build time (`rm -f /etc/ssh/ssh_host_*`) and an ed25519 key is
generated when the container first starts, so the image contains no host key shared between
instances. The fingerprint is printed to the log at startup; verify it when you connect for
the first time.

`PUBLIC_KEY` is written to `/root/.ssh/authorized_keys` (mode 600) and unset immediately
afterwards, so it never ends up in sshd's environment. Without `PUBLIC_KEY`,
[`entrypoint.sh`](entrypoint.sh) refuses to start.

The sshd configuration is [`sshd_hardening.conf`](sshd_hardening.conf):

| Directive | |
|---|---|
| `AuthenticationMethods publickey` | the only accepted method |
| `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitEmptyPasswords no` | passwords are off entirely |
| `PermitRootLogin prohibit-password`, `AllowUsers root` | root only, by key only |
| `PermitUserEnvironment no` | the client cannot inject environment variables |
| `AllowTcpForwarding local` | `ssh -L` works, remote forwarding with `-R` is refused |
| `GatewayPorts no`, `PermitTunnel no`, `AllowAgentForwarding no`, `X11Forwarding no` | the remaining channels are closed |
| `HostKey /etc/ssh/ssh_host_ed25519_key` | a single host key type is offered |
| `LoginGraceTime 20`, `MaxAuthTries 3`, `MaxSessions 4` | limits on guessing and on concurrent sessions |
| `ClientAliveInterval 30`, `ClientAliveCountMax 6` | dead sessions are dropped |
| `PrintMotd no`, `PrintLastLog no`, `Banner none` | nothing is printed on login |

The [`Dockerfile`](Dockerfile) declares exactly one port: `EXPOSE 22`.

## Building

```bash
docker build -t comfy-private .
```

Build args:

| ARG | Default |
|---|---|
| `CUDA_IMAGE` | `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04` |
| `COMFYUI_REF` | `v0.36.0` |
| `TORCH_INDEX_URL` | `https://download.pytorch.org/whl/cu128` |

The base image and the torch wheel index have to agree on the CUDA version:

```bash
docker build \
  --build-arg CUDA_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04 \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126 \
  -t comfy-private .
```

ComfyUI is cloned at the tag given by `COMFYUI_REF` and its `.git` directory is removed;
moving to another version means rebuilding the image. Python comes from the base image
(the `python3` package of Ubuntu 24.04, that is 3.12) and dependencies are installed into
the `/opt/venv` virtualenv.

## Running

```bash
docker run -d --name comfy --gpus all \
  -p 127.0.0.1:2222:22 \
  --shm-size=8g \
  -v "$PWD/models:/comfy/models" \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  comfy-private
```

Scratch directories and logs live in `/dev/shm`, so its size is the ceiling for results and
temporary files. The entrypoint prints the actual size of `/dev/shm` at startup and warns if
it turns out not to be tmpfs or ramfs.

## Connecting

Check the host key fingerprint in the container log:

```bash
docker logs comfy
```

Open the tunnel:

```bash
ssh -i ~/.ssh/id_ed25519 -p 2222 -L 8188:127.0.0.1:8188 root@HOST
```

ComfyUI is then available locally at `http://127.0.0.1:8188`.

Logs inside the container:

```bash
tail -f /dev/shm/comfy/comfyui.log
tail -f /dev/shm/comfy/sshd.log
```

If ComfyUI was not started automatically, the SSH session has a `comfyui` command — the same
script, and any extra arguments are passed through to `main.py`.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `PUBLIC_KEY` | — | required; the entrypoint exits with an error if it is empty |
| `COMFY_AUTOSTART` | `1` | any other value brings up sshd only, leaving ComfyUI to be started by hand |
| `COMFY_ALLOW_CUSTOM_NODES` | `1` | any other value adds `--disable-all-custom-nodes` |
| `SSHD_LOG_TO_CONSOLE` | `0` | `1` sends the sshd log to the container console instead of a file in RAM |
| `COMFY_PORT` | `8188` | the port ComfyUI listens on at `127.0.0.1` |

Paths are image environment variables too: `COMFY_HOME=/opt/comfyui`,
`COMFY_DATA_ROOT=/comfy`, `COMFY_RAM_ROOT=/dev/shm/comfy`.

## Where things are written

| Path | Backed by | Contents |
|---|---|---|
| `/dev/shm/comfy/output` | RAM | results |
| `/dev/shm/comfy/input` | RAM | input files |
| `/dev/shm/comfy/temp` | RAM | previews and intermediate files |
| `/dev/shm/comfy/user` | RAM | the ComfyUI user directory: settings, saved workflows |
| `/dev/shm/comfy/cache` | RAM | `XDG_CACHE_HOME`, `MPLCONFIGDIR` |
| `/dev/shm/comfy/comfyui.log`, `/dev/shm/comfy/sshd.log` | RAM | logs |
| `sqlite:///:memory:` | RAM | the ComfyUI database |
| `/comfy/models` | disk | model weights |
| `/comfy/huggingface`, `/comfy/torch` | disk | `HF_HOME` and `TORCH_HOME` unless overridden |

The directory in RAM is created with mode 700, as is everything below it.

## Custom nodes

Enabled by default: `--disable-all-custom-nodes` is added only when
`COMFY_ALLOW_CUSTOM_NODES` is set to something other than `1`. The flags listed above are
arguments to ComfyUI itself and say nothing about what third-party node code does.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml), two jobs.

`smoke-test` runs on pushes to `main`, on `v*` tags and on pull requests (changes confined
to `*.md` do not trigger a build):

- `actionlint` on the workflow itself;
- `shellcheck` on [`entrypoint.sh`](entrypoint.sh), [`comfyui.sh`](comfyui.sh) and
  [`ci/smoke-test.sh`](ci/smoke-test.sh);
- `docker build --check` on the Dockerfile;
- a build of the lightweight twin [`ci/Dockerfile.sshtest`](ci/Dockerfile.sshtest):
  `ubuntu:24.04` with the same `entrypoint.sh`, `comfyui.sh` and `sshd_hardening.conf`, but
  without CUDA and torch;
- a run of [`ci/smoke-test.sh`](ci/smoke-test.sh) against that twin.

The smoke test starts a container with a throwaway key and checks eight things:

1. the entrypoint prints a host key fingerprint to the log;
2. the image ships no baked-in host keys;
3. login with the key succeeds;
4. login without the key (password, keyboard-interactive) is refused;
5. `sshd -T` reports `passwordauthentication no`, `authenticationmethods publickey`,
   `permitrootlogin without-password`, `permitemptypasswords no`, `x11forwarding no`,
   `allowtcpforwarding local`;
6. a connection goes through `ssh -L` and returns an SSH banner;
7. running the launcher creates every directory ComfyUI expects, on disk and in RAM;
8. the container does not start without `PUBLIC_KEY`.

`publish` runs after a green smoke test and only outside pull requests: it builds
`linux/amd64` and pushes to `ghcr.io/<owner>/<repo>`. Build arg values come from the `ARG`
defaults in the Dockerfile, while `workflow_dispatch` can override `COMFYUI_REF`,
`CUDA_IMAGE` and `TORCH_INDEX_URL` for a single run without touching the file. The layer
cache is written to `:buildcache` next to the image.

| Trigger | Tags |
|---|---|
| push to `main` | `latest`, `comfy-<COMFYUI_REF>`, `sha-<commit>` |
| `v1.2.3` tag | `1.2.3`, `comfy-<COMFYUI_REF>`, `sha-<commit>` |

## Running the checks locally

```bash
docker build -f ci/Dockerfile.sshtest -t comfy-sshtest . && ci/smoke-test.sh comfy-sshtest
```

The test ports come from `SMOKE_SSH_PORT` (2222 by default) and `SMOKE_FWD_PORT` (9999).

## What the image does not do

Everything above is about the network and about the filesystem inside the container. Anyone
with root on the host machine can see the container's processes, its memory, its VRAM and
the contents of `/dev/shm`; no setting inside the image changes that. In the same way,
freeing the disk after the container is removed is not a guaranteed erasure of the data.

Outbound traffic is not filtered: the container can reach the network, and the image itself
offers no way to prevent that.
