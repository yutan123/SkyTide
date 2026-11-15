import 'dart:convert';
import 'db.dart';
import 'plugin_coordinator.dart';

/// SQLite owns scheduling; JavaScript timers are never used for durable work.
class PluginTaskStore {
  static Future<void> ensure() async {
    final db = await DBManager().database;
    await db.execute(
      'CREATE TABLE IF NOT EXISTS plugin_tasks ('
      'plugin_id TEXT NOT NULL, id TEXT NOT NULL, bot_id TEXT NOT NULL, '
      'due_at INTEGER NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL, '
      'lease_until INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0, '
      'error TEXT, PRIMARY KEY(plugin_id, id))',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS plugin_tasks_due ON plugin_tasks(state, due_at)',
    );
  }

  static Future<void> schedule(String pluginId, String botId, Map args) async {
    final id = args['id'];
    final due = args['at'];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(id) ||
        due is! int ||
        due < now ||
        due > now + const Duration(days: 365).inMilliseconds) {
      throw const FormatException('任务 id 无效或 at 不在未来一年内');
    }
    final payload = jsonEncode(args['payload']);
    if (utf8.encode(payload).length > 16384)
      throw const FormatException('任务 payload 超过 16 KiB');
    await ensure();
    await PluginCoordinator.locked('plugin-tasks:$pluginId', () async {
      final db = await DBManager().database;
      final count = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM plugin_tasks WHERE plugin_id = ? AND state IN (?, ?)',
        [pluginId, 'pending', 'running'],
      );
      if ((count.first['n'] as int) >= 100)
        throw StateError('每个插件最多保留 100 个活动任务');
      await db.rawInsert(
        'INSERT INTO plugin_tasks (plugin_id,id,bot_id,due_at,payload,state) VALUES (?,?,?,?,?,?)',
        [pluginId, id, botId, due, payload, 'pending'],
      );
    });
  }

  static Future<bool> cancel(String pluginId, String botId, String id) async {
    await ensure();
    final db = await DBManager().database;
    return await db.update(
          'plugin_tasks',
          {'state': 'cancelled'},
          where: 'plugin_id = ? AND bot_id = ? AND id = ? AND state = ?',
          whereArgs: [pluginId, botId, id, 'pending'],
        ) >
        0;
  }

  static Future<List<Map<String, dynamic>>> list(
    String pluginId,
    String botId,
  ) async {
    await ensure();
    final db = await DBManager().database;
    return db.query(
      'plugin_tasks',
      columns: ['id', 'due_at', 'state', 'attempts', 'error'],
      where: 'plugin_id = ? AND bot_id = ?',
      whereArgs: [pluginId, botId],
      orderBy: 'due_at DESC',
      limit: 100,
    );
  }

  static Future<Map<String, dynamic>?> claim() async {
    await ensure();
    final db = await DBManager().database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE plugin_tasks SET state = ? WHERE state = ? AND lease_until < ? AND attempts < 3',
        ['pending', 'running', now],
      );
      await txn.rawUpdate(
        'UPDATE plugin_tasks SET state = ?, error = ? WHERE state = ? AND lease_until < ? AND attempts >= 3',
        ['failed', '任务执行进程中断次数过多', 'running', now],
      );
      final rows = await txn.query(
        'plugin_tasks',
        where: 'state = ? AND due_at <= ?',
        whereArgs: ['pending', now],
        orderBy: 'due_at ASC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      await txn.update(
        'plugin_tasks',
        {
          'state': 'running',
          'lease_until': now + const Duration(minutes: 10).inMilliseconds,
          'attempts': (row['attempts'] as int) + 1,
        },
        where: 'plugin_id = ? AND id = ?',
        whereArgs: [row['plugin_id'], row['id']],
      );
      return {
        ...row,
        'attempts': (row['attempts'] as int) + 1,
        'lease_until': now + const Duration(minutes: 10).inMilliseconds,
      };
    });
  }

  static Future<void> assertClaim(Map task) async {
    final db = await DBManager().database;
    final rows = await db.query(
      'plugin_tasks',
      columns: ['id'],
      where:
          'plugin_id = ? AND id = ? AND state = ? AND attempts = ? AND lease_until = ? AND lease_until > ?',
      whereArgs: [
        task['plugin_id'],
        task['id'],
        'running',
        task['attempts'],
        task['lease_until'],
        DateTime.now().millisecondsSinceEpoch,
      ],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('任务执行权已失效');
  }

  static Future<void> finish(Map task, Object? error) async {
    final db = await DBManager().database;
    final message = error?.toString();
    await db.update(
      'plugin_tasks',
      {
        'state': error == null ? 'completed' : 'failed',
        'error': message?.substring(0, message.length.clamp(0, 2000)),
      },
      where:
          'plugin_id = ? AND id = ? AND state = ? AND attempts = ? AND lease_until = ?',
      whereArgs: [
        task['plugin_id'],
        task['id'],
        'running',
        task['attempts'],
        task['lease_until'],
      ],
    );
    await db.rawDelete(
      'DELETE FROM plugin_tasks WHERE state IN (?, ?, ?) AND due_at < ?',
      [
        'completed',
        'failed',
        'cancelled',
        DateTime.now()
            .subtract(const Duration(days: 30))
            .millisecondsSinceEpoch,
      ],
    );
  }
}
