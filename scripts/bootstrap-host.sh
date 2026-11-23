#!/usr/bin/env bash
# Run as root on the NEW, dedicated Ubuntu 24.04 ECS after reviewing this file.
# Installs the Lab3 environment and monitors only; does not run A/B/C/D or B0.
set -euo pipefail
umask 022
export LC_ALL=C

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run as root (sudo bash lab3-bootstrap.sh).'
[[ $(uname -m) == x86_64 ]] || die 'This bootstrap is for x86_64.'
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'Expected Ubuntu 24.04.'
[[ $(cat /proc/1/comm) == systemd ]] || die 'PID 1 must be systemd.'
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || die 'cgroup v2 required.'
for controller in cpu memory cpuset; do
  grep -qw "$controller" /sys/fs/cgroup/cgroup.controllers || die "Missing cgroup controller: $controller"
done
cpu_count=$(getconf _NPROCESSORS_ONLN)
case "$cpu_count" in
  2) control_cpus=0; instance_cpu=1 ;;
  4) control_cpus='0 1'; instance_cpu=2 ;;
  *)
    if (( cpu_count >= 8 )); then control_cpus='0 1 2 3'; instance_cpu=4
    else die 'Use 2, 4, or at least 8 vCPUs, matching the Lab3 CPU layout.'; fi
    ;;
esac
mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
(( mem_kib >= 3500000 )) || die 'Expected a 4 GiB VM (allowing for kernel reservations).'

repo=/srv/lab3
repo_url=https://github.com/magical-123/ops-lab3-16.git
go_version=1.27.4
go_sha256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840
go_archive=''
trap '[[ -z "$go_archive" ]] || rm -f -- "$go_archive"' EXIT

go_usable() {
  local output major minor
  output=$("$1" version) || return 1
  [[ $output =~ go([0-9]+)\.([0-9]+)(\.[0-9]+)?[[:space:]] ]] || return 1
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
  (( major > 1 || (major == 1 && minor >= 26) ))
}

# Refuse to replace an existing Go installation.
if [[ -e /usr/local/go ]]; then
  [[ -x /usr/local/go/bin/go ]] && go_usable /usr/local/go/bin/go || die 'Existing /usr/local/go is not a usable Go >=1.26; review it manually.'
  export PATH="/usr/local/go/bin:$PATH"
elif command -v go >/dev/null; then
  go_usable "$(command -v go)" || die 'Existing Go is older than 1.26; review it manually.'
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential git curl ca-certificates sysstat jq python3 iproute2 procps util-linux

if ! command -v go >/dev/null; then
  go_archive=$(mktemp /tmp/lab3-go.XXXXXX.tar.gz)
  curl -fL --retry 3 --connect-timeout 20 -o "$go_archive" "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz"
  printf '%s  %s\n' "$go_sha256" "$go_archive" | sha256sum -c -
  [[ ! -e /usr/local/go ]] || die '/usr/local/go appeared during installation; refusing to overwrite.'
  tar -xzf "$go_archive" -C /usr/local
  export PATH="/usr/local/go/bin:$PATH"
fi
go_usable "$(command -v go)" || die 'Go >=1.26 is required.'
if [[ $(command -v go) == /usr/local/go/bin/go ]]; then
  profile=/etc/profile.d/lab3-go.sh
  expected_profile='export PATH=/usr/local/go/bin:$PATH'
  if [[ -e $profile ]]; then
    [[ $(cat "$profile") == "$expected_profile" ]] || die "$profile already has different content."
  else
    printf '%s\n' "$expected_profile" > "$profile"
    chmod 644 "$profile"
  fi
  # Also make the tools available in non-login SSH commands.
  for tool in go gofmt; do
    if [[ ! -e /usr/local/bin/$tool && ! -L /usr/local/bin/$tool ]]; then
      ln -s "/usr/local/go/bin/$tool" "/usr/local/bin/$tool"
    fi
  done
fi
export GOTOOLCHAIN=local

if [[ -e $repo ]]; then
  [[ -d $repo/.git ]] || die "$repo exists but is not a Git checkout."
  [[ $(git -C "$repo" remote get-url origin) == "$repo_url" ]] || die "$repo has a different origin."
  [[ -z $(git -C "$repo" status --porcelain) ]] || die "$repo has uncommitted work; review it first."
  # Deliberately do not pull, reset, switch branches, or overwrite existing work.
else
  git clone --branch main --single-branch "$repo_url" "$repo"
fi
cd "$repo"
[[ $(git branch --show-current) == main ]] || die 'Expected the repository main branch.'
mkdir -p runs data
evidence="runs/setup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir "$evidence"
printf '%s\n' "$(git rev-parse HEAD)" > "$evidence/source-commit.txt"
make build test fmt-check vet 2>&1 | tee "$evidence/build-test.log"
bash scripts/get-tools.sh 2>&1 | tee "$evidence/get-tools.log"
tools/prometheus-3.13.4.linux-amd64/promtool check config deploy/prometheus.yml > "$evidence/promtool-check.log" 2>&1
if [[ ! -e data/targets.json ]]; then printf '[]\n' > data/targets.json; fi

# One unprivileged account for the two monitoring daemons. No SSH credential.
monitor_user=lab3-monitor
if ! getent passwd "$monitor_user" >/dev/null; then
  useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$monitor_user"
fi
[[ $(id -u "$monitor_user") -lt 1000 ]] || die 'lab3-monitor already exists as a regular login user.'
[[ $(getent passwd "$monitor_user" | cut -d: -f7) == /usr/sbin/nologin ]] || die 'lab3-monitor has an unexpected login shell.'

