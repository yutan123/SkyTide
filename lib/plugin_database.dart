import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'db.dart';
import 'plugin_data_policy.dart';

/// Parameterized document collections; plugins never receive SQL or host tables.
class PluginDatabase {
  static Future<void> ensure() async {
    final db = await DBManager().database;
    await db.execute(
      'CREATE TABLE IF NOT EXISTS plugin_documents (plugin_id TEXT NOT NULL, collection TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, vector TEXT, updated_at INTEGER NOT NULL, PRIMARY KEY(plugin_id,collection,key))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS plugin_data_versions (plugin_id TEXT PRIMARY KEY, version INTEGER NOT NULL)',
    );
  }

  static Future<dynamic> call(
    String plugin,
    String method,
    Map args,
    Future<void> Function() check,
  ) async {
    await ensure();
    await check();
    final db = await DBManager().database;
    return db.transaction((txn) async {
      await check();
      if (method == 'database.version') {
        final rows = await txn.query(
          'plugin_data_versions',
          where: 'plugin_id = ?',
          whereArgs: [plugin],
        );
        await check();
        return rows.isEmpty ? 0 : rows.first['version'];
      }
      if (method == 'database.batch' || method == 'database.migrate') {
        final ops = args['operations'];
        if (ops is! List || ops.isEmpty || ops.length > 100)
          throw const FormatException('批量操作数量必须为 1 至 100');
        if (method == 'database.migrate') {
          final from = args['from'], to = args['to'];
          if (from is! int ||
              to is! int ||
              from < 0 ||
              to <= from ||
              to > 10000)
            throw const FormatException('迁移版本无效');
          final rows = await txn.query(
            'plugin_data_versions',
            where: 'plugin_id = ?',
            whereArgs: [plugin],
          );
          final current = rows.isEmpty ? 0 : rows.first['version'];
          if (current != from) {
            await check();
            return false;
          }
          await txn.rawInsert(
            'INSERT OR REPLACE INTO plugin_data_versions(plugin_id,version) VALUES (?,?)',
            [plugin, to],
          );
        }
        final results = <dynamic>[];
        for (final op in ops) {
          if (op is! Map || !{'get', 'put', 'delete'}.contains(op['operation']))
            throw const FormatException('无效的批量操作');
          results.add(
            await _one(txn, plugin, 'database.${op['operation']}', op),
          );
        }
        await _quota(txn, plugin);
        if (utf8.encode(jsonEncode(results)).length > 512 * 1024)
          throw StateError('批量结果超过 512 KiB');
        await check();
        return method == 'database.migrate' ? true : results;
      }
      final result = await _one(txn, plugin, method, args);
      if (method == 'database.put') await _quota(txn, plugin);
      await check();
      return result;
    });
  }

