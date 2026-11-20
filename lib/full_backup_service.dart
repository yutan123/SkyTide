import 'backup_credential_cipher.dart';
import 'model_credential_codec.dart';
import 'model_credentials.dart';
import 'plugin_backup_data.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'data_transfer.dart';
import 'json_records.dart';
import 'transfer_media.dart';
import 'db.dart';

class FullBackupService {
  static const _dbName = 'tidebot.db';
  static const _archiveDbName = 'skytide.db';
  static const _voiceSamples = 'mimo_voice_samples';
  static const _native = MethodChannel('skytide.native.channel');
  static Future<void> restartToApply() =>
      _native.invokeMethod<void>('restartForRestore');

  static Future<({String name, File file})> create({
    Set<String>? selection,
  }) async {
    final work = await DataTransfer.workspace();
    try {
      final db = await DBManager().database;
      final dbPath = '${await getDatabasesPath()}/$_dbName';
      final snapshot = File('${work.path}/$_dbName');
      final docs = await getApplicationDocumentsDirectory();
      final files = <String, String>{_archiveDbName: snapshot.path};
      if (await docs.exists()) {
        await for (final item in docs.list(
          recursive: true,
          followLinks: false,
        )) {
          if (item is! File) continue;
          final relative = p.relative(item.path, from: docs.path);
          if (relative.startsWith('memory_embedding/') ||
              relative.startsWith('models/') ||
              relative == 'skytide_dev_logs.json' ||
              relative.startsWith('SkyTide/exports/'))
            continue;
          files['documents/$relative'] = item.path;
        }
      }
      final support = await getApplicationSupportDirectory();
      final pluginDirectories = <String>[];
      final supportDirectories = [
        if (selection == null || selection.contains('plugins'))
          ...PluginBackupData.supportDirectories,
        if (selection == null || selection.contains('media')) _voiceSamples,
      ];
      for (final name in supportDirectories) {
        final directory = Directory(p.join(support.path, name));
        if (!await directory.exists()) continue;
        await for (final item in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          final relative = p.relative(item.path, from: directory.path);
          if (name == PluginBackupData.privateFiles) {
            if (!PluginBackupData.isSafeDirectory(relative)) continue;
            if (item is Directory) pluginDirectories.add(relative);
          }
          if (item is File) files['support/$name/$relative'] = item.path;
        }
      }
      final dbSize = await File(dbPath).length();
      final wal = File('$dbPath-wal');
      final walSize = await wal.exists() ? await wal.length() : 0;
      await DataTransfer.ensureSpace(
        work,
        await DataTransfer.totalBytes(
              files.values.where((v) => v != snapshot.path),
            ) +
            2 * (dbSize + walSize),
      );
      var snapshotSecrets = <String, String>{};
      // Freeze writers while copying DB and WAL; works with older SQLite too.
      await db.transaction((txn) async {
        await File(dbPath).copy(snapshot.path);
        if (await wal.exists()) await wal.copy('${snapshot.path}-wal');
        snapshotSecrets = await ModelCredentials.storage.readAll();
      }, exclusive: true);
      final copy = await openDatabase(snapshot.path, singleInstance: false);
      final referenced = <String>{};
      try {
        final result = await copy.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
        if (result.isNotEmpty && (result.first.values.first as num) != 0) {
          throw StateError('数据库快照忙，请稍后重试');
        }
        if (selection != null) {
          await copy.execute('PRAGMA foreign_keys = OFF');
          const groups = {
            'chat': [
              'call_messages',
              'call_sessions',
              'voice_call_records',
              'chat_history',
            ],
            'memory': [
              'memory_vectors',
              'world_book_entries',
              'world_books',
              'memories',
            ],
            'posts': ['feed_events', 'post_comments', 'posts'],
            'diaries': ['bot_diaries', 'bot_life_schedules', 'schedule_tasks'],
            'stickers': ['stickers'],
            'plugins': [
              'skill_tools',
              'skills',
              'mcp_tools',
              'mcp_servers',
              'plugins',
              'plugin_documents',
              'plugin_data_versions',
            ],
          };
          final tables = (await copy.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table'",
          )).map((row) => row['name'] as String).toSet();
          for (final group in groups.entries) {
            if (selection.contains(group.key)) continue;
            for (final table in group.value) {
              if (tables.contains(table)) await copy.delete(table);
            }
          }
          // Runtime queues, diagnostics and derived vectors are never user backups.
          for (final table in [
            'background_tasks',
            'background_task_executions',
            'background_messages',
            'foreground_message_events',
            'tool_audit',
            'memory_vectors',
            'media_storage_garbage',
            'plugin_tasks',
            'plugin_workers',
            'plugin_events',
            'media_storage_jobs',
            'media_storage_uses',
            'media_storage_worker',
          ]) {
            if (tables.contains(table)) await copy.delete(table);
          }
          if (tables.contains('kv_store')) {
            const toolKeys =
                "(key GLOB 'plugin_*' OR key GLOB 'skill_*' OR key GLOB 'mcp_*')";
            if (!selection.contains('settings')) {
              await copy.delete(
                'kv_store',
                where: selection.contains('plugins') ? 'NOT $toolKeys' : null,
              );
            } else if (!selection.contains('plugins')) {
              await copy.delete('kv_store', where: toolKeys);
            }
          }
          if (tables.contains('kv_store')) {
            await copy.delete(
              'kv_store',
              where: "substr(key, 1, 12) = ?",
              whereArgs: ['auto_backup_'],
            );
          }
          // Read only retained records to decide which document files to include.
          if (selection.contains('media')) {
            for (final table in tables.where((t) => !t.startsWith('sqlite_'))) {
              var offset = 0;
              while (true) {
                final rows = await copy.query(
                  table,
                  limit: 200,
                  offset: offset,
                );
                if (rows.isEmpty) break;
                for (final row in rows) {
                  await mapTransferValue(row, (path) async {
                    if (p.isAbsolute(path) && p.isWithin(docs.path, path))
                      referenced.add(p.normalize(path));
                    return path;
                  });
                }
                offset += rows.length;
              }
            }
          }
          await copy.execute('VACUUM');
        }
      } finally {
        await copy.close();
      }
      final credentialDb = await openDatabase(
        snapshot.path,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final credentials = <String, String>{};
        if (selection == null || selection.contains('plugins')) {
          final pluginKeys = await _pluginStorageKeys(credentialDb);
          final pluginData = File(p.join(work.path, 'plugin_data.json'));
          await pluginData.writeAsString(
            await BackupCredentialCipher.encrypt({
              PluginBackupData.directoryList: jsonEncode(pluginDirectories),
              for (final entry in snapshotSecrets.entries)
                if (pluginKeys.contains(entry.key)) entry.key: entry.value,
            }),
          );
          files['plugin_data.json'] = pluginData.path;
          final retained = <String>{
            for (final row in await credentialDb.query('mcp_servers'))
              'mcp_headers_${row['id']}',
            for (final row in await credentialDb.query('skills'))
              'skill_headers_${row['id']}',
          };
          final stored = snapshotSecrets;
          for (final entry in stored.entries) {
            if (retained.contains(entry.key))
              credentials[entry.key] = entry.value;
          }
        }
        if (selection == null || selection.contains('settings')) {
          for (final row in await credentialDb.query('kv_store')) {
            if (!ModelCredentials.handles(row['key'] as String)) continue;
            void collect(dynamic node) {
              if (node is String &&
                  node.startsWith(
                    '${ModelCredentials.reference}${ModelCredentials.prefix}',
                  )) {
                credentials.putIfAbsent(
                  node.substring(ModelCredentials.reference.length),
                  () => '',
                );
              } else if (node is List) {
                node.forEach(collect);
              } else if (node is Map) {
                node.values.forEach(collect);
              }
            }

            collect(
              jsonDecode(
                ModelCredentialCodec.configuration(
                  row['key'] as String,
                  row['value'] as String,
                ),
              ),
            );
          }
          for (final key in credentials.keys.toList()) {
            if (!key.startsWith(ModelCredentials.prefix)) continue;
            final secret = snapshotSecrets[key];
            if (secret == null) throw StateError('模型密钥缺失，无法创建完整备份');
            credentials[key] = secret;
          }
        }
        final credentialFile = File('${work.path}/tool_credentials.json');
        await credentialFile.writeAsString(
          await BackupCredentialCipher.encrypt(credentials),
        );
        files['tool_credentials.json'] = credentialFile.path;
      } finally {
        await credentialDb.close();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (selection != null &&
          selection.contains('settings') &&
          selection.contains('media')) {
        for (final key in prefs.getKeys()) {
          await mapTransferValue(prefs.get(key), (path) async {
            if (p.isAbsolute(path) &&
                p.isWithin(docs.path, path) &&
                await File(path).exists()) {
              referenced.add(p.normalize(path));
            }
            return path;
          });
        }
      }
      if (selection != null) {
        files.removeWhere((key, path) {
          if (!key.startsWith('documents/')) return false;
          final relative = p.relative(path, from: docs.path);
          final pluginFile =
              relative.startsWith('plugins/') || relative.startsWith('skills/');
          return pluginFile
              ? !selection.contains('plugins')
              : !selection.contains('media') ||
                    !referenced.contains(p.normalize(path));
        });
        final manifest = File('${work.path}/backup_manifest.json');
        await manifest.writeAsString(
          jsonEncode({
            'format': 1,
            'kind': 'automatic',
            'created': DateTime.now().toIso8601String(),
            'selection': selection.toList(),
            'alwaysIncluded': ['bots'],
            'restoreMode': 'replace',
          }),
        );
        files['backup_manifest.json'] = manifest.path;
      }
      final preferences = File('${work.path}/preferences.json');
      final sink = preferences.openWrite();
      try {
        sink.write('{');
        var first = true;
        for (final key in prefs.getKeys()) {
          if (selection != null &&
              (!selection.contains('settings') ||
                  key.startsWith('auto_backup_')))
            continue;
          if (!first) sink.write(',');
          first = false;
          sink.write('${jsonEncode(key)}:${jsonEncode(prefs.get(key))}');
          await sink.flush();
        }
        sink.write('}');
      } finally {
        await sink.close();
      }
      files['preferences.json'] = preferences.path;
      final name =
          'skytide_backup_${DateTime.now().millisecondsSinceEpoch}.zip';
      final file = File('${work.path}/$name');
      await DataTransfer.ensureSpace(
        work,
        await DataTransfer.totalBytes(files.values),
      );
      await DataTransfer.zip(file.path, files);
      return (name: name, file: file);
    } catch (_) {
      await work.delete(recursive: true);
      rethrow;
    }
  }

