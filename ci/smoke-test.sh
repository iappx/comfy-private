#!/usr/bin/env bash
set -euo pipefail

IMAGE=${1:?usage: smoke-test.sh <image>}
NAME="comfy-smoke-$$"
PORT=${SMOKE_SSH_PORT:-2222}
FWD=${SMOKE_FWD_PORT:-9999}
KEYDIR=$(mktemp -d)

cleanup() {
    pkill -f "L 127.0.0.1:$FWD:127.0.0.1:22" 2>/dev/null || true
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$KEYDIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    docker logs "$NAME" >&2 2>/dev/null || true
    exit 1
}

ssh-keygen -q -t ed25519 -N '' -f "$KEYDIR/key" -C smoke

docker run -d --name "$NAME" -p "127.0.0.1:$PORT:22" \
    -e PUBLIC_KEY="$(cat "$KEYDIR/key.pub")" \
    -e COMFY_AUTOSTART=0 \
    "$IMAGE" >/dev/null

SSHOPT=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o ConnectTimeout=5
    -o LogLevel=ERROR
)

ready=0
for _ in $(seq 30); do
    if ssh "${SSHOPT[@]}" -i "$KEYDIR/key" -p "$PORT" root@127.0.0.1 true 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" = 1 ] || fail "sshd never became reachable"

echo "== entrypoint publishes a host key fingerprint"
docker logs "$NAME" 2>&1 | grep -q 'ED25519' || fail "no host key fingerprint in the log"

echo "== the image ships no baked-in host keys"
if docker run --rm --entrypoint sh "$IMAGE" -c 'ls /etc/ssh/ssh_host_* 2>/dev/null' | grep -q .; then
    fail "image ships ssh host keys"
fi

echo "== login with the key"
[ "$(ssh "${SSHOPT[@]}" -i "$KEYDIR/key" -p "$PORT" root@127.0.0.1 'echo ok')" = ok ] \
    || fail "key login rejected"

echo "== login without the key is refused"
if ssh "${SSHOPT[@]}" \
       -o PubkeyAuthentication=no \
       -o PreferredAuthentications=password,keyboard-interactive \
       -p "$PORT" root@127.0.0.1 true 2>/dev/null; then
    fail "login without a key succeeded"
fi

echo "== effective sshd configuration"
cfg=$(docker exec "$NAME" sshd -T)
for expect in \
    'passwordauthentication no' \
    'authenticationmethods publickey' \
    'permitrootlogin without-password' \
    'permitemptypasswords no' \
    'x11forwarding no' \
    'allowtcpforwarding local'
do
    grep -qx "$expect" <<<"$cfg" || fail "expected '$expect' from sshd -T"
done

echo "== local port forwarding"
ssh "${SSHOPT[@]}" -i "$KEYDIR/key" -p "$PORT" -f -N \
    -L "127.0.0.1:$FWD:127.0.0.1:22" root@127.0.0.1
sleep 1
exec 3<>"/dev/tcp/127.0.0.1/$FWD" || fail "no connection through the tunnel"
read -r -t 5 banner <&3 || fail "no banner through the tunnel"
exec 3<&-
[[ $banner == SSH-2.0-* ]] || fail "unexpected banner through the tunnel: $banner"

echo "== the launcher creates every directory ComfyUI expects"
docker exec "$NAME" sh -c '
    comfyui >/dev/null 2>&1 || true
    for d in /dev/shm/comfy/output /dev/shm/comfy/input /dev/shm/comfy/temp \
             /dev/shm/comfy/user /comfy/models /comfy/custom_nodes
    do
        [ -d "$d" ] || { echo "missing: $d"; exit 1; }
    done
' || fail "the launcher left a directory ComfyUI needs uncreated"

echo "== entrypoint refuses to start without PUBLIC_KEY"
if docker run --rm -e COMFY_AUTOSTART=0 "$IMAGE" >/dev/null 2>&1; then
    fail "container started without PUBLIC_KEY"
fi

echo "ALL CHECKS PASSED"
