/// Service definitions.
///
/// Two flavours:
///  * **内嵌服务文件** — templates shipped as assets (`assets/service/*.tmpl`),
///    filled in at install time; used when the build includes them.
///  * **运行时生成** — the unit text is produced by this class; fallback for
///    slim builds that don't ship templates.
import 'dart:io';

import 'bundled.dart';
class ServiceUnit {
  final String kernelPath;
  final String dataDir;

  const ServiceUnit({required this.kernelPath, required this.dataDir});

  String get unitName => 'aran-kernel.service';

  /// Path where the unit is installed on a systemd host.
  String get installPath => '/etc/systemd/system/$unitName';

  /// Embedded service template (shipped as an asset) with placeholders filled.
  /// Returns null when this build didn't ship templates.
  String? embeddedContent(String kind) {
    final file = switch (kind) {
      'openrc' => File('${Bundled.assetsDir.path}/service/aran-kernel.openrc.tmpl'),
      'runit' => File('${Bundled.assetsDir.path}/service/aran-kernel.runit.tmpl'),
      _ => File('${Bundled.assetsDir.path}/service/aran-kernel.service.tmpl'),
    };
    if (!file.existsSync()) return null;
    return file
        .readAsStringSync()
        .replaceAll('@KERNEL@', kernelPath)
        .replaceAll('@DATADIR@', dataDir);
  }

  /// systemd unit (default).
  String content() => '''[Unit]
Description=Aran proxy kernel (mihomo)
Documentation=https://github.com/MetaCubeX/mihomo
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=simple
ExecStart=$kernelPath -d $dataDir
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
''';

  /// Command pair used to install it: write to a staging file owned by us, then
  /// `install(1)` it into place with root.
  List<String> installArgs(String stagedPath) => ['install', '-m', '644', stagedPath, installPath];

  /// OpenRC init script — different lifecycle vocabulary from systemd.
  String openrcContent() => '''#!/sbin/openrc-run
name="aran-kernel"
description="Aran proxy kernel (mihomo)"

command="$kernelPath"
command_args="-d $dataDir"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/aran-kernel.log"
error_log="/var/log/aran-kernel.log"

depend() {
  need net
  after firewall
}
''';

  /// runit run script.
  String runitContent() => '''#!/bin/sh
exec $kernelPath -d $dataDir 2>&1
''';

  /// Body for the given supervisor: embedded template if the build shipped one,
  /// otherwise the generated text.
  String contentFor(String kind) {
    final embedded = embeddedContent(kind);
    if (embedded != null) return embedded;
    switch (kind) {
      case 'openrc':
        return openrcContent();
      case 'runit':
        return runitContent();
      default:
        return content();
    }
  }

  /// True when this build ships service templates (i.e. embedded service files).
  bool get hasEmbeddedTemplates =>
      File('${Bundled.assetsDir.path}/service/aran-kernel.service.tmpl').existsSync();

  /// Where each supervisor expects its file.
  String pathFor(String kind) {
    switch (kind) {
      case 'openrc':
        return '/etc/init.d/aran-kernel';
      case 'runit':
        return '/etc/sv/aran-kernel/run';
      default:
        return installPath;
    }
  }
}

/// Watchdog helper source, generated on demand into the data directory (again,
/// not shipped as an asset).
const String watchdogScript = r'''#!/usr/bin/env python3
"""Aran watchdog: hand groups back to a url-test group if the GUI disappears."""
import json, os, sys, time, urllib.parse, urllib.request

TIMEOUT = 30

def put_group(addr, secret, group, node):
    url = f"http://{addr}/proxies/{urllib.parse.quote(group, safe='')}"
    req = urllib.request.Request(
        url,
        data=json.dumps({"name": node}).encode(),
        method="PUT",
        headers={"Authorization": f"Bearer {secret}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5):
        pass

def main():
    if len(sys.argv) < 5:
        return 1
    addr, secret, hb, fallback = sys.argv[1:5]
    groups = sys.argv[5:]
    while True:
        try:
            age = time.time() - os.stat(hb).st_mtime
        except FileNotFoundError:
            age = 0
        if age > TIMEOUT:
            for g in groups:
                try:
                    put_group(addr, secret, g, fallback)
                    print(f"[watchdog] {g} -> {fallback}", flush=True)
                except Exception as e:
                    print(f"[watchdog] {g} failed: {e}", flush=True)
        time.sleep(5)

if __name__ == "__main__":
    sys.exit(main())
''';
