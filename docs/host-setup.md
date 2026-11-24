# Lab3 主机使用说明

## 环境与连接

- 仓库目录：`/srv/lab3`。
- 主机：2 vCPU、4 GB 内存，Ubuntu 24.04。
- 组长使用 `root`，四位组员使用独立普通账号 `lab3_m1`～`lab3_m4`，均只接受公钥认证。已复用组长先前收齐的四把公钥，编号沿用原 `lab2_m1`～`lab2_m4`，不代表本次 A/B/C/D 分工。
- 组员个人工作副本为 `~/lab3`，可编辑、编译和分析；`/srv/lab3` 是组长管理的正式部署目录，组员只读。组员没有 sudo 权限，正式 systemd/cgroup 操作和完整采集脚本仍由组长统一执行。
- 公网仅开放 SSH 22。业务、管理和监控端口均监听 `127.0.0.1`，不需要为实验开放公网端口。
- 组长已完成 B0；统一参数、原始数据及可复制的群通知见 [阶段交接说明](leader-handoff.md)。A/B/C/D 的正式任务由对应组员继续完成。

新主机的初始化脚本见 `scripts/bootstrap-host.sh`，适用于专用的 Ubuntu 24.04 x86_64 主机：`sudo bash scripts/bootstrap-host.sh`。已配置好的主机无需再次执行。脚本只准备工具和监控，不运行正式实验；若云端 GitHub 下载慢，可将校验值匹配的官方安装包先放入 `/srv/lab3/tools/`。

### 组员如何连接

| 原 Lab2 账号 | 新 Lab3 账号 |
| --- | --- |
| `lab2_m1` | `lab3_m1` |
| `lab2_m2` | `lab3_m2` |
| `lab2_m3` | `lab3_m3` |
| `lab2_m4` | `lab3_m4` |

组长私下提供公网 IP 和主机指纹。每人在自己电脑的 PowerShell 执行，将账号和公网 IP 换成自己的值：

```powershell
ssh -o IdentitiesOnly=yes -i "$env:USERPROFILE\.ssh\id_ed25519" lab3_m1@<公网IP>
```

`-i` 指向生成本人公钥时对应的私钥；私钥文件名若为 `id_ed25519_github`，就修改该路径。接收的 `.pub` 文件名中的 `(1)` 是传输重命名，不决定私钥名称；登录时选择不带 `.pub` 的文件。私钥继续留在本人电脑。

首次连接核对组长提供的主机指纹，登录后执行：

```bash
whoami
cd ~/lab3
git status --short --branch
```

服务端已核对四个账号的公钥、文件权限、密钥认证策略及目录权限；每位成员仍需用自己的私钥完成一次真实登录并反馈组长。个人副本已准备当前代码、二进制和数据目录；`tools/` 只读复用已安装工具，无需重复安装工具或启动监控。GitHub 身份和提交认证由各成员自行配置，服务器登录不会自动获得 GitHub 推送身份。

## 监控服务

监控已配置为 systemd 服务并开机自启，均绑定 CPU0：

| 服务 | 监听地址 | 数据目录 |
| --- | --- | --- |
| `opslab3-prometheus` | `127.0.0.1:9090` | `/dev/shm/lab3-prom` |
| `opslab3-node-exporter` | `127.0.0.1:9100` | — |

无需重复执行指导书中启动 node_exporter 和 Prometheus 的两条命令，以免端口冲突。以下命令在主机上运行；停止、启动由组长统一操作：

```bash
systemctl status opslab3-prometheus opslab3-node-exporter --no-pager
sudo systemctl stop opslab3-prometheus opslab3-node-exporter
sudo systemctl start opslab3-node-exporter opslab3-prometheus
```

在本机终端建立 SSH 隧道，并保持该终端运行：

```bash
ssh -N -L 19090:127.0.0.1:9090 <用户名>@<公网IP>
```

然后在本机浏览器打开 <http://127.0.0.1:19090> 查看 Prometheus。

## 实验与协作

- 正式压测串行执行，一次只安排一位负责人。结束后保存数据，并说明遗留服务、配置及恢复情况，再交接主机。
- `sudo`、systemd、cgroup、端口和基础环境修改由组长统一操作。组员提前准备实验命令、参数和预测。
- 任务 B/C/D：loadgen、lbd、scaler 和监控使用 CPU0；所有 scaler 实例共同使用 CPU1，每实例配额按指导书设置。
- 任务 A 按对应步骤单独设置配额和亲和，不套用上述实例统一绑核规则；尤其 A2 允许实例使用两个核，以观察配额与并行执行的关系。
- 未额外设置全局 `GOMAXPROCS`；需要对照修改时，仅按对应实验设置。
- 启动新的 scaler 会清理旧实例，不要在他人实验期间另起 scaler。运行前先确认当前实验已交接。

## 关机与恢复

关机或重启前结束实验，将需要的 Prometheus 查询结果导出到 `/srv/lab3/runs/<本次运行目录>/`，保存原始数据和报告，并备份必要文件。

`/dev/shm/lab3-prom` 属于内存文件系统，关机或重启后其中的监控历史会丢失。开机自启只会恢复监控进程，不会恢复这些历史数据。

重新实验时，先检查监控状态，再按对应任务重新启动业务服务、lbd/scaler 或任务 A 单元，恢复参数和 CPU 配置，确认实例健康、预热完成后再加压。现场检查结束前保留 ECS、`bin/`、`tools/`、配置和实验数据。