# Match the guide: Prometheus data in tmpfs avoids monitor disk I/O in experiments.
# On reboot ExecStartPre recreates this directory as the service account.
if [[ -e /dev/shm/lab3-prom ]]; then
  [[ -d /dev/shm/lab3-prom && $(stat -c %U /dev/shm/lab3-prom) == "$monitor_user" ]] || die 'Existing /dev/shm/lab3-prom has an unexpected owner/type.'
else
  install -d -m 0750 -o "$monitor_user" -g "$monitor_user" /dev/shm/lab3-prom
fi

# Names intentionally do NOT start with lab3-: scripts/cleanup.sh stops lab3-*.
cat > "$evidence/opslab3-prometheus.service" <<EOF
[Unit]
Description=Lab3 Prometheus (loopback, tmpfs)
After=network.target

[Service]
User=$monitor_user
Group=$monitor_user
WorkingDirectory=$repo
CPUAffinity=$control_cpus
ExecStartPre=/usr/bin/mkdir -p /dev/shm/lab3-prom
ExecStart=$repo/tools/prometheus --config.file=$repo/deploy/prometheus.yml --storage.tsdb.path=/dev/shm/lab3-prom --web.listen-address=127.0.0.1:9090
Restart=on-failure
RestartSec=3s
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
cat > "$evidence/opslab3-node-exporter.service" <<EOF
[Unit]
Description=Lab3 node_exporter (loopback)
After=network.target

[Service]
User=$monitor_user
Group=$monitor_user
WorkingDirectory=$repo
CPUAffinity=$control_cpus
ExecStart=$repo/tools/node_exporter --web.listen-address=127.0.0.1:9100
Restart=on-failure
RestartSec=3s
UMask=0027

[Install]
WantedBy=multi-user.target
EOF

# Check BOTH files before installing either one. Existing different services need review.
for unit in opslab3-prometheus.service opslab3-node-exporter.service; do
  target="/etc/systemd/system/$unit"
  if [[ -e $target || -L $target ]]; then
    cmp -s "$evidence/$unit" "$target" || die "$target already has different content."
  fi
done
for unit in opslab3-prometheus.service opslab3-node-exporter.service; do
  target="/etc/systemd/system/$unit"
  [[ -e $target ]] || install -m 0644 "$evidence/$unit" "$target"
done
systemctl daemon-reload
systemctl enable --now opslab3-prometheus.service opslab3-node-exporter.service

curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:9090/-/ready > "$evidence/prometheus-ready.txt"
curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:9100/metrics -o /dev/null
# One scrape cycle is sufficient; don't start application workloads to make their targets green.
for attempt in {1..12}; do
  curl -fsS http://127.0.0.1:9090/api/v1/targets > "$evidence/targets.json"
  if jq -e '.status == "success" and any(.data.activeTargets[]; .labels.job == "node" and .health == "up")' "$evidence/targets.json" >/dev/null; then break; fi
  (( attempt < 12 )) || die 'node_exporter was not UP in Prometheus after 12 checks.'
  sleep 1
done

# Verify the monitoring sockets are loopback-only. Do not save the host SSH/public IP.
python3 - <<'PY'
import subprocess
lines = subprocess.check_output(["ss", "-H", "-lnt"], text=True).splitlines()
for port in (9090, 9100):
    addresses = [line.split()[3] for line in lines if line.split()[3].rsplit(":", 1)[-1] == str(port)]
    if addresses != [f"127.0.0.1:{port}"]:
        raise SystemExit(f"Port {port} must listen only on IPv4 loopback: {addresses}")
PY

{
  printf 'Collected UTC: '; date -u --iso-8601=seconds
  printf '\nSource commit: '; git rev-parse HEAD
  printf '\nOS:\n'; cat /etc/os-release
  printf '\nKernel:\n'; uname -r
  printf '\nSystemd:\n'; systemctl --version | sed -n '1p'
  printf '\nCPU:\n'; lscpu
  printf '\nMemory:\n'; free -m
  printf '\nSwap:\n'; swapon --show
  printf '\nCgroup filesystem:\n'; stat -fc %T /sys/fs/cgroup
  printf '\nControllers:\n'; cat /sys/fs/cgroup/cgroup.controllers
  printf '\nTools:\n'; go version
  tools/prometheus --version 2>&1 | sed -n '1p'
  tools/node_exporter --version 2>&1 | sed -n '1p'
  printf '\nLab3 control CPUs: %s\nLab3 scaler instance CPU: %s\n' "$control_cpus" "$instance_cpu"
  printf 'Task A must follow its own affinity instructions; no global GOMAXPROCS or CPU restrictions were added.\n'
  printf 'Prometheus data: /dev/shm/lab3-prom (lost on reboot; export results before deleting/rebooting).\n'
  printf 'Application targets are DOWN until their respective experiments start.\n'
  printf '\nMonitoring units:\n'
  systemctl show opslab3-prometheus.service opslab3-node-exporter.service -p Id -p ActiveState -p SubState -p CPUAffinity -p MainPID
} > "$evidence/environment.txt"
( cd "$evidence"; sha256sum build-test.log get-tools.log promtool-check.log source-commit.txt targets.json environment.txt *.service > SHA256SUMS )
printf '\nEnvironment ready. Evidence: %s/%s\n' "$repo" "$evidence"
printf 'Next: review LAB3.md section 1, then run B0 separately. No formal experiment was run.\n'
