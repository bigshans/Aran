// 平台层诊断：在目标系统上打印 Aran 看到的平台能力。
// 用途：CI 在真 Windows 上验证 serviceKind / 服务工具链 / TUN 前置条件。
import 'dart:io';

import 'package:aran_core/aran_core.dart';

Future<void> main() async {
  final p = createPlatform();
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  final dataDir = p.dataDir(Platform.environment['XDG_DATA_HOME'], home);

  void show(String k, Object? v) => stdout.writeln('  $k = $v');

  stdout.writeln('== 平台 ==');
  show('os', Platform.operatingSystem);
  show('osVersion', Platform.operatingSystemVersion);
  show('id', p.id);
  show('portable', p.portable);
  show('dataDir', dataDir.path);
  show('serviceSupported', p.supportsSystemService);

  stdout.writeln('== 服务 ==');
  for (final scope in ['user', 'system']) {
    p.serviceScope = scope;
    show('$scope.kind', p.serviceKind);
    show('$scope.unitPath', p.serviceUnitPath());
    show('$scope.installed', p.serviceInstalled());
  }
  p.serviceScope = 'user';

  stdout.writeln('== 服务工具链 ==');
  for (final tool in ['systemctl', 'sc.exe', 'schtasks', 'journalctl', 'pkexec']) {
    final r = await _which(tool);
    show(tool, r ?? '缺失');
  }

  stdout.writeln('== TUN ==');
  final found = p.kernelSearchPaths(home).where((x) => File(x).existsSync()).toList();
  show('kernel', found.isEmpty ? '未找到' : found.first);
  show('tunCapable', found.isEmpty ? '无内核' : await p.tunCapable(found.first));

  stdout.writeln('== 内核来源候选 ==');
  for (final e in ['MIHOMO', 'ARAN_KERNEL', 'ARAN_DATA']) {
    show(e, Platform.environment[e] ?? '-');
  }
}

Future<String?> _which(String tool) async {
  try {
    final windows = Platform.isWindows;
    final r = await Process.run(windows ? 'where' : 'which', [tool]);
    if (r.exitCode != 0) return null;
    return '${r.stdout}'.trim().split('\n').first.trim();
  } catch (_) {
    return null;
  }
}
