# Cloudflare WARP + OpenCode 官方 CLI 多节点实测与结论

记录日期：2026-11-01  
验证仓库：https://github.com/2061969365/zen-warp-cli  
Action 运行记录：https://github.com/2061969365/zen-warp-cli/actions/runs/41291922205

---

## 一、方案背景与配置

复用 `2061969365/dump`（Katabump Auto Renew）中的 Cloudflare WARP 方案：
- Action：`fscarmen/warp-on-actions@v1.3`
- 参数：`mode: client`, `stack: dual`（官方 `cloudflare-warp` 客户端，注册新账号，启用 `warp+doh` 虚拟 TUN 网卡）
- 关键 DNS 修复：停止 `systemd-resolved`，强制写入 `1.1.1.1`、`8.8.8.8`
- 模型：官方 CLI `@opencode/cli@latest` 调用 `deepseek-v4.1-flash-free`

---

## 二、测试结果矩阵（6 个独立 Runner）

| Shard | 原始 Runner IP (Azure) | WARP IPv4 (Anycast) | WARP IPv6 | Cloudflare 节点 | Turn 1 | Turn 2 | Turn 3 (重连后) |
|---|---|---|---|---|---|---|---|
| **Shard 1** | 4.236.92.226 | 104.28.205.117 | `2a09:bac5:6194:2da5::48c:2b` | LAX (洛杉矶) | 429 | 429 | 429 |
| **Shard 2** | 20.171.51.210 | 104.28.205.117 | `2a09:bac5:6193:2da5::48c:63` | LAX (洛杉矶) | **200** | **200** | **200** |
| **Shard 3** | 20.84.158.51 | 104.28.216.161 | `2a09:bac1:7680:260::48:86` | MSP (明尼阿波利斯) | **200** | **200** | **200** |
| **Shard 4** | 172.171.125.20 | 104.28.201.162 | `2a09:bac5:cbba:1d37::2e9:31` | SEA (西雅图) | 429 | 429 | 429 |
| **Shard 5** | 64.236.177.1 | 104.28.227.110 | `2a09:bac5:7977:8c::e:36e` | ORD (芝加哥) | 429 | 429 | 429 |
| **Shard 6** | 20.83.175.224 | 104.28.196.79 | `2a09:bac1:7681:62b0::39d:5f` | IAD (华盛顿特区) | 429 | 429 | 429 |

### 真实返回内容（Shard 2 & Shard 3）
- **Shard 2 Turn 1**：`我是一名 AI 编程助手，可以帮你阅读代码、编写和修改文件、运行命令、排查问题，以及完成其他软件开发任务。`
- **Shard 2 Turn 2**：`我是一名 AI 编程助手`
- **Shard 2 Turn 3（断开并重连 WARP 后）**：`正常`
- **Shard 3 Turn 1**：`我是 OpenCode 编码助手，可以阅读和修改代码、运行命令、排查问题，并帮你完成代码库中的开发任务。`
- **Shard 3 Turn 3（断开并重连 WARP 后）**：`正常`

---

## 三、WARP 与 VPNGate 对比分析

| 维度 | VPNGate (OpenVPN / sing-box) | Cloudflare WARP (dump 方案) |
|---|---|---|
| **网络连通率** | 较低（44% 遇到 `ECONNREFUSED`，被上游防火墙直接阻断） | **100% 畅通**（0 次 `ECONNREFUSED`，网络层极为干净稳定） |
| **部署与维护** | 复杂（需定时抓取/转换 CSV、筛选存活、启动多个 sing-box 进程） | **极简**（`fscarmen/warp-on-actions` 一键 TUN 双栈） |
| **IP 纯净度 / 200 成功率** | 13 / 86 ≈ 15.1% | 2 / 6 ≈ 33.3% |
| **IPv6 支持** | 绝大多数节点为纯 IPv4 | **原生支持双栈**，OpenCode 优先走 IPv6，不同 Runner 分配到不同 IPv6 子网 |
| **重连换 IP 能力** | 需切换不同 OpenVPN 服务端节点 | `warp-cli disconnect && warp-cli connect` 秒级重连 |

---

## 四、工程落地方案

针对 `zen-console` / `zen-gateway-runner` 的出口策略建议：
1. **优先接入 WARP 双栈出口**：相比 VPNGate，WARP 免除了大量的坏节点重试与上游拒连（RST）问题。
2. **结合 IPv6 子网轮换**：OpenCode 对 WARP 的风控是基于 IPv6 子网/IP 维度的。在遭遇 429 时，执行 `warp-cli disconnect && warp-cli connect`，或轮换 WARP WireGuard 虚拟网卡接口，即可快速切换到可用的 200 出口。
