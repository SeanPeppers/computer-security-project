#!/usr/bin/env bash
# Quick honeypot check. Standalone: does not use or depend on example.sh.
# Runs the same few checks on machine A and machine B and logs everything to evidence.log.
#
#   scripts/quick-check.sh
#   A_HOST=10.0.0.5 B_HOST=10.0.0.6 scripts/quick-check.sh
#
# Override ports with A_SSH/A_API/B_SSH/B_API, the log file with LOG, the user with SSH_USER.
# Only run this against machines you own or are authorized to test.
set -euo pipefail

A_HOST=${A_HOST:-127.0.0.1} A_SSH=${A_SSH:-2222} A_API=${A_API:-2375}
B_HOST=${B_HOST:-127.0.0.1} B_SSH=${B_SSH:-2222} B_API=${B_API:-2375}
SSH_USER=${SSH_USER:-root}
LOG=${LOG:-evidence.log}
PAUSE=${PAUSE:-3}
SOCK_DIR=$(mktemp -d)
trap 'rm -rf "$SOCK_DIR"' EXIT

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms() { python3 -c 'import time; print(time.time_ns() // 1000000)'; }

# One reused SSH connection per machine, so each password is typed once.
# shellcheck disable=SC2086
run_ssh() { ssh -o ControlMaster=auto -o ControlPath="$SOCK_DIR/$1-$2" -o ControlPersist=2m \
                -o StrictHostKeyChecking=accept-new ${SSH_OPTS:-} -p "$2" "$SSH_USER@$1" "$3"; }
# -i keeps response headers (a real dockerd sets Server, Api-Version, Ostype).
run_api() { curl -sS -i --max-time 15 "http://$1:$2$3"; }

record() {  # label host port kind request
  local out
  if [ "$4" = ssh ]; then out=$(run_ssh "$2" "$3" "$5" 2>&1) || true
  else out=$(run_api "$2" "$3" "$5" 2>&1) || true; fi
  printf '### %s  %s:%s  %s  [%s]\n$ %s\n%s\n\n' "$1" "$2" "$3" "$4" "$(stamp)" "$5" "$out" | tee -a "$LOG"
}

both() {  # kind request
  local pa pb
  if [ "$1" = ssh ]; then pa=$A_SSH pb=$B_SSH; else pa=$A_API pb=$B_API; fi
  record A "$A_HOST" "$pa" "$1" "$2"; sleep "$PAUSE"
  record B "$B_HOST" "$pb" "$1" "$2"; sleep "$PAUSE"
}

timing() {  # request n   (SSH timing: opens the connection first, so login isn't timed)
  local label host port t0 times sorted
  for label in A B; do
    if [ $label = A ]; then host=$A_HOST port=$A_SSH; else host=$B_HOST port=$B_SSH; fi
    if ! run_ssh "$host" "$port" true; then echo "### timing $label: cannot log in" | tee -a "$LOG"; continue; fi
    times=()
    for _ in $(seq "$2"); do
      t0=$(now_ms); run_ssh "$host" "$port" "$1" >/dev/null 2>&1 || true
      times+=($(( $(now_ms) - t0 ))); sleep "$PAUSE"
    done
    sorted=$(printf '%s\n' "${times[@]}" | sort -n | tr '\n' ' ')
    printf '### timing %s %s:%s [%s] ms: %s\n$ %s\n\n' "$label" "$host" "$port" "$(stamp)" "$sorted" "$1" | tee -a "$LOG"
  done
}

echo "=== quick-check $(stamp) ===" | tee -a "$LOG"

# 1. Shell behaviour: one combined command, so one password per machine.
both ssh '
echo "arith: $((2+2))"
echo "pipe: $(echo a | tr a b)"
nonexistent_cmd_xyz 2>&1
echo "proc entries: $(ls /proc | wc -l)"
cat /proc/uptime
uname -a
docker ps 2>&1 | head -3
'

# 2. Docker API: a real dockerd gives specific answers to these.
both api /_ping
both api /version
both api /nonexistent        # real: 404 {"message":"page not found"}
both api /v9.99/version      # real: "client version 9.99 is too new..."

# 3. Timing: does 'sleep 2' really take about 2000 ms on each machine?
timing 'sleep 2' 3

echo "Done. Compare A and B in $LOG." | tee -a "$LOG"
