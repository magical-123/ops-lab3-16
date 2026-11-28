# o6-two-host

## 80 请求/秒阶段

| 指标 | 结果 |
|---|---:|
| 发出 / 成功 | 4743 / 4743 |
| 错误 | 0 |
| 成功请求/秒 | 79.0 |
| p50 / p99 | 5.25 / 19.30 ms |
| 最大延迟 | 55.24 ms |
| SLO 达标率 | 99.96% |
| 发送滞后 p99 | 1.06 ms |

## 全程

| 指标 | 结果 |
|---|---:|
| 发出 / 成功 | 8528 / 8528 |
| 错误 | 0 |
| p50 / p99 | 5.23 / 11.70 ms |
| SLO 达标率 | 99.98% |

原始数据见 `steps.csv`、`timeline.csv` 和 `loadgen.log`。B 上的负载均衡器日志与指标见 `lbd-journal.txt` 和 `lbd-metrics-end.txt`。A 上的后端日志、指标和资源快照见 `backend-journal.txt`、`backend-metrics-end.txt`、`backend-unit.txt` 与 `backend-cgroup-end.txt`。
