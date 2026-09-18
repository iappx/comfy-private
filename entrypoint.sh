#!/bin/sh
set -eu

RAM_ROOT=${COMFY_RAM_ROOT:-/dev/shm/comfy}

if [ -z "${PUBLIC_KEY:-}" ]; then
    echo "PUBLIC_KEY is empty, refusing to start a pod nobody can log into" >&2
    exit 1
fi

install -d -m 700 /root/.ssh
printf '%s\n' "$PUBLIC_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
unset PUBLIC_KEY

install -d -m 755 /run/sshd
install -d -m 700 "$RAM_ROOT"

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
fi

case "$(stat -f -c %T /dev/shm)" in
    tmpfs|ramfs) ;;
    *) echo "WARNING: /dev/shm is not RAM-backed, scratch data will land on disk" >&2 ;;
esac

echo "scratch space: $(df -h /dev/shm | awk 'NR==2 {print $2}')"
echo "host key fingerprint (verify this on first connect):"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

if [ "${COMFY_AUTOSTART:-1}" = "1" ]; then
    /usr/local/bin/comfyui >> "$RAM_ROOT/comfyui.log" 2>&1 &
fi

if [ "${SSHD_LOG_TO_CONSOLE:-0}" = "1" ]; then
    exec /usr/sbin/sshd -D -e
fi

exec /usr/sbin/sshd -D -E "$RAM_ROOT/sshd.log"
