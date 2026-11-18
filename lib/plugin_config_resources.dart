import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'db.dart';
import 'plugin_ai.dart';
import 'plugin_coordinator.dart';
import 'plugin_file_store.dart';
import 'plugin_system.dart';

class PluginConfigOption {
  const PluginConfigOption(this.id, this.label, [this.detail = ''])
    : avatar = null,
      isBot = false;

  const PluginConfigOption.bot(this.id, this.label, this.avatar)
    : detail = '',
      isBot = true;

  final String id;
  final String label;
  final String detail;
  final String? avatar;
  final bool isBot;
}

/// Only public display information and opaque IDs leave this host-side catalog.
class PluginConfigResources {
  static Future<List<PluginConfigOption>> options(
    String kind,
    List types,
  ) async {
    final db = DBManager();
    if (kind == 'bot') {
      return [
        for (final bot in await db.queryBots())
          PluginConfigOption.bot(
            bot['id'].toString(),
            bot['name']?.toString() ?? '机器人',
            bot['avatar']?.toString(),
          ),
      ];
    }
    final results = await Future.wait([
      if (types.contains('chat')) db.queryChatProviders(),
      if (types.contains('stt')) db.querySttProviders(),
      if (types.contains('tts')) db.queryTtsProviders(),
    ]);
    return [
      for (final list in results)
        for (final provider in list)
          PluginConfigOption(
            providerId(provider),
            provider['name']?.toString() ?? '模型提供商',
            '${const {'chat': '聊天', 'stt': '语音识别', 'tts': '语音合成'}[provider['type']]} · ${provider['model'] ?? ''}',
          ),
    ];
  }

  static String providerId(Map provider) {
    final hash = PluginAI.providerId(provider);
    return provider['type'] == 'chat' ? hash : '${provider['type']}:$hash';
  }

  static Future<PluginFileStore> _store(String id) async => PluginFileStore(
    Directory(
      '${(await getApplicationSupportDirectory()).path}/plugin_files/$id',
    ),
    check: () async {
      final rows = await PluginSystem.instance.list();
      final matches = rows.where((row) => row['id'] == id);
      if (matches.isEmpty) throw StateError('插件已被删除');
      final pack = await PluginSystem.instance.packageFor(matches.first);
      if (!(pack.manifest['permissions'] as List? ?? []).contains('files'))
        throw StateError('未声明 files 权限');
    },
    locked: <T>(Future<T> Function() work) =>
        PluginCoordinator.locked('storage:$id', work),
  );
  static Future<String> importFile(String id, String source) async {
    final store = await _store(id);
    final name = p.basename(source).replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final target =
        'config_imports/${DateTime.now().microsecondsSinceEpoch}-$name';
    await store.writeStream(target, File(source).openRead());
    return target;
  }

  static Future<List<PluginConfigOption>> directories(String id) async {
    final store = await _store(id);
    return store.locked(() async {
      await store.check();
      await store.root.create(recursive: true);
      final result = <PluginConfigOption>[];
      var count = 0;
      await for (final entity in store.root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (++count > 10000) throw StateError('插件文件条目超过 10000');
        if (entity is Directory) {
          final relative = p.relative(entity.path, from: store.root.path);
          if (!relative
              .split('/')
              .any((part) => part.startsWith('.pending-'))) {
            result.add(PluginConfigOption(relative, relative));
          }
        }
        if (result.length >= 1000) break;
      }
      return result..sort((a, b) => a.label.compareTo(b.label));
    });
  }

  static Future<String> createDirectory(String id, String name) async {
    final store = await _store(id);
    await store.locked(() async {
      final target = await store.file('$name/.directory');
      await target.parent.create(recursive: true);
    });
    return name;
  }
}
