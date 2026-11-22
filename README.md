# Aran

自用的代理**调度器**。不做代理——TUN、DNS、协议全是 mihomo 的活。Aran 只负责
「这个组现在该用哪个节点」，并且把这个决定做成**看得懂、查得到、能解释**的东西。

设计决策见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 现状

Aran 是一个**能用的客户端**，不只是看板：

| 能力 | 说明 | 状态 |
|---|---|---|
| 内核生命周期 | 自己拉起/停止 mihomo，随机端口，pidfile 清理遗留进程，信号退出不留孤儿 | ✅ |
| 配置与订阅 | 从 URL 拉订阅（含 base64 订阅）、导入本地文件、更新、切换、删除 | ✅ |
| 配置生成 | 运行时改写：固定端口/控制器口令、移除 `tun:`、把 `url-test`/`fallback` 改成 `select` 交给 Aran | ✅ |
| 代理控制 | 全局开关、规则/全局/直连模式切换、策略组点击切节点、单组测速 | ✅ |
| 连接视图 | 实时连接（规则/目标/链路/上下行/时长），可单条断开 | ✅ |
| 日志 | 内核 stdout/stderr 实时，落盘 `kernel.log` | ✅ |
| 调度 | 分层探测、被动吞吐、可解释评分、判死/阈值/冷却、审计 | ✅ |
| TUN | 需要特权 helper（systemd + CAP_NET_ADMIN） | ⬜ |
| 看门狗 | Aran 崩溃后回落内核 `url-test` | ⬜ |
| Windows | 服务模式、注册表代理、wintun，见 [docs/WINDOWS.md](docs/WINDOWS.md) | ⬜ 未在真机验证 |
| Android | 设计已定（进程内 kernel + VpnService），见 [docs/ANDROID.md](docs/ANDROID.md) | ⬜ 未开工 |

## 跑起来

```bash
# 1. 起一个隔离的开发内核（用户态，不开 TUN，不碰你现有客户端）
scripts/dev-core.sh start

# 2. 旁观模式：只看它怎么想，不写任何东西
cd core
dart run bin/shadow.dart --print-every 10
```

输出示例（真实数据）：

```
  cur  🇲🇾 马来西亚01[D专线]x2.0  x2.0  delay=83ms   L78 R100 S96 T50 -> 58.8
  best 🇭🇰 香港07[D阿里专线]      x1.0  delay=79ms   L80 R100 S100 T50 -> 84.6
       . 🇨🇳 台湾07[D阿里专线]      x1.0  delay=99ms   L70 R100 S100 T50 -> 80.6
  =>   HOLD  🇭🇰 香港07[D阿里专线] 领先 43.9%（达阈值），但冷却中，还剩 173s
  pool=80 usable=72 probed=80 probes=81/8fail idle=true active=0 traffic=0.0MB
```

注意 `cur` 的分很低：那是订阅里 `url-test` 组自己挑的节点——83ms 但**双倍计费**；
Aran 选的是 79ms 单倍计的节点，并在面板上说明为什么。

## 参数

```
--addr 127.0.0.1:9090     mihomo 控制器地址
--secret aran-dev
--group  "trumpyun - 特朗普云"   要接管的策略组
--auto-group "自动选择"          当前实现选择所在的组
--threshold 1.30          切换所需领先幅度
--cooldown-min 5          切换冷却
--print-every 10          状态行间隔（秒）
--takeover                真的 PUT（默认只建议）
--audit <path>            审计日志 JSONL
```

## 客户端部分的坑（都踩过）

1. **mihomo 只读 `<data-dir>/config.yaml`**：写成 `runtime.yaml` 会导致它用默认 7890 端口和默认配置启动，看起来「启动了但没生效」；
2. **空数据目录没有 geo 文件**：`Country.mmdb`/`geosite.dat` 缺失会让内核直接退出，需要从本机已有客户端软链；
3. **把 `url-test` 改成 `select` 之后没人选节点**：机场配置里常放 `Dont.use.this.node:8888` 这类占位节点在列表最前，`select` 默认选它 → 代理完全不通。启动时必须校验并初始化一个真实节点；
4. **应用被 SIGTERM 杀掉会遗留 mihomo**：子进程不会跟着退出，现在有 pidfile + 启动时清理 + 信号处理；
5. **合成鼠标事件在 Wayland/KWin 下不转发**：所以给了 `ARAN_PAGE=n` 环境变量用于直接打开某个页面（也方便截图和冒烟测试）。

## 被动观测的坑（已踩过）

`/connections` 只列**活着的**连接。按「节点字节总量做差分」会把两次采样之间结束的连接整段丢掉——
18 MB 的下载只统计到 0.3 MB。现在按**连接 id 逐条差分**，并且 GUI 用 200ms 采样（决策环仍是 1s）。
代价是连接关闭前最后一段（采样间隔内的尾巴）仍会丢，实测能抓到约 85% 的字节。

吞吐单位是 **MB/s**（曾经算成 Mbit/s，界面标 MB/s，差 8 倍）。

## 审计日志

每条决策都落盘，**包括被否决的**：

```
00:49:54 hold     🇭🇰 香港07 领先 43.9%（达阈值），但冷却中，还剩 173s
00:49:54 hold     🇨🇳 台湾07 仅领先 4.7%（阈值 30%），不切
00:49:54 dead     🇲🇾 马来西亚01 连续 2 次探测失败，判死；切到 🇭🇰 香港07
```

## 评分

```
L 延迟分   100 * log(500/delay) / log(10)       50ms=100, 500ms=0
R 可靠性   100 * (1 - 最近 20 次探测失败率)
S 稳定性   100 * clamp(1 - 抖动/150)
T 吞吐分   100 * log10(mbps+1)/log10(51)         只来自真实流量

quality = 0.40L + 0.30R + 0.15S + 0.15T
final   = quality * clamp(1/mult^0.5, 0.70, 1.20)
```

倍率修正**封顶**是刻意的：不封顶时，一个 259ms 的 `x0.1` 节点能靠倍率把 79ms 的
`x1.0` 节点压掉 3 倍分数——那正是「自动选择选得莫名其妙」的典型来源。
