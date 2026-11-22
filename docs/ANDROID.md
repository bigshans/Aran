# Android 支持

状态：**设计已定，未开工**（仓库里还没有 `app/android/`）。

这份文档记录的是截至设计评审结束时的结论。和 `docs/WINDOWS.md` 不同，这里写的大多还
**没有对应代码**；每完成一个里程碑就回来把这行状态和下面的表格改成实际值，不要重演
「代码就绪未验证」那种状态堆积。

## 为什么这不是「再加一个平台适配器」

桌面版的形状建立在一个假设上：**Aran 是 mihomo 的父进程**。`KernelManager` 分配端口、
写配置、`Process.start`、写 pidfile、吸 stdout、发信号停机。Android 上这个假设有三处
同时不成立：

1. **TUN 的 fd 是进程局部的。** mihomo 只接受 `tun.file-descriptor`（源码
   [`listener/config/tun.go`](https://github.com/MetaCubeX/mihomo/blob/Meta/listener/config/tun.go)，
   v1.15.0 起存在，未进官方文档）或 REST `PATCH /configs`，而这个值是**本进程的文件描述符编号**，
   mihomo 会拿它做 `ioctl(TUNGETIFF)`。父进程 `VpnService` 的 fd 号在子进程里指向别的东西。
   mihomo **没有** SCM_RIGHTS / unix socket 收 fd 的能力。所以内核只能跑在同一进程里
   （[ClashMetaForAndroid](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/master/service/src/main/java/com/github/kr328/clash/service/TunService.kt)、
   [FlClash](https://github.com/chen08209/FlClash/blob/main/android/service/src/main/java/com/follow/clash/service/VpnService.kt)
   都是这么做的）。
2. **`targetSdk >= 29` 后 `/data` 不可执行**（[W^X](https://developer.android.com/about/versions/10/behavior-changes-10)），
   `Bundled.extract` 把内核解到 `<data>/bin` 那套做法在 Android 上必然 EACCES。
3. **没有 systemd / sc.exe / sh / python。** `service_unit.dart` 生成的 unit、`watchdog.py`、
   `notify-send`、`exportDiagnostics` 里的 `systemctl` + `tar` 全部不适用。

再加上两条 Android 特有的事实：**没有全局系统代理**（只有 Wi-Fi 的 http proxy，一半 app 不认），
以及**没有「本机已有客户端」可以软链 geo 文件**（README 里第 2 个坑）。

## 已锁定的 Android 决策

| # | 问题 | 结论 |
|---|---|---|
| 1 | 内核集成 | gomobile 进程内 core（`libclash.so`），因为 fd 无法跨进程 |
| 2 | 进程归属 | Kotlin 前台 Service 持有 VPN 与内核；Dart 只做调度与 UI |
| 3 | 功能边界 | v1 = 桌面能力 + 全局 VPN；应用分流 v1.1；**规则编辑不做** |
| 4 | 生命周期 | 常驻通知；UI 退出 ≠ 断开；开机自启默认关；5 分钟内崩 3 次即停 |
| 5 | 文件布局 | 全部内部存储 + SAF 导入导出；geo 文件打包进 APK |
| 6 | UI | 五页保留 + 底部导航 + 排行榜卡片化；服务面板整块替换 |
| 7 | 打包 | release `arm64-v8a`，debug 加 `x86_64`；minSdk 26；keystore 在仓库外 |
| 8 | 验证 | ColorOS 16 真机，每步以「真机能全局代理」为验收线 |
| 9 | 控制面 | Dart 生成 `config.yaml` / 端口 / secret；Kotlin 哑执行 |
| 10 | 失联兜底 | 预置 `aran-fallback` 组；进程消失或 5 分钟无心跳 → PUT 一次 |
| 11 | CI | Android job 只做「编译 + 出 APK」，不做模拟器冒烟 |
| 12 | fd 交接 | `establish().detachFd()` → Go `startTun(fd)`；配置里 `tun:` 段照旧删掉 |
| 13 | 探测预算 | 灭屏/无流量只留当前节点 5 分钟心跳；否则 10s / 60s |
| 14 | 安静模式 | Dart 自我降频，跟随 Doze；不申请精确闹钟 |
| 15 | TUN stack | 默认 `system`，设置里可一键切 `gvisor` |
| 16 | 内核产物 | 自己写 Go 绑定 + CI `gomobile bind` |
| 17 | 顺序 | 垂直切片：先隧道出网 → 观察 → 调度 → UI → 兜底/导入/CI |
| 18 | DNS | `dns-hijack: any:53` + 内置 DNS；FakeIP 默认关 |
| 19 | 隔离纪律 | 共享代码只做增量；桌面代码「搬而不改」；桌面路径 diff 只允许纯 `+` |

## 架构

```
┌─────────────────── Android 进程 ───────────────────┐
│                                                    │
│  Dart (Flutter engine)         Kotlin              │
│  ├ app_state / engine     ←channel→  ├ VpnService  │
│  ├ prober / decide                   │ 前台服务    │
│  └ UI                                ├ 进程托管    │
│                                      │             │
│                            JNI ──────┘             │
│                             │                       │
│                    libclash.so (Go, mihomo)         │
└────────────────────────────────────────────────────┘
```

| 谁 | 负责 | 不负责 |
|---|---|---|
| Dart | 配置生成（`settings.dart` + `config_transform.dart`）、端口与 secret 分配、探测、评分、决策、审计、UI | 拉起内核、持有 fd、保活 |
| Kotlin Service | `startForeground`、`VpnService.Builder` 配置路由/DNS/MTU、`establish()`、JNI 调用、心跳守护（超时 PUT 一次）、进程/通知生命周期 | 任何调度判断 |
| libclash.so | mihomo 本体：TUN 收 fd、DNS 劫持、规则、连接 | 选择节点（组改写成 `select`） |

### 启动序列

1. Dart 生成 `config.yaml`（`tun:` 段照旧被 `config_transform.dart` 删掉，TUN 由 JNI 启动）
2. channel → `start(configPath, secret, ports)`
3. Kotlin：`startForeground()` → `VpnService.Builder` 配路由/DNS/MTU → `establish()` → `detachFd()`
4. JNI：`StartTun(fd, configPath)`，Go 侧把 fd 装进 `tun.file-descriptor` 并启动监听
5. Dart 连 `127.0.0.1:9090` + secret，正常跑 `prober` / `decide`
6. Dart 每 15s 通过 channel 打心跳；Service 超过 5 分钟没收到 → PUT 主组选中 `aran-fallback`

### 配置差异

桌面 `settings.dart` 的 `tunBlock`（`device: aran0`、`stack: gvisor`、`auto-route: true`）在
Android 上必须不同：

- `auto-route` / `auto-detect-interface` / `auto-redirect` 全部关 —— 路由由 Kotlin 的
  `Builder` 负责，mihomo 只收 fd。两边同时配会抢路由。
- `stack` 默认 `system`（省电），设置项可切回 `gvisor`。
- `device` 不适用。
- DNS：`dns-hijack: any:53`，VpnService 侧 `addDnsServer("0.0.0.0")`；FakeIP 默认关（症状太隐晦）。

## 省电

耗电排序：探测频率 ≫ TUN stack > 进程模型（进程模型几乎无关）。

- 前台/亮屏：决策环 1s、GUI 采样 200ms（与桌面一致）
- 后台：降到 5 分钟；灭屏跟随 Doze（`Timer` 被压制是**特性**，不申请 `AlarmManager` 精确唤醒）
- 灭屏或无真实流量：除当前节点 5 分钟心跳外全部停探；候选探测只在当前节点质量下滑时触发
- 不拿 `PARTIAL_WAKE_LOCK`；不默认申请忽略电池优化（只给一句引导 + 跳转按钮）
- 不打包 `smartdns`（DNS 全交给 mihomo 内置 + 劫持）

## 生命周期

- 前台服务常驻通知：点击回 Aran，带「断开」按钮
- 滑掉界面 / 系统回收 UI 进程：**代理继续**
- 开机自启：默认关。Android 尤其国产 ROM 上开机自启极不可靠，必须用户显式开启
- 内核崩溃：Service 有界重启，5 分钟内崩 3 次就停下并把错误写进通知，不做无限重启
- ColorOS 16：需要用户在系统设置里给「自启动」和「电池无限制」，并在「始终开启的 VPN」里
  选中 Aran 作为兜底。这条只能引导，没有 API

## 文件与数据

- 数据目录：`getApplicationSupportDirectory()`（`config.yaml` / `kernel.log` / 审计 JSONL / 下载的订阅）。
  桌面那条 `$HOME` / `XDG_DATA_HOME` 的路径推导（`linux.dart:54-58`）在 Android 上会退化成 `./.local/share/aran`，不可写，必须换。
- 导入导出：SAF（系统文件选择器 / 分享），**不申请** `MANAGE_EXTERNAL_STORAGE`，
  也不指望用户能看见 `Android/data/<pkg>/`（Android 11+ 文件管理器基本看不到）。
- geo 文件（`Country.mmdb` / `geoip.dat` / `geosite.dat`）：打包进 APK assets，首次启动复制到数据目录，
  缺失时内核直接退出。

## UI

- 五页保留（状态 / 节点 / 连接 / 日志 / 设置），导航改 `NavigationBar`
- 排行榜卡片化（桌面那套表格在 360dp 上放不下）
- 设置页删掉整个服务面板（systemd/polkit/sc.exe，约 150 行），换成「VPN 状态 + 始终开启的 VPN 引导 + 开机自启」
- `common.dart`（535 行通用组件）原样复用
- `window_manager` / `tray_manager` 用条件导入隔离，不改现有桌面文件

## 打包与 CI

- release：仅 `arm64-v8a`；debug/CI：`arm64-v8a` + `x86_64`（模拟器）
- minSdk 26；targetSdk 跟 Flutter 默认
- `packaging.jniLibs.useLegacyPackaging = true`（libclash.so 必须被解压出来）
- 签名 keystore 放仓库外，`.gitignore` 补 `*.jks` 兜底
- CI 新增 `android` job：装 Go + NDK + gomobile，`flutter build apk --debug` 出 artifact。
  **编译通过即绿**，不做模拟器冒烟——真机验收只能在 ColorOS 16 上做
- 体积预期：`libclash.so` 62–74MB/ABI，APK 约 45–58MB

## 与桌面共享代码的隔离纪律

| 文件 | 处理方式 |
|---|---|
| `core/lib/src/platform/factory.dart` | 加 `Platform.isAndroid` 分支 |
| `core/lib/src/platform/platform.dart` | **不动**；Android 特有能力另开 `AndroidVpn` 接口 |
| `core/lib/src/kernel.dart` | **不动**；新增 `AndroidKernel` |
| `app/lib/src/engine.dart` | 只加平台分支选实现 |
| `app/lib/src/app_state.dart` | 只在已有条件点加 `platform.id == 'android'`（watchdog / 诊断导出 / serviceMode） |
| `app/lib/src/ui/settings_page.dart` | 服务面板**原样搬**到独立文件，`build` 里按平台选 |
| `app/lib/main.dart`、`ui/shell.dart` | 条件导入；桌面文件不改，新增 `shell_mobile.dart` |
| `core/lib/src/config_transform.dart`、`settings.dart` | 加 Android 变体，桌面分支不变 |

规则：共享文件的改动只允许「加分支 / 移文件」，不允许重写现有桌面逻辑。评审就一条——
桌面执行路径上的行要么没变，要么是纯新增。

回归：现有 CI 的 `windows` job 是真实的跨平台编译回归，`linux` + `arch` job 保证桌面包能出；
动 `app_state.dart` / `settings_page.dart` 之前先本地 `flutter build linux` 取基线，
改完再跑一遍 + 手动点一遍五个页面、起停内核、系统代理开关。

## 里程碑

每步以「真机能验证」为界，跳过验证的步骤不算完成。

1. 工程骨架 + gomobile 绑定 + Service 起 TUN，**用一份现成的桌面 config** 验证浏览器出网
2. Dart 接上 9090 只读观察（面板能看到节点与连接）
3. 恢复 `config_transform` 接管 `select` 组 + 调度环 + 省电策略
4. UI 适配（底部导航、排行榜卡片化、砍服务面板）
5. 心跳兜底 + SAF 导入导出 + CI

## 风险与待验证

1. **gomobile 构建链**：CI 要装 Go + NDK + gomobile，构建时间显著变长
2. **体积**：APK 45–58MB，是桌面版的数倍
3. **CI 不验证功能**：只能保证编译；功能质量全压在真机上
4. **`system` 栈的兼容性**：UDP 密集 app / DNS 边角场景可能不通，需要真机实测，兜底是一键切 `gvisor`
5. **ColorOS 保活**：厂商 ROM 的后台回收行为无法在模拟器上验证
6. **Go panic = 整个进程崩**：这是进程内 core 的固有代价（决策 #1），用有界重启缓解，
   换不来真正的隔离
