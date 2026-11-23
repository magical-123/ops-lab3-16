# Lab3 主机使用说明

## 环境与连接

- 仓库目录：`/srv/lab3`。
- 主机：2 vCPU、4 GB 内存，Ubuntu 24.04。
- 当前已配置组长的 `root` SSH 公钥登录，SSH 仅接受公钥认证；组员账号和公钥由组长另行登记，Lab2 的登录权限不会自动迁移。
- 公网仅开放 SSH 22。业务、管理和监控端口均监听 `127.0.0.1`，不需要为实验开放公网端口。
- 组长已完成 B0；统一参数、原始数据及可复制的群通知见 [阶段交接说明](leader-handoff.md)。A/B/C/D 的正式任务由对应组员继续完成。

新主机的初始化脚本见 `scripts/bootstrap-host.sh`，适用于专用的 Ubuntu 24.04 x86_64 主机：`sudo bash scripts/bootstrap-host.sh`。已配置好的主机无需再次执行。脚本只准备工具和监控，不运行正式实验；若云端 GitHub 下载慢，可将校验值匹配的官方安装包先放入 `/srv/lab3/tools/`。

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