  static Future<void> _quota(DatabaseExecutor db, String plugin) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n, COALESCE(SUM(length(CAST(value AS BLOB)) + COALESCE(length(CAST(vector AS BLOB)),0) + length(CAST(key AS BLOB)) + length(collection)),0) AS size FROM plugin_documents WHERE plugin_id = ?',
      [plugin],
    );
    if ((rows.first['n'] as int) > 10000 ||
        (rows.first['size'] as int) > 32 * 1024 * 1024)
      throw StateError('插件数据库超过 10000 条或 32 MiB');
  }

  static Future<dynamic> _one(
    DatabaseExecutor db,
    String plugin,
    String method,
    Map args,
  ) async {
    final collection = PluginDataPolicy.name(args['collection']);
    if (method == 'database.query' || method == 'database.search') {
      final limit = args['limit'] ?? 50;
      if (limit is! int || limit < 1 || limit > 100)
        throw const FormatException('limit 范围为 1 至 100');
      if (method == 'database.search') {
        final vector = PluginDataPolicy.vector(args['vector']);
        final rows = await db.query(
          'plugin_documents',
          columns: ['key', 'vector'],
          where: 'plugin_id = ? AND collection = ? AND vector IS NOT NULL',
          whereArgs: [plugin, collection],
          limit: 1001,
        );
        if (rows.length > 1000) throw StateError('单集合向量检索最多 1000 条，请拆分集合');
        final result = rows
            .map(
              (row) => <String, dynamic>{
                'key': row['key'],
                'score': PluginDataPolicy.similarity(
                  vector,
                  (jsonDecode(row['vector'] as String) as List)
                      .map((n) => (n as num).toDouble())
                      .toList(),
                ),
              },
            )
            .toList();
        result.sort(
          (a, b) => (b['score'] as double).compareTo(a['score'] as double),
        );
        final selected = <Map<String, dynamic>>[];
        var bytes = 0;
        for (final item in result.take(limit)) {
          final docs = await db.query(
            'plugin_documents',
            columns: ['value'],
            where: 'plugin_id = ? AND collection = ? AND key = ?',
            whereArgs: [plugin, collection, item['key']],
          );
          item['value'] = jsonDecode(docs.single['value'] as String);
          bytes += utf8.encode(jsonEncode(item)).length;
          if (bytes > 512 * 1024) break;
          selected.add(item);
        }
        return selected;
      }
      final prefix = args['prefix'] ?? '', after = args['after'] ?? '';
      if (prefix is! String ||
          after is! String ||
          prefix.length > 256 ||
          after.length > 256)
        throw const FormatException('prefix/after 无效');
      final rows = await db.query(
        'plugin_documents',
        columns: ['key', 'value', 'updated_at'],
        where:
            'plugin_id = ? AND collection = ? AND key > ? AND substr(key,1,?) = ?',
        whereArgs: [plugin, collection, after, prefix.runes.length, prefix],
        orderBy: 'key ASC',
        limit: limit,
      );
      final result = <Map<String, dynamic>>[];
      var bytes = 0;
      for (final row in rows) {
        final item = <String, dynamic>{
          'key': row['key'],
          'value': jsonDecode(row['value'] as String),
          'updatedAt': row['updated_at'],
        };
        bytes += utf8.encode(jsonEncode(item)).length + 1;
        if (bytes > 512 * 1024 - 2) break;
        result.add(item);
      }
      return result;
    }
    final key = PluginDataPolicy.key(args['key']);
    const where = 'plugin_id = ? AND collection = ? AND key = ?';
    final values = [plugin, collection, key];
    if (method == 'database.get') {
      final rows = await db.query(
        'plugin_documents',
        columns: ['value'],
        where: where,
        whereArgs: values,
      );
      return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
    }
    if (method == 'database.delete')
      return await db.delete(
            'plugin_documents',
            where: where,
            whereArgs: values,
          ) >
          0;
    if (method == 'database.put') {
      final value = PluginDataPolicy.encode(args['value']);
      final vector = args['vector'] == null
          ? null
          : jsonEncode(PluginDataPolicy.vector(args['vector']));
      if (vector != null) {
        final existing = await db.query(
          'plugin_documents',
          columns: ['vector'],
          where:
              'plugin_id = ? AND collection = ? AND vector IS NOT NULL AND key != ?',
          whereArgs: [plugin, collection, key],
          limit: 1,
        );
        if (existing.isNotEmpty &&
            (jsonDecode(existing.first['vector'] as String) as List).length !=
                (jsonDecode(vector) as List).length)
          throw const FormatException('集合向量维度不一致');
      }
      await db.rawInsert(
        'INSERT OR REPLACE INTO plugin_documents(plugin_id,collection,key,value,vector,updated_at) VALUES (?,?,?,?,?,?)',
        [
          plugin,
          collection,
          key,
          value,
          vector,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      return null;
    }
    throw StateError('未知数据库接口');
  }

  static Future<void> delete(String plugin) async {
    await ensure();
    final db = await DBManager().database;
    await db.transaction((txn) async {
      await txn.delete(
        'plugin_documents',
        where: 'plugin_id = ?',
        whereArgs: [plugin],
      );
      await txn.delete(
        'plugin_data_versions',
        where: 'plugin_id = ?',
        whereArgs: [plugin],
      );
    });
  }
}