  static Future<bool> export() => DataTransfer.exclusive(() async {
    final backup = await create();
    try {
      return await DataTransfer.save(
            backup.file,
            backup.name,
            'application/zip',
          ) !=
          null;
    } finally {
      await backup.file.parent.delete(recursive: true);
    }
  });

  static Future<bool> restore() => DataTransfer.exclusive(() async {
    return await DataTransfer.pickImport<bool>(const ['zip'], (path) async {
          final work = await DataTransfer.workspace();
          try {
            await DataTransfer.extract(path, work.path);
            final source = File('${work.path}/$_dbName');
            final archiveDb = File('${work.path}/$_archiveDbName');
            if (await archiveDb.exists()) await archiveDb.rename(source.path);
            final preferences = File('${work.path}/preferences.json');
            if (!await source.exists() || !await preferences.exists()) {
              throw const FormatException('不是有效的 SkyTide 完整备份');
            }
            // Validate one preference at a time; retaining the complete decoded map
            // doubled the live preferences during a full restore.
            await for (final record in JsonRecords.read(
              preferences,
              arrays: const {},
            )) {
              final value = record.value;
              if (value is! bool &&
                  value is! num &&
                  value is! String &&
                  !(value is List && value.every((item) => item is String))) {
                throw const FormatException('备份设置格式无效');
              }
            }
            final check = await openDatabase(
              source.path,
              readOnly: true,
              singleInstance: false,
            );
            try {
              final result = await check.rawQuery('PRAGMA quick_check');
              if (result.length != 1 || result.first.values.first != 'ok') {
                throw const FormatException('备份数据库损坏');
              }
            } finally {
              await check.close();
            }
            final docs = await getApplicationDocumentsDirectory();
            final restoredPaths = RestoredDocuments(
              Directory('${work.path}/documents'),
              docs,
            );
            final support = await getApplicationSupportDirectory();
            final restoredSupport = Directory('${work.path}/support');
            Future<String> mapRestoredPath(String original) async {
              final mapped = await restoredPaths.mapPath(original);
              if (mapped != original) return mapped;
              for (final name in [
                ...PluginBackupData.supportDirectories,
                _voiceSamples,
              ]) {
                final staged = Directory(p.join(restoredSupport.path, name));
                final target = await ImportedMedia(
                  staged,
                  prefix: name,
                ).mapPath(original);
                if (target != original && p.isWithin(staged.path, target)) {
                  return p.join(
                    support.path,
                    name,
                    p.relative(target, from: staged.path),
                  );
                }
              }
              return original;
            }

            await _relocateDatabase(source, mapRestoredPath);
            final mappedPreferences = File(
              '${work.path}/restored_preferences.json',
            );
            final mappedSink = mappedPreferences.openWrite();
            try {
              mappedSink.write('{');
              var first = true;
              await for (final record in JsonRecords.read(
                preferences,
                arrays: const {},
              )) {
                if (!first) mappedSink.write(',');
                first = false;
                final value = await mapTransferValue(
                  record.value,
                  mapRestoredPath,
                );
                mappedSink.write(
                  '${jsonEncode(record.key)}:${jsonEncode(value)}',
                );
                await mappedSink.flush();
              }
              mappedSink.write('}');
            } finally {
              await mappedSink.close();
            }
            await DataTransfer.ensureSpace(
              docs,
              await DataTransfer.directoryBytes(work),
            );
            final credentialFile = File('${work.path}/tool_credentials.json');
            final hasCredentials = await credentialFile.exists();
            final restoredCredentials = <String, String>{};
            if (hasCredentials) {
              final decoded = await BackupCredentialCipher.decrypt(
                await credentialFile.readAsString(),
              );
              if (decoded.entries.any(
                (entry) =>
                    !(entry.key.toString().startsWith('mcp_headers_') ||
                        entry.key.toString().startsWith('skill_headers_') ||
                        entry.key.toString().startsWith(
                          ModelCredentials.prefix,
                        )),
              )) {
                throw const FormatException('工具鉴权备份格式无效');
              }
              restoredCredentials.addAll(Map<String, String>.from(decoded));
              for (final entry in decoded.entries) {
                if (entry.key.toString().startsWith(ModelCredentials.prefix))
                  continue;
                final headers = jsonDecode(entry.value);
                if (headers is! Map ||
                    headers.entries.any(
                      (entry) => entry.key is! String || entry.value is! String,
                    )) {
                  throw const FormatException('工具鉴权请求头格式无效');
                }
              }
            }
            final pluginData = File(p.join(work.path, 'plugin_data.json'));
            final hasPluginData = await pluginData.exists();
            final privateFiles = Directory(
              p.join(restoredSupport.path, PluginBackupData.privateFiles),
            );
            final credentialCheck = await openDatabase(
              source.path,
              readOnly: true,
              singleInstance: false,
            );
            try {
              if (hasPluginData) {
                final allowed = await _pluginStorageKeys(credentialCheck);
                final decoded = await BackupCredentialCipher.decrypt(
                  await pluginData.readAsString(),
                  allowLegacyPlaintext: false,
                );
                final directories = jsonDecode(
                  decoded.remove(PluginBackupData.directoryList) ?? '[]',
                );
                if (directories is! List ||
                    directories.any(
                      (value) =>
                          value is! String ||
                          !PluginBackupData.isSafeDirectory(value),
                    )) {
                  throw const FormatException('插件目录备份格式无效');
                }
                for (final relative in directories.cast<String>()) {
                  await Directory(
                    p.join(privateFiles.path, relative),
                  ).create(recursive: true);
                }
                for (final entry in decoded.entries) {
                  if (!allowed.contains(entry.key) ||
                      jsonDecode(entry.value) is! Map) {
                    throw const FormatException('插件设置备份格式无效');
                  }
                  restoredCredentials[entry.key] = entry.value;
                }
                restoredCredentials[PluginBackupData.restoredMarker] = '1';
                await privateFiles.create(recursive: true);
              } else if (await privateFiles.exists()) {
                throw const FormatException('插件私有文件缺少对应备份记录');
              }
              for (final row in await credentialCheck.query('kv_store')) {
                if (!ModelCredentials.handles(row['key'] as String)) continue;
                await ModelCredentialCodec.resolveKey(
                  row['key'] as String,
                  row['value'] as String,
                  (key) async => restoredCredentials[key],
                );
              }
            } finally {
              await credentialCheck.close();
            }
            await _requireReauthorization(
              source,
              hasCredentials: hasCredentials,
            );
            // Only the private restore workspace contains decoded credentials.
            // The published ZIP always contains the encrypted envelope.
            if (hasCredentials || hasPluginData) {
              await credentialFile.writeAsString(
                jsonEncode(restoredCredentials),
                flush: true,
              );
            }
            await _native.invokeMethod<bool>('stageFullRestore', {
              'path': work.path,
            });
            return true;
          } finally {
            await work.delete(recursive: true);
          }
        }) ??
        false;
  });

