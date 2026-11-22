# Aran — 设计文档

一个自用的代理调度器。**不实现代理**：TUN、DNS、协议全部由 mihomo 提供，Aran 只做一件事——
**替 mihomo 决定「这个组现在该用哪个节点」，并且让这个决定可读、可查、可解释。**

## 已锁定的决策

| # | 决策 | 结论 |
|---|---|---|
| 1 | 场景 | 翻墙；单用户自用；候选池不区分自建/机场 |
| 2 | 平台 | Linux 优先 → Windows → Android（Flutter 一套代码） |
| 3 | 内核 | mihomo（embedded/子进程），Aran 拥有其生命周期 |
| 4 | 全局代理 | TUN（root 服务），不是系统代理 |
| 5 | 作用范围 | 每个策略组内部自治，不改动规则与分组结构 |
| 6 | 决策权 | 组改写为 `select`，Aran 独占；**30s 心跳丢失则回落到内核 `url-test` 兜底** |
| 7 | 上线方式 | 先 `shadow`（只建议不执行），验证后再接管 |
| 8 | 探测 | 分层（当前 10s / 候选 60s / 其余 10min）+ 空闲降频 |
| 9 | 数据源 | 被动观测（`/connections` 字节数）为主，主动探测兜底 |
| 10 | 切换 | 连续 2 次失败=死亡立刻切；否则需领先 30%；切后冷却 5min（死亡切换豁免） |
| 11 | 评分 | `quality / multiplier^0.5`，质量=延迟+可靠性+稳定性+吞吐 加权 |
| 12 | 配置 | 订阅拉取 + 本地模板合并（Aran 生成 `proxy-groups`，节点来自订阅） |
| 13 | 同步 | 无。各设备独立 |
| 15 | 客户端形态 | Aran 拥有 mihomo 生命周期；配置由订阅生成；组改写为 `select` 后必须先校验初始选择 |
| 14 | UI | 诊断优先，零动效：状态 → 排行榜（含「为什么不是它」）→ 决策时间线 → 规则推演 → 热力图 |

## 平台差异：Android

上表是桌面（Linux/Windows）的形状。Android 上有几处结论不同，因为前提变了——详见
[docs/ANDROID.md](docs/ANDROID.md)。

| # | 桌面上 | Android 上 | 为什么 |
|---|---|---|---|
| 3 | mihomo 子进程，Aran 是父进程 | **进程内**（gomobile `libclash.so` + JNI） | TUN 的 fd 是进程局部的；mihomo 只接受 `tun.file-descriptor`，没有 SCM_RIGHTS 收 fd 的通道 |
| 4 | TUN 靠 root 特权（CAP_NET_ADMIN） | `VpnService`，**不需要 root**；路由/DNS 由 Kotlin 的 `Builder` 配 | Android 的 TUN 不是权限问题，是框架能力 |
| 6 | 30s 心跳丢失 → 回落 `url-test` | 进程消失或 **5 分钟**无心跳 → PUT 一次 `aran-fallback` 组 | Doze 下 30s 静默是常态而非异常 |
| 8/9 | 分层探测 10s/60s/10min，实际是主动探测为主 | 灭屏或无真实流量时只留当前节点 5 分钟心跳，**被动观测为主** | 桌面上 CPU 是免费的，手机上一次探测就是一次无线电唤醒 |

其余决策在两端一致：组改写为 `select`、Aran 独占、评分与阈值不分叉、配置由订阅生成。

## 分层

```
core/                 纯 Dart，无平台依赖，可被 Flutter 直接复用
  api.dart            mihomo REST 客户端（/proxies, /connections, /proxies/{n}/delay）
  model.dart          节点状态、探测结果、决策记录
  prober.dart         分层探测调度器（预算控制、空闲降频、限流）
  score.dart          评分函数（可解释，逐项输出）
  decide.dart         决策引擎（判死、阈值、冷却、审计）
  store.dart          JSONL 审计日志 + 状态持久化
bin/shadow.dart       旁观模式 CLI：只建议，不 PUT
```

后续：
```
service/              root 特权服务（起 mihomo + TUN + 心跳看门狗）
app/                  Flutter UI（复用 core/）
app/android/          Android 平台层（VpnService + libclash.so，内核在进程内；见 docs/ANDROID.md）
```

## 评分（全部可解释）

```
L 延迟分     100 * clamp((600-delay)/500, 0..1)
R 可靠性     100 * (1 - 最近 20 次探测失败率)          ← 权重最高，对应「节点会挂」
S 稳定性     100 * clamp(1 - 抖动/150, 0..1)
T 吞吐分     100 * clamp(log10(mbps+1)/log10(51), 0..1)  ← 仅来自真实流量

quality = 0.25L + 0.45R + 0.15S + 0.15T
final   = quality / multiplier^0.5
```

每条决策（包括**被否决的**）都会写进审计日志：
`切换` / `拒绝` / `判死`，附带当时的分数对比。

## 探测预算

- 当前节点 10s（死亡判定 2 连败 ≈ 20s 内发现）
- 候选前 3 名 60s
- 其余节点 600s，按名称散列错峰，避免同时打出去
- 无流量超过 180s → 空闲模式，只保留当前节点 60s 心跳
- 全局并发上限 6，避免探测本身成为负载

## 倍率

节点名里的 `x0.1` / `x2.0` 解析为计费倍率（缺省 1.0），作为分母进入评分。
面板上**分开显示质量分和倍率**，切换理由里写清「质量高 40% 但倍率 2.0，综合排第 3」。
