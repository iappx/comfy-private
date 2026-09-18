ARG CUDA_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
FROM ${CUDA_IMAGE}

ARG COMFYUI_REF=v0.36.0
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin \
    COMFY_HOME=/opt/comfyui \
    COMFY_DATA_ROOT=/comfy \
    COMFY_RAM_ROOT=/dev/shm/comfy \
    HF_HUB_DISABLE_TELEMETRY=1 \
    DO_NOT_TRACK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      openssh-server \
      python3 \
      python3-venv \
      libgl1 \
      libglib2.0-0t64 \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_*

RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/comfyanonymous/ComfyUI ${COMFY_HOME} \
 && rm -rf ${COMFY_HOME}/.git

RUN python3 -m venv ${VIRTUAL_ENV} \
 && pip install --upgrade pip \
 && pip install --index-url ${TORCH_INDEX_URL} torch torchvision torchaudio \
 && pip install -r ${COMFY_HOME}/requirements.txt

COPY sshd_hardening.conf /etc/ssh/sshd_config.d/10-hardening.conf
COPY comfyui.sh /usr/local/bin/comfyui
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 0644 /etc/ssh/sshd_config.d/10-hardening.conf \
 && chmod 0755 /usr/local/bin/comfyui /usr/local/bin/entrypoint.sh \
 && mkdir -p /run/sshd ${COMFY_DATA_ROOT}/models \
 && printf '%s\n' \
      'PATH="/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
      'COMFY_HOME="/opt/comfyui"' \
      'COMFY_DATA_ROOT="/comfy"' \
      'COMFY_RAM_ROOT="/dev/shm/comfy"' \
      'VIRTUAL_ENV="/opt/venv"' \
      'HF_HUB_DISABLE_TELEMETRY="1"' \
      'DO_NOT_TRACK="1"' \
      > /etc/environment \
 && printf '%s\n' \
      'export PATH=/opt/venv/bin:$PATH' \
      'export COMFY_HOME=/opt/comfyui' \
      'export COMFY_DATA_ROOT=/comfy' \
      'export COMFY_RAM_ROOT=/dev/shm/comfy' \
      'export HF_HUB_DISABLE_TELEMETRY=1' \
      'export DO_NOT_TRACK=1' \
      'export HISTFILE=/dev/null' \
      'export LESSHISTFILE=/dev/null' \
      > /etc/profile.d/comfy.sh \
 && chmod 0644 /etc/profile.d/comfy.sh \
 && printf '%s\n' '. /etc/profile.d/comfy.sh' >> /root/.bashrc

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
