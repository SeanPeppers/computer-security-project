#!/usr/bin/env bash
# Example script: run the same check on two machines (A and B) and log the exact command, each machine's
# output, and the UTC time it ran.
#
#   scripts/example.sh ssh 'uname -a'            # same shell command over SSH on A and B
#   scripts/example.sh api /containers/json      # same Docker API GET on A and B
#   scripts/example.sh time ssh 'true' 10        # timing: N runs per machine, 3 s apart
#
# A and B both default to the local test machine, so the script can be built and tried
# against one box; point them at two hosts with A_HOST/A_SSH/A_API and B_HOST/B_SSH/B_API.
# Everything is appended to evidence.log.
set -euo pipefail

A_HOST=${A_HOST:-127.0.0.1} A_SSH=${A_SSH:-${SSH_PORT:-2222}} A_API=${A_API:-${API_PORT:-2375}}
B_HOST=${B_HOST:-127.0.0.1} B_SSH=${B_SSH:-${SSH_PORT:-2222}} B_API=${B_API:-${API_PORT:-2375}}
LOG=${LOG:-evidence.log}
PAUSE=${PAUSE:-3}  # seconds between requests, so scripts don't hammer a machine
SOCK_DIR=$(mktemp -d)
cleanup() {
  for sock in "$SOCK_DIR"/*; do [ -S "$sock" ] && ssh -o ControlPath="$sock" -O exit x 2>/dev/null; done
  rm -rf "$SOCK_DIR"
}
trap cleanup EXIT

# One SSH connection per machine, reused, so the password is typed once per machine.
# SSH_OPTS adds options, e.g. SSH_OPTS="-o UserKnownHostsFile=/tmp/test_known_hosts".
# shellcheck disable=SC2086
run_ssh() { ssh -o ControlMaster=auto -o ControlPath="$SOCK_DIR/$1-$2" -o ControlPersist=10m \
                -o StrictHostKeyChecking=accept-new ${SSH_OPTS:-} -p "$2" "root@$1" "$3"; }
run_api() { curl -sS --max-time 15 "http://$1:$2$3"; }
# macOS date has no %N; fall back to python3 for a millisecond clock there.
if [ "$(date +%N)" != N ]; then now_ms() { echo $(( $(date +%s%N) / 1000000 )); }; stamp() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
else now_ms() { python3 -c 'import time; print(time.time_ns() // 1000000)'; }; stamp() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")'; }; fi

record() {  # label host port kind request
  local when out
  when=$(stamp)
  if [ "$4" = ssh ]; then out=$(run_ssh "$2" "$3" "$5" 2>&1) || true; else out=$(run_api "$2" "$3" "$5" 2>&1) || true; fi
  printf '### %s  %s:%s  %s  [%s]\n$ %s\n%s\n\n' "$1" "$2" "$3" "$4" "$when" "$5" "$out" | tee -a "$LOG"
}

case "${1:-}" in
  ssh) record A "$A_HOST" "$A_SSH" ssh "$2"; sleep "$PAUSE"; record B "$B_HOST" "$B_SSH" ssh "$2" ;;
  api) record A "$A_HOST" "$A_API" api "$2"; sleep "$PAUSE"; record B "$B_HOST" "$B_API" api "$2" ;;
  time)
    kind=$2 req=$3 n=${4:-10}
    for label in A B; do
      if [ $label = A ]; then host=$A_HOST; port=$([ "$kind" = ssh ] && echo "$A_SSH" || echo "$A_API")
      else host=$B_HOST; port=$([ "$kind" = ssh ] && echo "$B_SSH" || echo "$B_API"); fi
      # Open the connection first so the timing covers the command, not the login.
      if [ "$kind" = ssh ] && ! run_ssh "$host" "$port" true; then echo "### timing $label $host:$port: cannot log in" | tee -a "$LOG"; continue; fi
      times=()
      for _ in $(seq "$n"); do
        t0=$(now_ms)
        if [ "$kind" = ssh ]; then run_ssh "$host" "$port" "$req" >/dev/null 2>&1 || true; else run_api "$host" "$port" "$req" >/dev/null 2>&1 || true; fi
        times+=($(( $(now_ms) - t0 )))
        sleep "$PAUSE"
      done
      sorted=$(printf '%s\n' "${times[@]}" | sort -n | tr '\n' ' ')
      printf '### timing %s %s:%s %s [%s] n=%s ms: %s(median %s)\n$ %s\n\n' "$label" "$host" "$port" "$kind" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" "$sorted" "$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')" "$req" | tee -a "$LOG"
    done ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
