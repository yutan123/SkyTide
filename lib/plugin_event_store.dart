import 'db.dart';

/// Best-effort events are claimed once across foreground/background engines.
class PluginEventStore {
  static Future<bool> claim(
    String pluginId,
    String botId,
    String event,
    String messageId,
  ) async {
    final db = await DBManager().database;
    await db.execute(
      'CREATE TABLE IF NOT EXISTS plugin_events ('
      'plugin_id TEXT NOT NULL, bot_id TEXT NOT NULL, event TEXT NOT NULL, '
      'message_id TEXT NOT NULL, created_at INTEGER NOT NULL, '
      'PRIMARY KEY(plugin_id,bot_id,event,message_id))',
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      await txn.rawDelete('DELETE FROM plugin_events WHERE created_at < ?', [
        now - const Duration(days: 7).inMilliseconds,
      ]);
      await txn.rawInsert(
        'INSERT OR IGNORE INTO plugin_events (plugin_id,bot_id,event,message_id,created_at) VALUES (?,?,?,?,?)',
        [pluginId, botId, event, messageId, now],
      );
      final changed = await txn.rawQuery('SELECT changes() AS n');
      return changed.first['n'] == 1;
    });
  }
}
