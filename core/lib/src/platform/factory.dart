import 'dart:io';

import 'linux.dart';
import 'platform.dart';
import 'windows.dart';

export 'platform.dart';
export 'linux.dart';
export 'windows.dart';

/// Resolves the adapter for the current OS.
///
/// Only Linux is implemented today; the others fail loudly instead of silently
/// doing Linux things on Windows/Android, which is exactly the failure mode this
/// layer exists to prevent.
AranPlatform createPlatform() {
  if (Platform.isLinux) return LinuxPlatform();
  if (Platform.isWindows) return WindowsPlatform();
  if (Platform.isMacOS) {
    throw UnsupportedError('macOS 支持尚未实现：需要 launchd、NetworkExtension 与 networksetup 适配器');
  }
  if (Platform.isAndroid) {
    throw UnsupportedError('Android 支持尚未实现：mihomo 需以 AAR 内嵌并经 VpnService 提供 fd');
  }
  throw UnsupportedError('未支持的平台：${Platform.operatingSystem}');
}
