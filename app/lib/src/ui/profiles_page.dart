import 'dart:io';

import 'package:aran_core/aran_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

/// Auto-update presets shared by the row and the settings dialog.
const _intervals = <int, String>{
  0: '不自动更新',
  6: '每 6 小时',
  12: '每 12 小时',
  24: '每 24 小时',
  48: '每 48 小时',
};

class ProfilesPage extends StatelessWidget {
  final AppState state;
  const ProfilesPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final list = state.profiles.profiles;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Row(children: [
          const Text('配置与订阅', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          Btn(
            label: state.isPending('updcheck') ? '检查中…' : '检查更新',
            icon: Icons.refresh_rounded,
            loading: state.isPending('updcheck'),
            onTap: () => state.runPending('updcheck', () => state.checkUpdatesNow()),
          ),
          const SizedBox(width: 8),
          Btn(label: '从 URL 导入', icon: Icons.link_rounded, onTap: () => _addUrl(context)),
          const SizedBox(width: 8),
          Btn(label: '从文件导入', icon: Icons.folder_open_rounded, onTap: () => _addFile(context)),
          const SizedBox(width: 8),
          Btn(
            label: '导入 Sparkle 配置',
            icon: Icons.download_rounded,
            loading: state.isPending('import'),
            onTap: () => state.runPending('import', () => _importSparkle(context)),
          ),
        ]),
        const SizedBox(height: 6),
        Text('点击任意一行即可切换为该配置；启动代理时 Aran 会把自动策略组改写为自己接管。',
            style: mono.copyWith(fontSize: 11, color: dim)),
        const SizedBox(height: 16),
        if (list.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: panel, border: Border.all(color: line, width: borderWidth), borderRadius: BorderRadius.circular(radius)),
            child: Text('还没有配置。可以导入机场订阅链接，或直接导入本机 Sparkle 正在用的配置。',
                style: mono.copyWith(fontSize: 12, color: dim)),
          ),
        for (final p in list) _ProfileRow(state: state, profile: p),
      ],
    );
  }

  static Future<void> _history(BuildContext context, AppState state, Profile profile) async {
    final snaps = await state.profiles.snapshots(profile.id);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('配置快照 · ${profile.name}'),
        content: SizedBox(
          width: 520,
          height: 320,
          child: snaps.isEmpty
              ? Center(child: Text('还没有快照（每次保存配置或更新订阅前会自动生成）',
                  style: mono.copyWith(fontSize: 12, color: dim)))
              : ListView.builder(
                  itemCount: snaps.length,
                  itemBuilder: (ctx, i) {
                    final f = snaps[i];
                    final name = f.path.split('/').last.replaceAll('.yaml', '').replaceAll('T', ' ');
                    final size = f.lengthSync();
                    return Row(children: [
                      Expanded(child: Text(name, style: mono.copyWith(fontSize: 12))),
                      Text('${(size / 1024).toStringAsFixed(0)} KB',
                          style: mono.copyWith(fontSize: 11, color: dim)),
                      const SizedBox(width: 12),
                      Btn(
                        label: '回滚',
                        small: true,
                        color: amber,
                        onTap: () async {
                          await state.restoreSnapshot(profile.id, f);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                      const SizedBox(width: 6),
                      Btn(
                        label: '删除',
                        small: true,
                        color: red,
                        onTap: () async {
                          await state.profiles.deleteSnapshot(profile.id, f);
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) ProfilesPage._history(context, state, profile);
                        },
                      ),
                    ]);
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await state.profiles.clearSnapshots(profile.id);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('清空全部'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  static Future<void> _editMeta(BuildContext context, AppState state, Profile profile) async {
    final nameCtrl = TextEditingController(text: profile.name);
    final urlCtrl = TextEditingController(text: profile.url ?? '');
    var hours = profile.autoUpdateHours ?? 24;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('订阅设置'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              style: mono.copyWith(fontSize: 12),
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: urlCtrl,
              style: mono.copyWith(fontSize: 12),
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '订阅 URL',
                hintText: 'https://…（本地导入的配置可留空）',
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Text('自动更新', style: mono.copyWith(fontSize: 12, color: dim)),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: _intervals.containsKey(hours) ? hours : 24,
                isDense: true,
                dropdownColor: panel,
                style: mono.copyWith(fontSize: 12, color: text),
                items: [
                  for (final e in _intervals.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setDialogState(() => hours = v ?? 24),
              ),
              const Spacer(),
              Text('仅对有 URL 的订阅生效', style: mono.copyWith(fontSize: 11, color: dim)),
            ]),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('改完 URL 记得点「更新」重新下载一次',
                  style: mono.copyWith(fontSize: 11, color: dim)),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
      ),
    );
    if (ok == true) {
      await state.saveProfileMeta(
        profile.id,
        name: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
        url: urlCtrl.text.trim(),
        autoUpdateHours: hours,
      );
    }
  }

  static Future<void> _edit(BuildContext context, AppState state, Profile profile) async {
    final text = await state.readProfileText(profile.id);
    if (!context.mounted) return;
    final ctrl = TextEditingController(text: text);
    final scroll = ScrollController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 1040,
          height: 720,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
                child: Row(children: [
                  Text('编辑配置 · ${profile.name}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  Text('${text.length} 字节 · 保存后若为当前配置会自动重启代理',
                      style: mono.copyWith(fontSize: 11, color: dim)),
                  const Spacer(),
                  Btn(label: '取消', onTap: () => Navigator.pop(ctx, false)),
                  const SizedBox(width: 8),
                  Btn(label: '保存并应用', color: green, filled: true, onTap: () => Navigator.pop(ctx, true)),
                ]),
              ),
              Container(height: 1, color: line),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: TextField(
                    controller: ctrl,
                    scrollController: scroll,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: mono.copyWith(fontSize: 12, height: 1.45),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) {
      final ok = await state.saveProfileText(profile.id, ctrl.text);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(state.error ?? '保存失败')),
        );
      }
    }
  }

  Future<void> _addUrl(BuildContext context) async {
    final urlCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入订阅链接'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: urlCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: '订阅 URL', hintText: 'https://…'),
          ),
          const SizedBox(height: 12),
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称（可选）')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
        ],
      ),
    );
    if (ok == true && urlCtrl.text.trim().isNotEmpty) {
      await state.addProfileFromUrl(urlCtrl.text.trim(), name: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim());
    }
  }

  Future<void> _addFile(BuildContext context) async {
    final pathCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入本地配置文件'),
        content: TextField(
          controller: pathCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '文件路径', hintText: '/home/you/config.yaml'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
        ],
      ),
    );
    if (ok == true && pathCtrl.text.trim().isNotEmpty) {
      await state.addProfileFromFile(pathCtrl.text.trim());
    }
  }

  Future<void> _importSparkle(BuildContext context) async {
    final home = Platform.environment['HOME'] ?? '.';
    final candidates = [
      '$home/.config/sparkle/work/config.yaml',
      '$home/.config/mihomo/config.yaml',
      '$home/.config/clash/config.yaml',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        await state.addProfileFromFile(c, name: '本机导入（${c.split('/').sublist(c.split('/').length - 2).join('/')}）');
        return;
      }
    }
    state.setError('没找到可导入的配置（找过 sparkle / mihomo / clash 的默认路径）');
  }
}