  static Future<Set<String>> _pluginStorageKeys(Database db) async {
    final tables = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'plugins'",
    );
    if (tables.isEmpty) return {};
    final rows = await db.query('plugins', columns: ['id']);
    return PluginBackupData.keysFor(rows.map((row) => row['id'] as String));
  }

  // Rewrite only the extracted snapshot, before touching live data. Bounded
  // pages keep large chat databases from being retained in memory.
  static Future<void> _relocateDatabase(
    File source,
    Future<String> Function(String) mapPath,
  ) async {
    final db = await openDatabase(source.path, singleInstance: false);
    String quote(String name) => '"${name.replaceAll('"', '""')}"';
    try {
      await db.transaction((txn) async {
        final tables = await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        );
        for (final table in tables) {
          final tableName = table['name'] as String;
          final name = quote(tableName);
          // Process-local leases must never survive restoration.
          if (tableName == 'media_storage_uses' ||
              tableName == 'media_storage_worker') {
            await txn.delete(tableName);
            continue;
          }
          var offset = 0;
          while (true) {
            final rows = await txn.rawQuery(
              'SELECT rowid AS "__transfer_rowid__", * FROM $name ORDER BY rowid LIMIT 100 OFFSET ?',
              [offset],
            );
            if (rows.isEmpty) break;
            for (final row in rows) {
              final updates = <String, Object?>{};
              for (final entry in row.entries) {
                if (entry.key == '__transfer_rowid__' || entry.value is! String)
                  continue;
                final mapped = await mapTransferValue(entry.value, mapPath);
                if (mapped != entry.value) updates[entry.key] = mapped;
              }
              if (updates.isNotEmpty) {
                await txn.rawUpdate(
                  'UPDATE $name SET ${updates.keys.map((key) => '${quote(key)} = ?').join(', ')} WHERE rowid = ?',
                  [...updates.values, row['__transfer_rowid__']],
                );
              }
            }
            offset += rows.length;
          }
        }
      });
      final result = await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      if (result.isNotEmpty && result.first.values.first != 0) {
        throw StateError('恢复数据库忙，请稍后重试');
      }
    } finally {
      await db.close();
    }
  }

  static Future<void> _requireReauthorization(
    File source, {
    required bool hasCredentials,
  }) async {
    final db = await openDatabase(source.path, singleInstance: false);
    try {
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).toSet();
      await db.transaction((txn) async {
        if (tables.contains('plugins')) {
          await txn.update('plugins', {'enabled': 0});
        }
        for (final table in ['plugin_workers', 'plugin_events']) {
          if (tables.contains(table)) await txn.delete(table);
        }
        if (tables.contains('plugin_tasks')) {
          await txn.update('plugin_tasks', {
            'state': 'cancelled',
            'lease_until': 0,
            'error': '备份恢复后需重新授权并创建任务',
          }, where: "state IN ('pending', 'running')");
        }
        if (tables.contains('mcp_servers')) {
          await txn.update('mcp_servers', {
            if (!hasCredentials) 'enabled': 0,
            'status': 'disconnected',
            'error': hasCredentials ? null : '旧备份不包含鉴权凭据，请重新填写后启用',
          });
        }
        if (!hasCredentials && tables.contains('skill_tools')) {
          await txn.update('skill_tools', {
            'enabled': 0,
            'authorized': 0,
          }, where: "executor IN ('http', 'mcp_proxy')");
        }
        if (tables.contains('voice_call_records')) {
          await txn.update('voice_call_records', {
            'status': 'ended',
          }, where: "status IN ('ringing', 'active')");
          await txn.update(
            'chat_history',
            {'call_status': 'ended', 'content': '[语音通话，已结束]'},
            where:
                "type = 'voice_call_card' AND call_status IN ('ringing', 'active')",
          );
        }
      });
      final checkpoint = await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      if (checkpoint.isNotEmpty && checkpoint.first.values.first != 0) {
        throw StateError('备份数据库忙，请重新导入');
      }
    } finally {
      await db.close();
    }
  }
}
