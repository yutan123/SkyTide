import 'dart:async';
import 'dart:math';
import 'db.dart';
import 'plugin_worker_policy.dart';

/// SQLite leases coordinate worker callbacks across foreground/background engines.
class PluginWorkerRunner {
  PluginWorkerRunner({
    required this.pluginId,
    required this.specs,
    required this.check,
    required this.dispatch,
    required this.log,
    required this.lost,
  });
  final String pluginId;
  final List<Map<String, dynamic>> specs;
  final Future<void> Function() check;
  final Future<dynamic> Function(String name, String token) dispatch;
  final void Function(String) log;
  final void Function() lost;
  final owner = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _active = <String>{};
  final _states = <String, Map<String, dynamic>>{};
  Timer? _timer;
  bool _closed = false, _ticking = false;
  static Future<void> ensure() async {
    final db = await DBManager().database;
    await db.execute(
      'CREATE TABLE IF NOT EXISTS plugin_workers (plugin_id TEXT NOT NULL, name TEXT NOT NULL, owner TEXT, lease_until INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(plugin_id,name))',
    );
  }

  Future<void> start() async {
    await ensure();
    if (_closed) return;
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_tick()),
    );
    unawaited(_tick());
  }

  List<Map<String, dynamic>> get status => specs
      .map((s) => <String, dynamic>{...s, ...?_states[s['name']]})
      .toList();
  String _token(String name) => '$owner:$name';
  Future<void> assertToken(Object? token) async {
    final name = token is String && token.startsWith('$owner:')
        ? token.substring(owner.length + 1)
        : '';
    if (_closed || !_active.contains(name)) throw StateError('常驻任务执行权已失效');
    await check();
    final db = await DBManager().database;
    final rows = await db.query(
      'plugin_workers',
      columns: ['name'],
      where: 'plugin_id = ? AND name = ? AND owner = ? AND lease_until > ?',
      whereArgs: [pluginId, name, owner, DateTime.now().millisecondsSinceEpoch],
    );
    if (rows.isEmpty) {
      lost();
      throw StateError('常驻任务租约已失效');
    }
  }

  Future<void> _tick() async {
    if (_closed || _ticking) return;
    _ticking = true;
    try {
      await check();
      final db = await DBManager().database;
      for (final spec in specs) {
        if (_closed) break;
        final now = DateTime.now().millisecondsSinceEpoch;
        final name = spec['name'] as String;
        if (_active.contains(name)) {
          final renewed = await db.rawUpdate(
            'UPDATE plugin_workers SET lease_until = ? WHERE plugin_id = ? AND name = ? AND owner = ? AND lease_until > ?',
            [now + 30000, pluginId, name, owner, now],
          );
          if (renewed == 0) {
            _states[name] = {'state': 'lost'};
            lost();
            break;
          }
          continue;
        }
        final acquired = await db.transaction((txn) async {
          await check();
          if (_closed) return false;
          await txn.rawInsert(
            'INSERT OR IGNORE INTO plugin_workers(plugin_id,name) VALUES (?,?)',
            [pluginId, name],
          );
          final changed =
              await txn.rawUpdate(
                'UPDATE plugin_workers SET owner = ?, lease_until = ? WHERE plugin_id = ? AND name = ? AND lease_until <= ? AND next_at <= ?',
                [owner, now + 30000, pluginId, name, now, now],
              ) ==
              1;
          await check();
          return changed;
        });
        if (!acquired) continue;
        if (_closed) {
          await db.rawUpdate(
            'UPDATE plugin_workers SET owner = NULL, lease_until = 0 WHERE plugin_id = ? AND name = ? AND owner = ?',
            [pluginId, name, owner],
          );
          break;
        }
        _active.add(name);
        unawaited(_run(name, spec['intervalMs'] as int));
      }
    } catch (error) {
      if (!_closed) log('常驻任务调度失败：$error');
    } finally {
      _ticking = false;
    }
  }

  Future<void> _run(String name, int interval) async {
    Object? failure;
    _states[name] = {
      'state': 'running',
      'startedAt': DateTime.now().millisecondsSinceEpoch,
    };
    try {
      await assertToken(_token(name));
      await dispatch(name, _token(name));
      await assertToken(_token(name));
    } catch (error) {
      failure = error;
      if (!_closed) log('Worker $name：$error');
    } finally {
      try {
        final db = await DBManager().database;
        await db.transaction((txn) async {
          final rows = await txn.query(
            'plugin_workers',
            where: 'plugin_id = ? AND name = ? AND owner = ?',
            whereArgs: [pluginId, name, owner],
          );
          if (rows.isEmpty) return;
          final failures = failure == null
              ? 0
              : (rows.first['failures'] as int) + 1;
          final next =
              DateTime.now().millisecondsSinceEpoch +
              (failure == null
                  ? interval
                  : PluginWorkerPolicy.backoff(interval, failures));
          await txn.update(
            'plugin_workers',
            {
              'owner': null,
              'lease_until': 0,
              'next_at': next,
              'failures': failures,
            },
            where: 'plugin_id = ? AND name = ? AND owner = ?',
            whereArgs: [pluginId, name, owner],
          );
          _states[name] = {
            'state': failure == null ? 'waiting' : 'retrying',
            'nextAt': next,
            'failures': failures,
            if (failure != null)
              'error': failure.toString().substring(
                0,
                failure.toString().length.clamp(0, 2000),
              ),
          };
        });
      } catch (error) {
        if (!_closed) log('Worker 清理失败：$error');
      }
      _active.remove(name);
    }
  }

  static Future<void> delete(String plugin) async {
    await ensure();
    final db = await DBManager().database;
    await db.delete(
      'plugin_workers',
      where: 'plugin_id = ?',
      whereArgs: [plugin],
    );
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    // Running leases expire rather than releasing work still in flight.
  }
}
