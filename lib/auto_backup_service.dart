import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'db.dart';
import 'data_transfer.dart';
import 'full_backup_service.dart';

const backupChoices = <String, String>{
  'settings': '应用设置与接口配置',
  'chat': '聊天记录与通话记录',
  'memory': '记忆与世界书',
  'posts': '动态与评论',
  'diaries': '日记与生活日程',
  'stickers': '表情包',
  'plugins': '插件、Skill 与 MCP 配置',
  'media': '图片、视频、语音、头像与背景',
};

class AutoBackupService {
  static const channel = MethodChannel('skytide.auto_backup');
  static const location = '下载/SkyTide/backup';
  static const configKey = 'auto_backup_config';
  static Future<Map<String, dynamic>> config() async {
    final raw = await DBManager().getKV(configKey);
    return raw == null
        ? {
            'enabled': true,
            'days': 2,
            'keep': 3,
            'selected': backupChoices.keys.toList(),
          }
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  static Future<void> save(Map<String, dynamic> value) async {
    await DBManager().setKV(configKey, jsonEncode(value));
    await channel.invokeMethod<void>('schedule', {'enabled': value['enabled']});
  }

  static Future<List<Map<String, dynamic>>> files() async {
    final rows = await channel.invokeListMethod<dynamic>('list') ?? [];
    return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  static Future<void> delete(String uri) =>
      channel.invokeMethod<void>('delete', {'uri': uri});
  static Future<void> open(String uri) =>
      channel.invokeMethod<void>('open', {'uri': uri});
  static Future<bool> run({bool force = false}) async {
    final cfg = await config();
    if (!force && DataTransfer.isBusy) return false;
    if (!force && cfg['enabled'] != true) return false;
    final last =
        int.tryParse(await DBManager().getKV('auto_backup_last') ?? '') ?? 0;
    if (!force &&
        DateTime.now().millisecondsSinceEpoch - last <
            Duration(days: cfg['days'] as int).inMilliseconds)
      return false;
    return DataTransfer.exclusive(() async {
      // Native file lock serializes foreground and headless engines.
      final locked = await channel.invokeMethod<bool>('lock') ?? false;
      if (!locked) return false;
      try {
        final latest =
            int.tryParse(await DBManager().getKV('auto_backup_last') ?? '') ??
            0;
        if (!force &&
            DateTime.now().millisecondsSinceEpoch - latest <
                Duration(days: cfg['days'] as int).inMilliseconds)
          return false;
        final selected = (cfg['selected'] as List).cast<String>().toSet();
        if (selected.isEmpty) throw StateError('请至少选择一项备份内容');
        final backup = await FullBackupService.create(selection: selected);
        try {
          final now = DateTime.now();
          final date = now.toIso8601String().substring(0, 10);
          await channel.invokeMethod<void>('publish', {
            'path': backup.file.path,
            'name': 'SkyTide-backup-$date.zip',
            'selected': selected.map((k) => backupChoices[k]).toList(),
          });
          await DBManager().setKV(
            'auto_backup_last',
            now.millisecondsSinceEpoch.toString(),
          );
          await channel.invokeMethod<void>('prune', {'keep': cfg['keep']});
          await DBManager().setKV('auto_backup_error', '');
          return true;
        } finally {
          await backup.file.parent.delete(recursive: true);
        }
      } finally {
        await channel.invokeMethod<void>('unlock');
      }
    });
  }

  static Future<void> runDue() async {
    try {
      await run();
    } catch (e) {
      await DBManager().setKV('auto_backup_error', e.toString());
    }
  }
}

void startAutoBackupEngine() {
  WidgetsFlutterBinding.ensureInitialized();
  AutoBackupService.channel.setMethodCallHandler((call) async {
    if (call.method != 'run') throw MissingPluginException();
    try {
      await AutoBackupService.run();
      return true;
    } catch (e) {
      await DBManager().setKV('auto_backup_error', e.toString());
      rethrow;
    }
  });
  unawaited(AutoBackupService.channel.invokeMethod<void>('ready'));
}
