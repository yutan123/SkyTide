import 'dart:convert';
import 'package:flutter/material.dart';
import 'auto_backup_service.dart';
import 'db.dart';
import 'theme.dart';
import 'ui_components.dart';

String backupSize(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

class AutoBackupPage extends StatefulWidget {
  const AutoBackupPage({super.key});
  @override
  State<AutoBackupPage> createState() => _AutoBackupPageState();
}

class _AutoBackupPageState extends State<AutoBackupPage> {
  Map<String, dynamic>? _config;
  List<Map<String, dynamic>> _files = [];
  bool _busy = false;
  String? _error;
  String? _lastError;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await AutoBackupService.config();
      final files = await AutoBackupService.files();
      final error = await DBManager().getKV('auto_backup_error');
      if (mounted)
        setState(() {
          _config = config;
          _files = files;
          _lastError = error;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(String key, dynamic value) => _perform(() async {
    final next = {..._config!, key: value};
    await AutoBackupService.save(next);
  });
  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final config = _config;
    final total = _files.fold<int>(0, (n, f) => n + (f['size'] as num).toInt());
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('备份管理'),
          backgroundColor: Colors.transparent,
        ),
        body: config == null
            ? Center(
                child: _error == null
                    ? CircularProgressIndicator(color: theme.primary)
                    : TextButton(
                        onPressed: _load,
                        child: Text('$_error\n点击重试'),
                      ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    FrostCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_files.length} 个自动备份 · ${backupSize(total)}',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: theme.textStrong,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              AutoBackupService.location,
                              style: TextStyle(color: theme.textWeak),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '仅统计自动备份，手动导出的备份不参与管理。',
                              style: TextStyle(color: theme.textWeak),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FrostCard(
                      child: Column(
                        children: [
                          SwitchListTile.adaptive(
                            title: const Text('自动备份'),
                            subtitle: const Text('到期后由系统后台执行，系统限制时可能延后'),
                            value: config['enabled'] == true,
                            onChanged: _busy
                                ? null
                                : (v) => _change('enabled', v),
                          ),
                          ListTile(
                            title: const Text('备份间隔'),
                            trailing: DropdownButton<int>(
                              value: config['days'] as int,
                              items: [1, 2, 3, 7, 14, 30]
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text('每 $v 天'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _busy
                                  ? null
                                  : (v) {
                                      if (v != null) _change('days', v);
                                    },
                            ),
                          ),
                          ListTile(
                            title: const Text('最多保留'),
                            trailing: DropdownButton<int>(
                              value: config['keep'] as int,
                              items: [1, 3, 5, 7, 10, 20, 30, 50, 100]
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text('$v 个文件'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _busy
                                  ? null
                                  : (v) {
                                      if (v != null) _change('keep', v);
                                    },
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: Text('新备份保存成功后，超出上限才删除最旧的自动备份。'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FrostCard(
                      child: Column(
                        children: [
                          const ListTile(
                            title: Text('备份内容'),
                            subtitle: Text(
                              '机器人基础资料始终保留，保证各类数据的归属。内置模型、缓存和运行日志不备份。媒体文件仅包含所选数据引用的文件；取消媒体后仅保存文字与记录。',
                            ),
                          ),
                          for (final entry in backupChoices.entries)
                            CheckboxListTile.adaptive(
                              title: Text(entry.value),
                              value: (config['selected'] as List).contains(
                                entry.key,
                              ),
                              activeColor: theme.primary,
                              onChanged: _busy
                                  ? null
                                  : (v) {
                                      final selected = List<String>.from(
                                        config['selected'] as List,
                                      );
                                      if (v == true) {
                                        selected.add(entry.key);
                                      } else {
                                        selected.remove(entry.key);
                                      }
                                      if (selected.isEmpty) {
                                        setState(() => _error = '请至少保留一项备份内容');
                                        return;
                                      }
                                      _change('selected', selected);
                                    },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.primary,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _busy
                          ? null
                          : () => _perform(() async {
                              await AutoBackupService.run(force: true);
                            }),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.backup_outlined),
                      label: Text(_busy ? '正在处理…' : '立即执行自动备份'),
                    ),
                    if (_error != null || (_lastError?.isNotEmpty ?? false))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error ?? '上次自动备份失败：$_lastError',
                          style: TextStyle(color: theme.textStrong),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('备份文件'),
                    ),
                    if (_files.isEmpty)
                      const FrostCard(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('暂无自动备份'),
                        ),
                      ),
                    for (final file in _files)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: FrostCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ListTile(
                                title: Text(file['name'] as String),
                                subtitle: Text(
                                  '${backupSize((file['size'] as num).toInt())}\n${AutoBackupService.location}',
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Text(
                                  ((jsonDecode(file['contents'] as String)
                                              as List)
                                          .isEmpty)
                                      ? '备份内容见压缩包内 backup_manifest.json'
                                      : (jsonDecode(file['contents'] as String)
                                                as List)
                                            .join('、'),
                                ),
                              ),
                              OverflowBar(
                                children: [
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _perform(
                                            () => AutoBackupService.open(
                                              file['uri'] as String,
                                            ),
                                          ),
                                    child: const Text('查看文件'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () async {
                                            final confirmed =
                                                await showTideDialog<bool>(
                                                  context: context,
                                                  builder: (ctx) =>
                                                      TideDialogSurface(
                                                        title: const Text(
                                                          '删除备份',
                                                        ),
                                                        content: const Text(
                                                          '删除这个自动备份文件？此操作不会删除当前应用数据。',
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  ctx,
                                                                  false,
                                                                ),
                                                            child: const Text(
                                                              '取消',
                                                            ),
                                                          ),
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  ctx,
                                                                  true,
                                                                ),
                                                            child: const Text(
                                                              '删除',
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                );
                                            if (confirmed == true)
                                              await _perform(
                                                () => AutoBackupService.delete(
                                                  file['uri'] as String,
                                                ),
                                              );
                                          },
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '恢复时使用数据管理中的“恢复所有数据”。恢复会覆盖当前数据；未选入备份的内容不会恢复。',
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
