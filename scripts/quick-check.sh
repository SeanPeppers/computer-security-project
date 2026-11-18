#!/usr/bin/env bash
# Quick check: run the same read-only checks on two machines (A and B) and log the exact command, each
# machine's output, and the UTC time it ran. It only records output; it does not judge it.
#
#   scripts/quick-check.sh                                   # all checks, A and B both local
#   A_HOST=10.77.10.20 B_HOST=10.77.10.21 SSH_PORT=22 scripts/quick-check.sh
#   SSH_OPTS="-o PubkeyAuthentication=no" REPS=10 scripts/quick-check.sh
#
# A and B both default to the local test machine, so the script can be tried against one box; point
# them at two hosts with A_HOST/A_SSH/A_API and B_HOST/B_SSH/B_API. Everything is appended to evidence.log.
# Checks: 1 shell behaviour, 2 platform facts (both over SSH), 3 Docker API, 4 SSH timing.
set -euo pipefail

A_HOST=${A_HOST:-127.0.0.1} A_SSH=${A_SSH:-${SSH_PORT:-22}} A_API=${A_API:-${API_PORT:-2375}}
B_HOST=${B_HOST:-127.0.0.1} B_SSH=${B_SSH:-${SSH_PORT:-22}} B_API=${B_API:-${API_PORT:-2375}}
LOG=${LOG:-evidence.log}
PAUSE=${PAUSE:-3}  # seconds between requests, so scripts don't hammer a machine
REPS=${REPS:-5}    # runs per machine for each timing measurement
SOCK_DIR=$(mktemp -d /tmp/qc.XXXXXX)  # short path: a long one can break the SSH socket on macOS
cleanup() {
  for sock in "$SOCK_DIR"/*; do [ -S "$sock" ] && ssh -o ControlPath="$sock" -O exit x 2>/dev/null || true; done
  rm -rf "$SOCK_DIR"
}
trap cleanup EXIT

# One SSH connection per machine, reused, so the password is typed once per machine.
# SSH_OPTS adds options, e.g. SSH_OPTS="-o PubkeyAuthentication=no".
# shellcheck disable=SC2086
run_ssh() { ssh -o ControlMaster=auto -o ControlPath="$SOCK_DIR/$1-$2" -o ControlPersist=10m \
                -o StrictHostKeyChecking=accept-new ${SSH_OPTS:-} -p "$2" "root@$1" "$3"; }
run_api() { curl -sS -i --max-time 15 "http://$1:$2$3"; }  # -i keeps the response headers
# macOS date has no %N; fall back to python3 for a millisecond clock there.
if [ "$(date +%N)" != N ]; then now_ms() { echo $(( $(date +%s%N) / 1000000 )); }; stamp() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
else now_ms() { python3 -c 'import time; print(time.time_ns() // 1000000)'; }; stamp() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")'; }; fi

record() {  # label host port kind request
  local when out
  when=$(stamp)
  if [ "$4" = ssh ]; then out=$(run_ssh "$2" "$3" "$5" 2>&1) || true; else out=$(run_api "$2" "$3" "$5" 2>&1) || true; fi
  printf '### %s  %s:%s  %s  [%s]\n$ %s\n%s\n\n' "$1" "$2" "$3" "$4" "$when" "$5" "$out" | tee -a "$LOG"
}

both() {  # kind request: same request on A, pause, then B, pause
  if [ "$1" = ssh ]; then record A "$A_HOST" "$A_SSH" ssh "$2"; sleep "$PAUSE"; record B "$B_HOST" "$B_SSH" ssh "$2"; sleep "$PAUSE"
  else record A "$A_HOST" "$A_API" api "$2"; sleep "$PAUSE"; record B "$B_HOST" "$B_API" api "$2"; sleep "$PAUSE"; fi
}

timing() {  # request n: n SSH runs per machine, A and B alternating, times logged in the order taken
  local req=$1 n=$2 t0 ta="" tb="" when
  # Open both connections first so the timing covers the command, not the login.
  if ! run_ssh "$A_HOST" "$A_SSH" true || ! run_ssh "$B_HOST" "$B_SSH" true; then echo "### timing '$req': cannot log in" | tee -a "$LOG"; return; fi
  when=$(stamp)
  for _ in $(seq "$n"); do
    t0=$(now_ms); run_ssh "$A_HOST" "$A_SSH" "$req" >/dev/null 2>&1 || true; ta+="$(( $(now_ms) - t0 )) "; sleep "$PAUSE"
    t0=$(now_ms); run_ssh "$B_HOST" "$B_SSH" "$req" >/dev/null 2>&1 || true; tb+="$(( $(now_ms) - t0 )) "; sleep "$PAUSE"
  done
  printf '### timing A %s:%s ssh [%s] n=%s ms, in order taken: %s\n$ %s\n\n' "$A_HOST" "$A_SSH" "$when" "$n" "$ta" "$req" | tee -a "$LOG"
  printf '### timing B %s:%s ssh [%s] n=%s ms, in order taken: %s\n$ %s\n\n' "$B_HOST" "$B_SSH" "$when" "$n" "$tb" "$req" | tee -a "$LOG"
}

# Check 1, shell behaviour: one SSH call, so one password per machine. Comments stay out of the block
# so the remote shell receives exactly these lines.
#   arith       $((2+2)): shell arithmetic expansion
#   pipe        $(echo a | tr a b): command substitution, a pipe, and the tr program
#   bad command nonexistent_cmd_xyz: the exact "command not found" message and its format
#   proc count  number of entries in /proc
#   uptime      /proc/uptime: seconds since boot, aggregate idle seconds
#   uname -a    kernel, hostname, release, build date, architecture
#   docker ps   whether a docker client exists on the machine and what it lists (first 3 lines)
SHELL_CMDS=$(cat <<'EOF'
echo "arith: $((2+2))"
echo "pipe: $(echo a | tr a b)"
nonexistent_cmd_xyz 2>&1
echo "proc entries: $(ls /proc | wc -l)"
cat /proc/uptime
uname -a
docker ps 2>&1 | head -3
EOF
)

# Check 2, platform facts as each machine reports them: same one-call approach.
#   uname -m           CPU architecture (aarch64 or armv7l on a Raspberry Pi, x86_64 on a PC)
#   device-tree model  /proc/device-tree/model names the board on ARM boards such as a Pi; tr strips
#                      its trailing null byte; a missing file shows up as an error line in the log
#   cpuinfo            model name / model / hardware lines; sort -u drops the per-core duplicates
#   thermal            CPU temperature in millidegrees, if the machine exposes one
#   interfaces + MACs  each network interface name with its MAC address
PLATFORM_CMDS=$(cat <<'EOF'
echo "uname -m: $(uname -m)"
echo "device-tree model: $(tr -d '\0' < /proc/device-tree/model 2>&1)"
echo "cpuinfo: $(grep -iE '^(model name|model|hardware)' /proc/cpuinfo 2>&1 | sort -u)"
echo "thermal: $(cat /sys/class/thermal/thermal_zone0/temp 2>&1)"
for i in /sys/class/net/*; do echo "$(basename "$i") $(cat "$i/address" 2>&1)"; done
EOF
)

echo "=== quick-check start $(stamp)  A=$A_HOST B=$B_HOST ===" | tee -a "$LOG"

both ssh "$SHELL_CMDS"       # check 1
both ssh "$PLATFORM_CMDS"    # check 2

# Check 3, Docker API: plain HTTP GETs on the API port, response headers kept.
both api /_ping              # health check: status line and all response headers
both api /version            # version JSON: Version, ApiVersion, Os, Arch, KernelVersion, ...
both api /nonexistent        # a path that does not exist: status code and error body
both api /v9.99/version      # an absurdly high API version: how the server answers

# Check 4, timing over SSH, measured on the laptop.
timing 'true' "$REPS"        # baseline: does nothing, so its time is connection and clock overhead
timing 'sleep 2' "$REPS"     # should take about 2000 ms plus that overhead

echo "=== quick-check end $(stamp). Raw evidence is in $LOG ===" | tee -a "$LOG"
