# Windows 支持

状态：**代码就绪，未在真机验证**（开发机是 Arch Linux，无法编译/运行 Windows 目标）。

## 已实现的适配（`core/lib/src/platform/windows.dart`）

| 能力 | Windows 做法 |
|---|---|
| 数据目录 | `%LOCALAPPDATA%\Aran`；便携模式（exe 旁 `portable` 文件或 `ARAN_PORTABLE=1`）→ `<exeDir>\aran-data` |
| 内核发现 | 扫描 PATH（`;` 分隔）+ `%LOCALAPPDATA%\Aran\bin` + scoop shims + chocolatey bin，找 `mihomo.exe` / `clash-meta.exe` / `clash.exe` |
| 内核进程 | `mihomo.exe -d <dataDir>`，与 Linux 相同的托管模式 |
| 服务 | Windows Service Manager：`sc.exe create AranKernel binPath= "mihomo.exe -d ..."`，UAC 提权执行；状态用 `sc.exe query` |
| 提权 | `powershell Start-Process -Verb RunAs -Wait -PassThru`（UAC 弹窗） |
| 系统代理 | 注册表 `HKCU\...\Internet Settings`：ProxyEnable / ProxyServer / ProxyOverride，然后调 `InternetSetOption` 刷新 WinINet |
| 开机自启 | `HKCU\...\CurrentVersion\Run` 写 `Aran` 值 |
| 通知 | PowerShell 气泡通知（`System.Windows.Forms.NotifyIcon`） |
| TUN | 需要 `wintun.dll` 放在 `mihomo.exe` 同目录 **且** 以管理员身份运行；没有 setcap 等价物，所以 `tunCapable()` 会同时检查这两点 |
| 进程校验 | `tasklist /FI "PID eq N" /FO CSV` |

## 服务范围（对应 Linux 的 systemd user/system）

| 范围 | 机制 | 安装 | 启停 | 密码 |
|---|---|---|---|---|
| `user`（默认） | 登录计划任务 `schtasks /sc onlogon /rl LIMITED` | 不需要管理员 | `schtasks /run|/end`，不需要管理员 | 从不 |
| `system` | Windows 服务 `sc.exe create AranKernel` | 需要管理员 | 需要管理员 | 每次（或配置服务 DACL） |

用户级计划任务的限制：**登录后才启动**（不随开机），并且**不能创建 TUN**——
Windows 没有 setcap 等价物，TUN 必须在提权进程里跑。

```powershell
# 查看当前状态（应用里也显示）
schtasks /query /tn AranKernel /fo LIST /v
```

## 打包（在 Windows 主机上）

```powershell
# 便携版 ZIP（默认不含内核）
.\scripts\package-windows.ps1
# 内嵌内核 / SmartDNS
.\scripts\package-windows.ps1 -Kernel C:\tools\mihomo.exe -SmartDns C:\tools\smartdns.exe
# 让便携版默认使用应用目录存放数据（生成 portable 标记）
.\scripts\package-windows.ps1 -Kernel ... -PortableDefault
```

产物：

| 文件 | 说明 |
|---|---|
| `dist\aran-<ver>-windows-x64-portable.zip` | 解压即用；含 `aran_app.exe`、`data\`、`licenses\`、`README.txt` |
| `dist\aran-<ver>-windows-x64-setup.exe` | Inno Setup 安装包：按用户安装到 `%LOCALAPPDATA%\Programs\Aran`（**不需要管理员**），可选桌面快捷方式与登录自启 |

安装包定义在 `packaging/windows/aran.iss`，需要 Inno Setup 6（`ISCC.exe`）；缺失时脚本只出 ZIP 并给警告。

## 构建（手动）

在 **Windows 主机**上（交叉编译不受支持）：

```powershell
# 依赖：Flutter SDK、Visual Studio 2022（Desktop development with C++）
cd app
flutter config --enable-windows-desktop
flutter build windows --release
# 产物：app\build\windows\x64\runner\Release\aran_app.exe
```

内嵌内核（可选，GPL-3.0 传染）：

```powershell
copy C:\path\to\mihomo.exe app\assets\bin\mihomo.exe
flutter build windows --release
```

## 已知待验证项

1. `sc.exe create` 的 `binPath=` 参数带空格时的引号转义
2. `powershell Start-Process -Verb RunAs` 的退出码是否能可靠取回
3. WinINet 代理设置在 Edge/Chrome/Firefox 中的实际生效范围（Firefox 默认用系统代理但可覆盖）
4. wintun.dll 与不同 mihomo 版本的兼容性
5. 托盘（tray_manager / window_manager）在 Windows 上的行为差异
6. 长路径、非 ASCII 用户名下的路径处理

## 需要 platform 层之外改动的地方

- `pubspec.yaml` 的 `assets/` 路径分隔符（Flutter 侧已统一用 `/`，无需改）
- Linux 专属的 `scripts/*.sh` 不参与 Windows 构建
- 托盘图标路径：`<exeDir>\data\flutter_assets\assets\icon.png`（已用 `Platform.pathSeparator` 拼接）
