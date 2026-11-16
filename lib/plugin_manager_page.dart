import 'plugin_market.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'plugin_archive.dart';
import 'plugin_package_files.dart';
import 'package:crypto/crypto.dart';
import 'plugin_config_dialog.dart';
import 'plugin_service.dart';
import 'plugin_operation.dart';
import 'transfer_progress.dart';
import 'plugin_system.dart';
import 'plugin_ui_page.dart';
import 'theme.dart';
import 'ui_components.dart';

class PluginManagerPage extends StatefulWidget {
  const PluginManagerPage({super.key});
  @override
  State<PluginManagerPage> createState() => _PluginManagerPageState();
}

class _PluginManagerPageState extends State<PluginManagerPage> {
  var _tab = 0;
  var _loading = true;
  var _busy = false;
  PluginOperation? _operation;

  @override
  void dispose() {
    PluginMarket.instance.removeListener(_marketChanged);
    _marketScrollController.dispose();
    _marketSearchController.dispose();
    _operation?.cancel();
    _cleanTemp();
    super.dispose();
  }

  String? _error;
  List<Map<String, dynamic>> _plugins = [];
  final _packages = <String, TidePluginPackage>{};

  @override
  void initState() {
    super.initState();
    _syncMarketOrder();
    _marketScrollController.addListener(_queueMarketScrollCheck);
    _reload();
    PluginMarket.instance.addListener(_marketChanged);
    unawaited(PluginMarket.instance.refresh());
  }

  final _marketSources = <String, Map<String, dynamic>>{};
  String _query = '';
  static const _marketPageSize = 20;
  final _marketScrollController = ScrollController(keepScrollOffset: false);
  final _marketSearchController = TextEditingController();
  final _marketOrder = <String>[];
  int _marketVisibleCount = _marketPageSize;
  int _marketGeneration = 0;
  bool _marketLoadingMore = false;
  bool _marketScrollCheckQueued = false;

  // Keep a single randomized order for the browsing session. Index refreshes
  // update metadata without reshuffling pages that the user has already seen.
  void _syncMarketOrder({bool reshuffle = false}) {
    final ids = PluginMarket.instance.plugins.map((p) => p.id).toSet();
    if (reshuffle) _marketOrder.clear();
    _marketOrder.removeWhere((id) => !ids.contains(id));
    final known = _marketOrder.toSet();
    final added = ids.where((id) => !known.contains(id)).toList()..shuffle();
    _marketOrder.addAll(added);
  }

  List<MarketPlugin> get _filteredMarketEntries {
    final byId = {for (final p in PluginMarket.instance.plugins) p.id: p};
    final query = _query.trim().toLowerCase();
    return [
      for (final id in _marketOrder)
        if (byId[id] case final plugin?)
          if ('${plugin.name} ${plugin.author} ${plugin.description}'
              .toLowerCase()
              .contains(query))
            plugin,
    ];
  }

  void _resetMarketPages({bool reshuffle = false}) {
    _marketGeneration++;
    _marketLoadingMore = false;
    _marketVisibleCount = _marketPageSize;
    _syncMarketOrder(reshuffle: reshuffle);
    if (_marketScrollController.hasClients) {
      _marketScrollController.jumpTo(0);
    }
  }

  void _selectTab(int index) {
    if (_tab == index) return;
    setState(() {
      if (index == 1) _resetMarketPages(reshuffle: true);
      _tab = index;
    });
  }