class _ProfileRow extends StatelessWidget {
  /// Overflow menu: metadata, YAML editor, snapshots, proxied update, delete.
  Widget _rowMenu(BuildContext context, Profile profile) {
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      color: panel,
      position: PopupMenuPosition.under,
      icon: Icon(Icons.more_horiz, size: 18, color: dim),
      onSelected: (v) {
        switch (v) {
          case 'meta':
            ProfilesPage._editMeta(context, state, profile);
          case 'config':
            ProfilesPage._edit(context, state, profile);
          case 'history':
            ProfilesPage._history(context, state, profile);
          case 'update':
            state.runPending('upd:${profile.id}', () => state.updateProfile(profile.id));
          case 'proxy':
            state.runPending('upd:${profile.id}', () => state.updateProfile(profile.id, viaProxy: true));
          case 'delete':
            state.runPending('rm:${profile.id}', () => state.removeProfile(profile.id));
        }
      },
      itemBuilder: (context) => [
        _menuItem('meta', '订阅信息', Icons.link),
        _menuItem('config', '编辑配置 YAML', Icons.edit_note),
        _menuItem('history', '历史快照 / 回滚', Icons.history),
        if (profile.url != null) _menuItem('update', '更新订阅（直连）', Icons.refresh_rounded),
        if (profile.url != null) _menuItem('proxy', '更新订阅（通过代理）', Icons.shield_outlined),
        const PopupMenuDivider(),
        _menuItem('delete', '删除此配置', Icons.delete_outline, color: red),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, String label, IconData icon, {Color? color}) {
    final c = color ?? text;
    return PopupMenuItem(
      value: value,
      height: 38,
      child: Row(children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 10),
        Text(label, style: mono.copyWith(fontSize: 12, color: c)),
      ]),
    );
  }

  final AppState state;
  final Profile profile;
  const _ProfileRow({required this.state, required this.profile});

  @override
  Widget build(BuildContext context) {
    final active = state.profiles.activeId == profile.id;
    final activating = state.isPending('act:${profile.id}');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: active || activating
            ? null
            : () => state.runPending('act:${profile.id}', () => state.activateProfile(profile.id)),
        hoverColor: blue.withValues(alpha: 0.05),
        child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: active ? panelAlt : panel,
        border: Border.all(color: active ? blue : line),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(children: [
        Icon(active ? Icons.check_circle : Icons.radio_button_unchecked, size: 17, color: active ? green : dim),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(profile.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? green : text,
                    )),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: (profile.url != null ? blue : dim).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: Text(
                  profile.url != null ? '远程订阅' : '本地文件',
                  style: mono.copyWith(fontSize: 10, color: profile.url != null ? blue : dim),
                ),
              ),
              const SizedBox(width: 8),
              if (active)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: green.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  child: Text('正在使用', style: mono.copyWith(fontSize: 10.5, color: green)),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: line,
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  child: Text(
                    state.isPending('act:${profile.id}') ? '启用中…' : '点击启用',
                    style: mono.copyWith(
                      fontSize: 10.5,
                      color: state.isPending('act:${profile.id}') ? blue : dim,
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 3),
            Row(children: [
              if (profile.trafficLeft != null) ...[
                _quotaChip(profile),
                const SizedBox(width: 10),
                if (profile.trafficTotal != null && profile.trafficUsed != null)
                  QuotaBar(
                    used: profile.trafficUsed!,
                    total: profile.trafficTotal!,
                    width: 110,
                    label: '已用 ${fmtBytes(profile.trafficUsed)}',
                  ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  // Never render the URL: airport links carry ?token=… and this
                  // list ends up in screenshots and on shared screens.
                  [
                    '更新于 ${_fmt(profile.updatedAt)}',
                    '${(profile.bytes / 1024).toStringAsFixed(0)} KB',
                    if (profile.url == null && profile.homeDir != null) '来源 ${profile.homeDir}',
                  ].join('   ·   '),
                  style: mono.copyWith(fontSize: 11, color: dim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ]),
        ),
        // Everything lives in the overflow menu; the row itself is the
        // "activate" affordance.
        _rowMenu(context, profile),
      ]),
        ),
      ),
    );
  }

  Widget _quotaChip(Profile p) {
    final left = p.trafficLeft!;
    final total = p.trafficTotal;
    final ratio = (total != null && total > 0) ? left / total : null;
    final color = ratio == null
        ? blue
        : ratio < 0.1
            ? red
            : ratio < 0.3
                ? amber
                : green;
    final text = total != null
        ? '剩余 ${fmtBytes(left)} / ${fmtBytes(total)}'
        : '剩余 ${fmtBytes(left)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(text, style: mono.copyWith(fontSize: 10.5, color: color)),
    );
  }


  String _fmt(DateTime t) =>
      '${t.year}-${_p(t.month)}-${_p(t.day)} ${_p(t.hour)}:${_p(t.minute)}';

  String _p(int v) => v.toString().padLeft(2, '0');
}
