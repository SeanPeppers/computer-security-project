#!/bin/bash
# Start sshd and a Docker daemon whose API listens on plain HTTP 2375 with no auth.
set -euo pipefail

: "${ROOT_PASSWORD:?set ROOT_PASSWORD (see .env.example)}"
[ "$ROOT_PASSWORD" != change-me ] || { echo "set your own ROOT_PASSWORD in .env" >&2; exit 1; }
echo "root:${ROOT_PASSWORD}" | chpasswd
ssh-keygen -A >/dev/null  # host keys made per container on first start, not baked into the image

/usr/sbin/sshd

# Nested Docker needs the container to run privileged (see compose.yaml).
dockerd -H unix:///var/run/docker.sock -H tcp://0.0.0.0:2375 >/var/log/dockerd.log 2>&1 &
for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info >/dev/null 2>&1 || { echo "dockerd did not start; see /var/log/dockerd.log" >&2; tail -20 /var/log/dockerd.log >&2; exit 1; }

echo "test machine ready: ssh on 22, Docker API on 2375"
# PID 1 ignores SIGTERM unless it traps it; without this `docker compose down` waits 10 s.
trap 'exit 0' TERM INT
sleep infinity &
wait