  void _checkMarketScroll() {
    if (!mounted ||
        _tab != 1 ||
        _marketLoadingMore ||
        !_marketScrollController.hasClients ||
        _marketScrollController.position.extentAfter > 240 ||
        _marketVisibleCount >= _filteredMarketEntries.length)
      return;
    final generation = _marketGeneration;
    setState(() => _marketLoadingMore = true);
    // Render the loading footer before revealing the next local index batch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _marketGeneration) return;
      setState(() {
        _marketVisibleCount += _marketPageSize;
        _marketLoadingMore = false;
      });
    });
  }

  void _queueMarketScrollCheck() {
    if (_marketScrollCheckQueued) return;
    _marketScrollCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _marketScrollCheckQueued = false;
      if (mounted) _checkMarketScroll();
    });
  }

  String? _pendingReadmeId;
  MarketPlugin? _pendingMarketDetails;
  final _readmes = <String, File>{};
  String? _downloadingId;
  int _downloaded = 0, _downloadTotal = 0;

  void _marketChanged() {
    if (mounted) setState(_syncMarketOrder);
  }

  MarketPlugin? _marketUpdate(Map<String, dynamic> row) {
    final source = _marketSources[row['id']];
    if (source == null || source['version'] != row['version']) return null;
    for (final plugin in PluginMarket.instance.plugins) {
      if (plugin.id == row['id'] &&
          plugin.repository == source['repository'] &&
          plugin.newerThan(row['version'].toString()))
        return plugin;
    }
    return null;
  }

  Future<void> _refreshAll() async {
    if (_tab == 1) setState(() => _resetMarketPages(reshuffle: true));
    await PluginMarket.instance.refresh();
    await _reload();
  }

  Future<void> _installMarket(MarketPlugin plugin) async {
    final row = _plugins.where((r) => r['id'] == plugin.id).firstOrNull;
    if (row != null && _marketUpdate(row) == null) return;
    final temporary = await Directory.systemTemp.createTemp('tide-market-');
    _tempDirs.add(temporary);
    if (mounted)
      setState(() {
        _downloadingId = plugin.id;
        _downloaded = 0;
        _downloadTotal = 0;
      });
    try {
      final file = await PluginMarket.instance.download(
        plugin,
        temporary,
        _operation!,
        (received, total) {
          if (mounted)
            setState(() {
              _downloaded = received;
              _downloadTotal = total;
            });
        },
      );
      final reviewed = await _reviewPackage(
        file.path,
        updatingId: row == null ? null : plugin.id,
        market: plugin,
      );
      if (reviewed == null) return;
      _operation!.check();
      if (row == null) {
        await PluginSystem.instance.installZip(reviewed, operation: _operation);
      } else {
        await PluginService.instance.updateZip(
          plugin.id,
          reviewed,
          operation: _operation,
        );
      }
      await PluginMarket.instance.saveSource(plugin);
      if (row == null) {
        _pendingReadmeId = plugin.id;
      } else {
        _pendingMarketDetails = plugin;
      }
      if (mounted) _notice(row == null ? '插件已安装，配置后可启用' : '插件已更新');
    } finally {
      if (mounted) setState(() => _downloadingId = null);
      await _cleanTemp();
    }
  }

  Future<void> _reload() async {
    try {
      await PluginService.instance.initialize();
      final rows = await PluginSystem.instance.list();
      final packs = <String, TidePluginPackage>{};
      for (final row in rows) {
        try {
          packs[row['id'] as String] = await PluginSystem.instance.packageFor(
            row,
          );
        } catch (_) {
          /* Damaged packages can still be removed. */
        }
      }
      final readmes = <String, File>{};
      for (final entry in packs.entries) {
        await for (final entity in entry.value.directory.list(
          followLinks: false,
        )) {
          if (entity is File &&
              p.basename(entity.path).toLowerCase() == 'readme.md') {
            readmes[entry.key] = entity;
            break;
          }
        }
      }
      final sources = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final source = await PluginMarket.instance.source(row['id'] as String);
        if (source != null) sources[row['id'] as String] = source;
      }
      if (!mounted) return;
      setState(() {
        _marketSources
          ..clear()
          ..addAll(sources);
        _plugins = [
          ...rows.where((row) => row['enabled'] == 1),
          ...rows.where((row) => row['enabled'] != 1),
        ];
        _readmes
          ..clear()
          ..addAll(readmes);
        _packages
          ..clear()
          ..addAll(packs);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = error.toString();
        });
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _operate(
    Future<void> Function() action, {
    bool cancellable = false,
    String label = '正在处理插件…',
  }) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final operation = cancellable ? PluginOperation() : null;
    _operation = operation;
    operation?.startDeadline();
    try {
      await TransferProgress.run(
        context,
        label,
        () async {
          operation?.check();
          await action();
        },
        operation: operation,
        compact: true,
      );
    } catch (error) {
      if (mounted) {
        if (operation?.cancelled == true) {
          try {
            operation?.check();
          } catch (reason) {
            _notice('$reason');
          }
        } else {
          _notice('操作失败：$error');
        }
      }
    } finally {
      operation?.dispose();
      _operation = null;
      await _reload();
      if (mounted) setState(() => _busy = false);
      final id = _pendingReadmeId;
      _pendingReadmeId = null;
      final updatedPlugin = _pendingMarketDetails;
      _pendingMarketDetails = null;
      if (mounted && updatedPlugin != null) {
        await _marketDetails(updatedPlugin, showChangelog: true);
      } else if (mounted && id != null && _readmes.containsKey(id)) {
        await _showReadme(id);
      }
    }
  }

  Future<String?> _pickZip() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final item = picked.files.single;
    if (item.path != null) return item.path;
    if (item.bytes != null) {
      final tmp = await Directory.systemTemp.createTemp('tide-plugin-');
      _tempDirs.add(tmp);
      final path = p.join(tmp.path, 'package.zip');
      await File(path).writeAsBytes(item.bytes!);
      return path;
    }
    throw const FormatException('无法读取插件文件');
  }

  final _tempDirs = <Directory>[];

  Future<void> _cleanTemp() async {
    for (final dir in _tempDirs.toList()) {
      try {
        await dir.delete(recursive: true);
        _tempDirs.remove(dir);
      } catch (_) {}
    }
  }

  Future<String?> _reviewPackage(
    String path, {
    String? updatingId,
    MarketPlugin? market,
  }) async {
    final file = File(path);
    if (await file.length() > PluginArchive.maxCompressed) {
      throw const FormatException('插件包超过 256 MiB 限制');
    }
    final bytes = await file.readAsBytes();
    final manifest = PluginArchive.decode(bytes).manifest;
    if (updatingId != null && manifest['id'] != updatingId) {
      throw const FormatException('更新包的插件 ID 不匹配');
    }
    if (market != null) {
      if (manifest['id'] != market.id ||
          manifest['version'] != market.version) {
        throw const FormatException('插件包与市场信息不匹配');
      }
    }
    if (market != null || updatingId == null) {
      if (!mounted) return null;
      _operation?.check();
      final temporary = await Directory.systemTemp.createTemp('tide-reviewed-');
      _tempDirs.add(temporary);
      final snapshot = File(p.join(temporary.path, 'package.zip'));
      await snapshot.writeAsBytes(bytes, flush: true);
      return snapshot.path;
    }
    final previous = _packages[updatingId]?.manifest;
    final permissions = (manifest['permissions'] as List? ?? []).cast<String>();
    final origins = (manifest['networkOrigins'] as List? ?? []).cast<String>();
    final addedPermissions = permissions.where(
      (value) => !(previous?['permissions'] as List? ?? []).contains(value),
    );
    final addedOrigins = origins.where(
      (value) => !(previous?['networkOrigins'] as List? ?? []).contains(value),
    );
    if (!mounted) return null;
    final approved =
        await TideDialogs.show<bool>(
          context: context,
          builder: (ctx) => TideDialogSurface(
            title: const Text('更新插件'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${manifest['name']}  ${manifest['version']}'),
                  Text('作者：${manifest['author'] ?? '未填写'}'),
                  Text(
                    market == null
                        ? '来源：本地导入文件'
                        : '来源：插件市场 · ${market.repository}',
                  ),
                  if (market != null && market.changelog.isNotEmpty)
                    Text('更新说明：${market.changelog}'),
                  if (permissions.isNotEmpty)
                    Text('权限：${permissions.join('、')}'),
                  if (origins.isNotEmpty) Text('网络域名：${origins.join('、')}'),
                  if (addedPermissions.isNotEmpty)
                    Text('新增权限：${addedPermissions.join('、')}'),
                  if (addedOrigins.isNotEmpty)
                    Text('新增域名：${addedOrigins.join('、')}'),
                  const SizedBox(height: 12),
                  SelectableText('SHA-256：${sha256.convert(bytes)}'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('继续'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved || !mounted) return null;
    _operation?.check();
    final temporary = await Directory.systemTemp.createTemp('tide-reviewed-');
    _tempDirs.add(temporary);
    final snapshot = File(p.join(temporary.path, 'package.zip'));
    await snapshot.writeAsBytes(bytes, flush: true);
    return snapshot.path;
  }

  Future<void> _install() async {
    final path = await _pickZip();
    if (path == null) return;
    try {
      _operation?.check();
      final reviewedPath = await _reviewPackage(path);
      if (reviewedPath == null) return;
      await PluginSystem.instance.installZip(
        reviewedPath,
        operation: _operation,
      );
      if (mounted) _notice('插件已安装，默认关闭；配置完成后可启用');
    } finally {
      await _cleanTemp();
    }
  }

  Future<void> _update(Map<String, dynamic> row) async {
    final path = await _pickZip();
    if (path == null) return;
    try {
      _operation?.check();
      final reviewedPath = await _reviewPackage(
        path,
        updatingId: row['id'] as String,
      );
      if (reviewedPath == null) return;
      await PluginService.instance.updateZip(
        row['id'] as String,
        reviewedPath,
        operation: _operation,
      );
      await PluginMarket.instance.clearSource(row['id'] as String);
      if (mounted) _notice('插件已更新');
    } finally {
      await _cleanTemp();
    }
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final theme = TideTheme.of(context);
    final confirmed = await TideDialogs.show<bool>(
      context: context,
      builder: (dialogContext) => TideDialogSurface(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        child: TideDialogs.glassContent(
          context: dialogContext,
          maxWidth: 0.84,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30).withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    color: Color(0xFFFF3B30),
                    size: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '删除插件',
                    style: TextStyle(
                      color: theme.textStrong,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '确定卸载“${row['name']}”？其文件、配置和私有数据都会被删除。',
              style: TextStyle(
                color: theme.textWeak,
                height: 1.5,
                fontSize: 13,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text('取消', style: TextStyle(color: theme.textWeak)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF3B30),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    minimumSize: const Size(0, 42),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      await _operate(() async {
        await PluginService.instance.delete(row['id'] as String);
        await PluginMarket.instance.clearSource(row['id'] as String);
      });
    }
  }

  Future<void> _settings(TidePluginPackage pack) async {
    try {
      final schema = pack.manifest['config'] as Map?;
      if (schema == null || (schema['properties'] as Map).isEmpty) {
        _notice('此插件没有配置项');
        return;
      }
      final values = await PluginSystem.instance.loadConfig(pack.id);
      if (!mounted) return;
      final result = await TideDialogs.show<Map<String, dynamic>>(
        context: context,
        builder: (_) => PluginConfigDialog(
          title: '${pack.name} 设置',
          schema: schema,
          values: values,
        ),
      );
      if (result != null && mounted)
        await _operate(
          () => PluginService.instance.saveConfig(pack.id, result),
        );
    } catch (error) {
      if (mounted) _notice('设置失败：$error');
    }
  }

  Future<void> _selectBots(TidePluginPackage pack) async {
    try {
      final bots = await DBManager().queryBots();
      final disabled = await PluginService.instance.disabledBots(pack.id);
      if (!mounted) return;
      final saved = await TideDialogs.show<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, refresh) => TideDialogSurface(
            title: const Text('选择启用的机器人'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('默认对全部机器人启用，取消勾选可单独停用。新建机器人默认启用。'),
                    for (final bot in bots)
                      CheckboxListTile(
                        title: Text(bot['name']?.toString() ?? '机器人'),
                        value: !disabled.contains(bot['id'].toString()),
                        onChanged: (value) => refresh(() {
                          final id = bot['id'].toString();
                          if (value == true) {
                            disabled.remove(id);
                          } else {
                            disabled.add(id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (saved != true) return;
      await PluginService.instance.setDisabledBots(pack.id, disabled);
      if (mounted) _notice('机器人启用范围已保存');
    } catch (error) {
      if (mounted) _notice('保存失败：$error');
    }
  }

  Widget _pluginIcon(TidePluginPackage? pack, {double size = 44}) {
    final theme = TideTheme.of(context);
    final icon = pack?.manifest['icon'] as String?;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.primary.withValues(alpha: .18),
            theme.primary.withValues(alpha: .06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(Icons.power_rounded, size: size * .5, color: theme.primary),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .28),
      child: icon == null || pack == null
          ? fallback
          : Image.file(
              File(p.join(pack.directory.path, icon)),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }

  String _author(Map<String, dynamic> row) {
    final author = row['author']?.toString().trim() ?? '';
    return author.isEmpty ? '未知作者' : author;
  }

  Future<void> _details(Map<String, dynamic> row) => TideDialogs.show<void>(
    context: context,
    builder: (dialogContext) {
      final theme = TideTheme.of(dialogContext);
      final pack = _packages[row['id']];
      final error = PluginService.instance.errors[row['id']];
      return Center(
        child: Material(
          color: Colors.transparent,
          child: TideDialogs.glassContent(
            context: dialogContext,
            children: [
              Row(
                children: [
                  _pluginIcon(pack, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row['name']?.toString() ?? row['id'].toString(),
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: theme.textStrong,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${_author(row)} · v${row['version']}',
                          style: TextStyle(fontSize: 12, color: theme.textWeak),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭详情',
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                '插件介绍',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.textWeak,
                ),
              ),
              const SizedBox(height: 9),
              SelectableText(
                (row['description']?.toString().trim().isNotEmpty ?? false)
                    ? row['description'].toString()
                    : '暂无介绍',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.65,
                  color: theme.textStrong,
                ),
              ),
              const SizedBox(height: 20),
              SelectableText(
                'ID  ${row['id']}',
                style: TextStyle(fontSize: 12, color: theme.textWeak),
              ),
              const SizedBox(height: 8),
              Text(
                pack == null
                    ? '插件文件不可用'
                    : row['enabled'] == 1
                    ? '已启用'
                    : '未启用',
                style: TextStyle(fontSize: 12, color: theme.textWeak),
              ),
              if (pack != null) ...[
                const SizedBox(height: 8),
                Text(
                  '工具 ${(pack.manifest['tools'] as List? ?? []).length} 个',
                  style: TextStyle(fontSize: 12, color: theme.textWeak),
                ),
                if ((pack.manifest['permissions'] as List? ?? [])
                    .isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    '权限  ${(pack.manifest['permissions'] as List).join(' · ')}',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: theme.textWeak,
                    ),
                  ),
                ],
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                SelectableText(
                  error,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Future<void> _showReadme(String id) async {
    try {
      final file = _readmes[id];
      if (file == null) return;
      if (await file.length() > 2 * 1024 * 1024) {
        if (mounted) _notice('自述文件过大，无法预览');
        return;
      }
      final pack = _packages[id];
      if (pack == null) return;
      final bytes = await PluginPackageFiles(
        pack.directory,
      ).read(p.basename(file.path), maxBytes: 2 * 1024 * 1024);
      final text = utf8.decode(bytes, allowMalformed: true);
      if (mounted) await _textDialog(_packages[id]?.name ?? id, text);
    } catch (error) {
      if (mounted) _notice('读取自述文件失败：$error');
    }
  }

  Future<void> _textDialog(String title, String text) => TideDialogs.show<void>(
    context: context,
    builder: (ctx) => TideDialogSurface(
      title: Align(alignment: Alignment.centerLeft, child: Text(title)),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontSize: 14, height: 1.6),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _marketDetails(
    MarketPlugin plugin, {
    bool showChangelog = false,
  }) => _textDialog(
    plugin.name,
    [
      '${plugin.author} · 版本:${plugin.version}',
      plugin.description,
      if (showChangelog && plugin.changelog.trim().isNotEmpty)
        '更新说明\n${plugin.changelog}',
    ].join('\n\n'),
  );

  Widget _action(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    bool destructive = false,
  }) {
    final theme = TideTheme.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: destructive
            ? Theme.of(context).colorScheme.error.withValues(alpha: .8)
            : theme.textWeak,
        disabledForegroundColor: theme.textFaint,
      ),
      icon: Icon(icon, size: 19),
    );
  }

  Widget _card(Map<String, dynamic> row) {
    final theme = TideTheme.of(context);
    final id = row['id'] as String;
    final pack = _packages[id];
    final update = _marketUpdate(row);
    final enabled = row['enabled'] == 1;
    final error = PluginService.instance.errors[id];
    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.primary.withValues(alpha: .45),
          width: .7,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: theme.isDark ? .08 : .025),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _details(row),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 8, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: _pluginIcon(pack),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                row['name']?.toString() ?? id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: theme.textStrong,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                row['description']?.toString() ?? '暂无介绍',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: theme.textWeak,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 5,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    '${_author(row)} · 版本:${row['version']}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.textWeak,
                                    ),
                                  ),
                                  if (update != null) ...[
                                    Text(
                                      '→',
                                      style: TextStyle(color: theme.textWeak),
                                    ),
                                    _versionBadge(update.version),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Semantics(
                            label: '启用插件',
                            toggled: enabled,
                            button: true,
                            child: Tooltip(
                              message: enabled ? '停用插件' : '启用插件',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: _busy || pack == null
                                    ? null
                                    : () => _operate(
                                        () => PluginService.instance.setEnabled(
                                          id,
                                          !enabled,
                                          operation: _operation,
                                        ),
                                        cancellable: !enabled,
                                        label: enabled ? '正在关闭插件…' : '正在启用插件…',
                                      ),
                                child: SizedBox(
                                  width: 48,
                                  height: 44,
                                  child: Center(
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      width: 38,
                                      height: 23,
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                        color: enabled
                                            ? theme.primary
                                            : theme.surfaceVariant,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: AnimatedAlign(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        curve: Curves.easeOutCubic,
                                        alignment: enabled
                                            ? Alignment.centerRight
                                            : Alignment.centerLeft,
                                        child: Container(
                                          width: 17,
                                          height: 17,
                                          decoration: BoxDecoration(
                                            color: _busy || pack == null
                                                ? theme.textFaint
                                                : enabled
                                                ? Colors.white
                                                : theme.textWeak,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      height: 32,
                      width: 40,
                      child: _action(
                        Icons.upgrade_rounded,
                        '从本地 ZIP 更新',
                        _busy
                            ? null
                            : () => _operate(
                                () => _update(row),
                                cancellable: true,
                                label: '正在更新插件…',
                              ),
                      ),
                    ),
                  ],
                ),
                if (update != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _marketUpdateButton(update),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(width: 56),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: error != null || pack == null
                            ? Theme.of(context).colorScheme.error
                            : enabled
                            ? theme.primary
                            : theme.textFaint,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        error != null
                            ? '运行异常'
                            : pack == null
                            ? '文件不可用'
                            : enabled
                            ? '已启用'
                            : '未启用',
                        style: TextStyle(fontSize: 10, color: theme.textWeak),
                      ),
                    ),
                    if (_readmes.containsKey(id))
                      _action(
                        Icons.menu_book_rounded,
                        '查看自述文件',
                        _busy ? null : () => _showReadme(id),
                      ),
                    if (pack != null)
                      _action(
                        Icons.group_outlined,
                        '选择启用的机器人',
                        _busy ? null : () => _selectBots(pack),
                      ),
                    if (pack != null &&
                        ((pack.manifest['config'] as Map?)?['properties']
                                    as Map? ??
                                {})
                            .isNotEmpty)
                      _action(
                        Icons.tune_rounded,
                        '插件设置',
                        _busy ? null : () => _settings(pack),
                      ),
                    if (pack?.hasUi == true)
                      _action(
                        Icons.open_in_new_rounded,
                        '打开插件',
                        _busy
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => PluginUiPage(package: pack!),
                                ),
                              ),
                      ),
                    _action(
                      Icons.delete_outline_rounded,
                      '卸载插件',
                      _busy ? null : () => _remove(row),
                      destructive: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _versionBadge(String version) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFFFFD76A),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      version,
      style: const TextStyle(
        fontSize: 11,
        color: Color(0xFF624400),
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _marketUpdateButton(MarketPlugin plugin) => FilledButton.icon(
    style: FilledButton.styleFrom(
      minimumSize: const Size(76, 34),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      textStyle: const TextStyle(fontSize: 12),
      backgroundColor: const Color(0xFFFFD76A),
      foregroundColor: const Color(0xFF624400),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    onPressed: _busy
        ? null
        : () => _operate(
            () => _installMarket(plugin),
            cancellable: true,
            label: '正在下载并更新插件…',
          ),
    icon: const Icon(Icons.error_outline_rounded, size: 17),
    label: const Text('更新'),
  );

  Widget _marketBody() {
    final market = PluginMarket.instance;
    final theme = TideTheme.of(context);
    final allEntries = _filteredMarketEntries;
    final entries = allEntries.take(_marketVisibleCount).toList();
    final hasMore = entries.length < allEntries.length;
    _queueMarketScrollCheck();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _marketSearchController,
            onChanged: (v) => setState(() {
              _query = v;
              _resetMarketPages();
            }),
            decoration: InputDecoration(
              hintText: '搜索插件、作者',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
              ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
              ),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                onPressed: market.loading ? null : _refreshAll,
                icon: const Icon(Icons.refresh_rounded),
              ),
              filled: true,
              fillColor: theme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshAll,
            child: ListView.separated(
              controller: _marketScrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              itemCount: entries.isEmpty
                  ? 1
                  : entries.length +
                        (hasMore ? 1 : 0) +
                        (market.error == null ? 0 : 1),
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, index) {
                if (entries.isEmpty)
                  return Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.storefront_outlined,
                            size: 44,
                            color: theme.textFaint,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            market.loading
                                ? '正在加载插件市场…'
                                : market.error != null
                                ? '暂时无法获取插件市场'
                                : _query.isNotEmpty
                                ? '没有找到匹配的插件'
                                : '暂无上架插件',
                            style: TextStyle(color: theme.textWeak),
                          ),
                          if (market.error != null)
                            TextButton(
                              onPressed: _refreshAll,
                              child: const Text('重新加载'),
                            ),
                        ],
                      ),
                    ),
                  );
                if (hasMore && index == entries.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.primary,
                        ),
                      ),
                    ),
                  );
                }
                if (index >= entries.length)
                  return Text(
                    '刷新失败，当前显示缓存内容',
                    style: TextStyle(color: theme.textWeak),
                  );
                final plugin = entries[index];
                final installed = _plugins
                    .where((r) => r['id'] == plugin.id)
                    .firstOrNull;
                final update = installed == null
                    ? null
                    : _marketUpdate(installed);
                final downloading = _downloadingId == plugin.id;
                return Material(
                  color: theme.surface,
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _marketDetails(plugin),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: theme.primary.withValues(alpha: .10),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(
                                  Icons.extension_rounded,
                                  color: theme.primary,
                                  size: 21,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      plugin.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: theme.textStrong,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${plugin.author} · 版本:${plugin.version}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: theme.textWeak,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            plugin.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: theme.textWeak,
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (downloading)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: LinearProgressIndicator(
                                value: _downloadTotal > 0
                                    ? (_downloaded / _downloadTotal)
                                          .clamp(0, 1)
                                          .toDouble()
                                    : null,
                                color: theme.primary,
                              ),
                            ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (update != null)
                                _marketUpdateButton(plugin)
                              else
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: theme.primary,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(76, 34),
                                    visualDensity: VisualDensity.standard,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(11),
                                    ),
                                    textStyle: const TextStyle(fontSize: 12),
                                  ),
                                  onPressed: _busy || installed != null
                                      ? null
                                      : () => _operate(
                                          () => _installMarket(plugin),
                                          cancellable: true,
                                          label: '正在下载插件…',
                                        ),
                                  icon: Icon(
                                    installed == null
                                        ? Icons.download_rounded
                                        : Icons.check_rounded,
                                    size: 16,
                                  ),
                                  label: Text(installed == null ? '下载' : '已安装'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabs() {
    final theme = TideTheme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.surfaceVariant.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(17),
      ),
      child: LayoutBuilder(
        builder: (_, constraints) => Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: _tab == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: Container(
                width: constraints.maxWidth / 2,
                decoration: BoxDecoration(
                  color: theme.surface,
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: List.generate(2, (index) {
                final selected = _tab == index;
                return Expanded(
                  child: Semantics(
                    selected: selected,
                    button: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(13),
                        onTap: () => _selectTab(index),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 180),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected
                                  ? theme.textStrong
                                  : theme.textWeak,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  index == 0
                                      ? Icons.widgets_outlined
                                      : Icons.storefront_outlined,
                                  size: 17,
                                  color: selected
                                      ? theme.primary
                                      : theme.textWeak,
                                ),
                                const SizedBox(width: 8),
                                Text(index == 0 ? '插件列表' : '插件市场'),
                                if (_plugins.any(
                                  (row) => _marketUpdate(row) != null,
                                )) ...[
                                  const SizedBox(width: 5),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFD76A),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '${_plugins.where((row) => _marketUpdate(row) != null).length}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF624400),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return Scaffold(
      backgroundColor: theme.pageBackground,
      appBar: AppBar(
        title: const Text('插件'),
        backgroundColor: theme.pageBackground,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
            child: _tabs(),
          ),
        ),
      ),
      body: _tab == 1
          ? _marketBody()
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: TextButton(
                onPressed: _reload,
                child: Text('加载失败，点击重试：$_error'),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: _plugins.isEmpty
                      ? const Center(child: Text('暂无已安装插件'))
                      : RefreshIndicator(
                          onRefresh: _refreshAll,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                            itemCount: _plugins.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (_, index) => _card(_plugins[index]),
                          ),
                        ),
                ),
              ],
            ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              onPressed: _busy
                  ? null
                  : () =>
                        _operate(_install, cancellable: true, label: '正在安装插件…'),
              tooltip: '导入插件 ZIP',
              child: const Icon(Icons.add_rounded),
            )
          : null,
    );
  }
}
