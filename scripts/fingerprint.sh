#!/usr/bin/env bash
# Compare two machines (A and B) side by side and log every difference that could expose one as
# a honeypot: a decoy or monitored box usually differs from a real one in small, observable ways.
#
#   scripts/fingerprint.sh            # collect the same signals on A and B, diff them, flag tells
#
# It does three things and appends all of it to fingerprint.log:
#   1. SIGNALS  one SSH round trip per machine gathers ~25 host signals; the two blocks are diffed
#               line by line, so every DIFFER line is something that tells A and B apart.
#   2. DOCKER   /version and /info from each machine's Docker API, diffed the same way.
#   3. TELLS    per machine, absolute honeypot indicators (containerized, freshly booted, empty
#               shell history, monitoring agents, sparse system, low entropy, ...).
#
# A and B both default to the local test machine, so out of the box this compares the box to
# itself: the diff is empty and the tells match — a self-test. Point them at two hosts with
# A_HOST/A_SSH/A_API and B_HOST/B_SSH/B_API to compare for real. These are heuristics, read-only;
# run them only on machines you are allowed to test.
set -euo pipefail

A_HOST=${A_HOST:-127.0.0.1} A_SSH=${A_SSH:-${SSH_PORT:-2222}} A_API=${A_API:-${API_PORT:-2375}}
B_HOST=${B_HOST:-127.0.0.1} B_SSH=${B_SSH:-${SSH_PORT:-2222}} B_API=${B_API:-${API_PORT:-2375}}
LOG=${LOG:-fingerprint.log}
SOCK_DIR=$(mktemp -d)
WORK=$(mktemp -d)
cleanup() {
  for sock in "$SOCK_DIR"/*; do [ -S "$sock" ] && ssh -o ControlPath="$sock" -O exit x 2>/dev/null; done
  rm -rf "$SOCK_DIR" "$WORK"
}
trap cleanup EXIT

# One reused SSH connection per machine, so the password is typed once. SSH_OPTS adds options,
# e.g. SSH_OPTS="-o UserKnownHostsFile=/tmp/test_known_hosts".
# shellcheck disable=SC2086
run_ssh() { ssh -o ControlMaster=auto -o ControlPath="$SOCK_DIR/$1-$2" -o ControlPersist=10m \
                -o StrictHostKeyChecking=accept-new ${SSH_OPTS:-} -p "$2" "root@$1" "$3"; }
run_api() { curl -sS --max-time 15 "http://$1:$2$3"; }
if [ "$(date +%N)" != N ]; then stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
else stamp() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }; fi

# Signals collected on the target. Printed as stable "key: value" lines so the A/B diff is clean
# and ordered. Sent base64-encoded to sidestep all the remote-quoting trouble.
COLLECTOR=$(cat <<'EOF'
set -u
val() { "$@" 2>/dev/null || true; }
echo "hostname: $(val hostname)"
echo "kernel: $(uname -r 2>/dev/null)"
echo "arch: $(uname -m 2>/dev/null)"
pretty=unknown; [ -r /etc/os-release ] && . /etc/os-release && pretty=${PRETTY_NAME:-unknown}
echo "os: $pretty"
echo "uptime_s: $(cut -d. -f1 /proc/uptime 2>/dev/null)"
echo "nproc: $(val nproc)"
echo "cpu_model: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
echo "mem_total_kb: $(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
echo "entropy: $(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)"
echo "modules: $(lsmod 2>/dev/null | tail -n +2 | wc -l)"
echo "packages: $(dpkg -l 2>/dev/null | grep -c '^ii')"
echo "users_total: $(getent passwd 2>/dev/null | wc -l)"
echo "users_withshell: $(getent passwd 2>/dev/null | awk -F: '$7 ~ /(ba)?sh$/' | wc -l)"
echo "proc_count: $(ps -e --no-headers 2>/dev/null | wc -l)"
echo "proc_names: $(ps -eo comm= 2>/dev/null | sort -u | tr '\n' ',')"
echo "listening: $(ss -H -tln 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ',')"
echo "root_history: $([ -f /root/.bash_history ] && wc -l < /root/.bash_history || echo 0)"
echo "logins_seen: $(last -n 200 2>/dev/null | grep -cE '^[a-z]')"
echo "dockerenv: $([ -e /.dockerenv ] && echo yes || echo no)"
echo "virt: $(val systemd-detect-virt)"
echo "cgroup1: $(tr '\n' ';' < /proc/1/cgroup 2>/dev/null)"
echo "rootfs_type: $(awk '$2=="/"{print $3; exit}' /proc/mounts 2>/dev/null)"
echo "overlay_mounts: $(grep -c overlay /proc/mounts 2>/dev/null)"
echo "monitoring: $(for p in auditd sysdig falco osqueryd snoopy sysdig-probe; do command -v $p >/dev/null 2>&1 && printf '%s ' $p; done)"
echo "audit_rules: $(auditctl -l 2>/dev/null | grep -vce '^No rules$')"
echo "clock_utc: $(date -u +%s 2>/dev/null)"
EOF
)
B64=$(printf '%s' "$COLLECTOR" | base64 | tr -d '\n')

collect() {  # host port outfile -> writes signal block, echoes round-trip ms
  local t0 t1
  t0=$(python3 -c 'import time;print(int(time.time()*1000))')
  run_ssh "$1" "$2" "echo $B64 | base64 -d | bash" >"$3" 2>&1 || true
  t1=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo $(( t1 - t0 ))
}

# Absolute honeypot tells, judged per machine from its signal block. Heuristics, not proof.
tells() {  # block-file machine-label
  local f=$1 m=$2 v
  v() { grep -m1 "^$1: " "$f" | cut -d' ' -f2- || true; }
  num() { local n; n=$(v "$1"); [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo ""; }
  [ "$(v dockerenv)" = yes ] && echo "  [$m] /.dockerenv present — running in a container"
  case "$(v cgroup1)" in *docker*|*lxc*|*kubepods*) echo "  [$m] cgroup path names a container runtime" ;; esac
  [ "$(num overlay_mounts)" ] && [ "$(num overlay_mounts)" -gt 0 ] && echo "  [$m] overlay rootfs — a container image, not a real disk"
  case "$(v virt)" in ""|none) : ;; *) echo "  [$m] virtualization detected: $(v virt)" ;; esac
  local u; u=$(num uptime_s); [ "$u" ] && [ "$u" -lt 1800 ] && echo "  [$m] uptime ${u}s — freshly booted (decoys are reset often)"
  local h; h=$(num root_history); [ "$h" ] && [ "$h" -lt 5 ] && echo "  [$m] root .bash_history has $h lines — no real use"
  local e; e=$(num entropy); [ "$e" ] && [ "$e" -lt 256 ] && echo "  [$m] low entropy_avail ($e) — little real I/O"
  local p; p=$(num proc_count); [ "$p" ] && [ "$p" -lt 15 ] && echo "  [$m] only $p processes running — bare system"
  local k; k=$(num packages); [ "$k" ] && [ "$k" -lt 150 ] && echo "  [$m] sparse package set ($k installed) — minimal image"
  local mo; mo=$(v monitoring); [ -n "$mo" ] && echo "  [$m] monitoring agent(s) present: $mo"
  local a; a=$(num audit_rules); [ "$a" ] && [ "$a" -gt 0 ] && echo "  [$m] auditd rules loaded — the box is watching"
  local l; l=$(num logins_seen); [ "$l" ] && [ "$l" -lt 2 ] && echo "  [$m] almost no login history ($l)"
  local md; md=$(num modules); [ "$md" ] && [ "$md" -lt 5 ] && echo "  [$m] $md kernel modules — unusually bare (containers share the host kernel)"
  return 0
}

# Pull selected, non-volatile fields from a Docker API JSON object, one "key: value" per line.
api_fields() {  # path host port field...
  local path=$1 host=$2 port=$3; shift 3
  run_api "$host" "$port" "$path" 2>/dev/null | python3 -I -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for k in sys.argv[1:]:
    v = d.get(k)
    print(f"{k}: {v}")
' "$@" 2>/dev/null || true
}

{
  echo "================================================================"
  echo "fingerprint  [$(stamp)]"
  echo "  A = $A_HOST  ssh:$A_SSH  api:$A_API"
  echo "  B = $B_HOST  ssh:$B_SSH  api:$B_API"
  echo "================================================================"

  a_ms=$(collect "$A_HOST" "$A_SSH" "$WORK/a.txt")
  b_ms=$(collect "$B_HOST" "$B_SSH" "$WORK/b.txt")
  echo
  echo "## SSH latency (whole collector round trip)"
  echo "  A ${a_ms} ms   B ${b_ms} ms   (uniform, suspiciously low, or very different timing is itself a tell)"

  echo
  echo "## SIGNALS — lines that differ between A and B"
  if diff_out=$(diff --label A "$WORK/a.txt" --label B "$WORK/b.txt" -u); then
    echo "  (none — A and B look identical on every signal)"
  else
    printf '%s\n' "$diff_out" | sed '1,2d'
  fi

  echo
  echo "## DOCKER API — /version and /info"
  for ep in "version /version Version ApiVersion GitCommit GoVersion Os Arch KernelVersion BuildTime" \
            "info /info Name ServerVersion OperatingSystem OSType KernelVersion Architecture NCPU MemTotal Containers ContainersRunning Images Driver CgroupDriver SecurityOptions"; do
    read -r name path fields <<<"$ep"
    # shellcheck disable=SC2086
    api_fields "$path" "$A_HOST" "$A_API" $fields >"$WORK/a_$name.txt"
    # shellcheck disable=SC2086
    api_fields "$path" "$B_HOST" "$B_API" $fields >"$WORK/b_$name.txt"
    if [ ! -s "$WORK/a_$name.txt" ] && [ ! -s "$WORK/b_$name.txt" ]; then
      echo "  $path: no response from either API"; continue
    fi
    if d=$(diff --label "A $path" "$WORK/a_$name.txt" --label "B $path" "$WORK/b_$name.txt" -u); then
      echo "  $path: identical"
    else
      printf '%s\n' "$d" | sed '1,2d'
    fi
  done

  echo
  echo "## TELLS — absolute honeypot indicators per machine"
  t=$( tells "$WORK/a.txt" A; tells "$WORK/b.txt" B )
  if [ -n "$t" ]; then printf '%s\n' "$t"; else echo "  (none flagged)"; fi
  echo
} | tee -a "$LOG"
