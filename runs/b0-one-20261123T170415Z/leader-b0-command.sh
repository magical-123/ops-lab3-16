#!/usr/bin/env bash
set -euo pipefail
umask 022
export PATH=/usr/local/go/bin:$PATH
export LC_ALL=C
cd /srv/lab3
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
name="b0-one-$(date -u +%Y%m%dT%H%M%SZ)"
dir="runs/$name"
[[ ! -e $dir ]]
if systemctl list-units --type=service --state=running --plain --no-legend 'lab3-*' | grep -q .; then
  echo 'Existing Lab3 experiment services are running; refusing to interrupt.' >&2
  exit 1
fi
for port in 8080 8081 8090 8091 8101; do
  [[ -z $(ss -H -lnt "sport = :$port") ]] || { echo "Port $port is occupied." >&2; exit 1; }
done
systemctl is-active --quiet opslab3-prometheus opslab3-node-exporter
preflight=$(mktemp /tmp/lab3-b0-preflight.XXXXXX)
{
  printf 'Prepared UTC: '; date -u --iso-8601=seconds
  printf 'Source commit: '; git rev-parse HEAD
  printf 'Guide B0: one instance, CPUQuota=25%%, AllowedCPUs=1, MemoryMax=128M, MemorySwapMax=0.\n'
  printf 'Control side: CPU0. Default enrolld args: -warmup 60s -work 1000000.\n'
  printf 'Plan: 20,40,60,80,100 requests/s, each 20s, GET /api/courses/1 through lbd.\n'
  printf 'Select largest zero-error stage before the first error stage; if no errors, extend probing.\n'
  printf 'C=0.7*observed upper; P=4*C rounded down to a multiple of 10; baseline=P/10.\n'
} > "$preflight"
cleanup() {
  systemctl stop lab3-b0-scaler >/dev/null 2>&1 || true
  systemctl stop lab3-b0-lbd >/dev/null 2>&1 || true
}
trap cleanup EXIT
systemd-run --quiet --collect --unit=lab3-b0-lbd --service-type=exec \
  --working-directory=/srv/lab3 --property=CPUAffinity=0 --property=UMask=0022 \
  /srv/lab3/bin/lbd
curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:8090/config >/dev/null
systemd-run --quiet --collect --unit=lab3-b0-scaler --service-type=exec \
  --working-directory=/srv/lab3 --property=CPUAffinity=0 --property=UMask=0022 \
  /srv/lab3/bin/scaler -mode fixed -replicas 1 -cpus 1
printf 'B0 name: %s; waiting for the single instance to warm up.\n' "$name"
ready=0
for attempt in {1..160}; do
  if curl -fsS http://127.0.0.1:8090/backends 2>/dev/null | jq -e 'length == 1 and .[0].up == true' >/dev/null; then
    ready=1
    break
  fi
  if (( attempt % 30 == 0 )); then printf 'Waiting for readiness: %ss\n' "$attempt"; fi
  sleep 1
done
[[ $ready == 1 ]] || { journalctl -u lab3-b0-scaler --no-pager -n 50; echo 'Readiness timeout.' >&2; exit 1; }
printf 'Single instance ready; beginning the guide B0 stages.\n'
GEN_CPUS=0 scripts/run3.sh "$name" -url http://127.0.0.1:8080/api/courses/1 -rates 20,40,60,80,100 -step 20s
cp "$preflight" "$dir/preflight.txt"
cp /tmp/lab3-leader-b0.sh "$dir/leader-b0-command.sh"
curl -fsS http://127.0.0.1:8101/config > "$dir/instance-config.json"
systemctl show lab3-inst-8101 -p CPUQuotaPerSecUSec -p AllowedCPUs -p MemoryMax -p MemorySwapMax -p ActiveState > "$dir/instance-cgroup.txt"
journalctl -u lab3-b0-lbd --no-pager -o cat > "$dir/lbd-journal.txt"
journalctl -u lab3-b0-scaler --no-pager -o cat > "$dir/scaler-journal.txt"
cleanup
trap - EXIT
systemctl list-units --type=service --state=running --plain --no-legend 'lab3-*' > "$dir/services-after.txt"
[[ ! -s "$dir/services-after.txt" ]] || { echo 'Lab3 experiment services remain; inspect before handoff.' >&2; exit 1; }
(cd "$dir"; find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
printf 'B0 completed and experiment services stopped: %s\n' "$dir"
scripts/table.sh "$dir" ok_rps error_rate p99_ms
