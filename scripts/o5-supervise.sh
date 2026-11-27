#!/usr/bin/env bash
# O5（HAProxy 替换 lbd）的实例监督器：补上被停掉的 scaler 的两块职责——自动补建 + 维护 Prometheus 目标文件。
#
# 用法（在仓库根目录，需要 root）：
#   sudo scripts/o5-supervise.sh [端口...]
#   不带端口时默认 8101 8102 8103
#
# 功能：
#   1. 启动/补建：lab3-inst-<端口> 没在运行就 systemd-run 启动，参数与 scaler、task-o5.md 3.3 一致
#   2. 自动补建：常驻循环，发现实例退出（failed/inactive，如 inject.sh kill）就自动重启
#   3. 自动生成 data/targets.json：写进所有期望实例，Prometheus 的 file_sd（job=instances）据此抓取
#   4. Ctrl+C（SIGINT/SIGTERM）：停止所有期望实例、删除 targets.json 后退出
#
# 关于“挂起”：SIGSTOP 挂起（inject.sh pause）的实例进程仍在、systemd 单元仍是 active，
# 本脚本不会误判为退出而补建——挂起由 HAProxy 的健康检查超时发现。要挂起实例请用
#   sudo scripts/inject.sh pause <端口> <秒>
#
# 注意：补建后的实例有 -warmup 60s 预热，期间 /readyz 返回 503，HAProxy 会标 DOWN，属正常现象。
set -euo pipefail

DATA=${DATA:-data}
WARMUP=60     # 与 scaler / task-o5.md 一致的预热时长
POLL=2        # 检查实例状态的间隔（秒）

die() { echo "o5-supervise.sh：$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root：sudo scripts/o5-supervise.sh …"
[ -x bin/enrolld ] || die "请在仓库根目录运行，并先 make build（找不到 bin/enrolld）"

# 期望的实例端口：来自命令行，默认三个
ports=("$@")
if [ ${#ports[@]} -eq 0 ]; then ports=(8101 8102 8103); fi
for p in "${ports[@]}"; do
  [[ $p =~ ^[0-9]+$ ]] || die "端口应为数字：$p"
done

# 启动单个实例（参数与 scaler 启动的实例一致）
launch() {
  local p=$1
  systemctl reset-failed "lab3-inst-$p" 2>/dev/null || true
  rm -rf "$DATA/inst-$p"
  systemd-run --unit="lab3-inst-$p" --quiet \
    --property=CPUQuota=25% --property=MemoryMax=128M \
    --property=MemorySwapMax=0 --property=AllowedCPUs=1 \
    "$PWD/bin/enrolld" -addr "127.0.0.1:$p" -data "$PWD/data/inst-$p" \
    -version v1 -warmup "${WARMUP}s" -work 1000000
  echo "[$(date +%H:%M:%S)] 已启动 lab3-inst-$p（预热 ${WARMUP}s，期间 /readyz 为 503）"
}

# 实例是否在运行（SIGSTOP 挂起仍算 active，不会误补建）
active() { systemctl is-active --quiet "lab3-inst-$1"; }

# 写 Prometheus 的 file_sd 目标文件（格式与 scaler 的 writeTargets 一致）
write_targets() {
  local list=() p
  for p in "${ports[@]}"; do list+=("\"127.0.0.1:$p\""); done
  local joined
  joined=$(IFS=,; echo "${list[*]}")
  {
    echo '['
    echo '  {'
    echo "    \"targets\": [$joined],"
    echo '    "labels": {"group": "lab3"}'
    echo '  }'
    echo ']'
  } > "$DATA/targets.json"
  echo "[$(date +%H:%M:%S)] 已写 $DATA/targets.json：$joined"
}

cleanup() {
  echo
  echo "[$(date +%H:%M:%S)] 收到停止信号，清理实例…"
  local p
  for p in "${ports[@]}"; do
    systemctl kill --signal=SIGCONT "lab3-inst-$p" 2>/dev/null || true  # 若被挂起，先恢复
    systemctl stop "lab3-inst-$p" 2>/dev/null || true                    # 优雅停止（drain 2s）
    systemctl reset-failed "lab3-inst-$p" 2>/dev/null || true
  done
  rm -f "$DATA/targets.json"
  echo "已停止 ${ports[*]} 并删除 targets.json。"
  exit 0
}
trap cleanup INT TERM

# 初始：把缺的实例都起起来
for p in "${ports[@]}"; do
  active "$p" || launch "$p"
done
write_targets

echo "监督中：${ports[*]}，每 ${POLL}s 检查一次；Ctrl+C 停止实例并退出。"
while true; do
  sleep "$POLL"
  for p in "${ports[@]}"; do
    if ! active "$p"; then
      echo "[$(date +%H:%M:%S)] 检测到 lab3-inst-$p 退出，自动补建"
      launch "$p"
      write_targets
    fi
  done
done