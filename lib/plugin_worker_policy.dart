import 'dart:async';

/// Bounded, cancellable host waits shared by every invocation of a plugin.
class PluginWaits {
  final _waits = <Timer, Completer<void>>{};
  bool _closed = false;
  Future<void> sleep(Object? value, Future<void> Function() check) async {
    if (value is! int || value < 1 || value > 60000) {
      throw const FormatException('等待时间必须为 1 至 60000 毫秒');
    }
    await check();
    if (_closed) throw StateError('插件已停止');
    if (_waits.length >= 32) throw StateError('最多同时等待 32 个任务');
    final done = Completer<void>();
    late final Timer timer;
    timer = Timer(Duration(milliseconds: value), () {
      _waits.remove(timer);
      done.complete();
    });
    _waits[timer] = done;
    await done.future;
    await check();
  }

  void close() {
    _closed = true;
    for (final entry in _waits.entries) {
      entry.key.cancel();
      entry.value.completeError(StateError('插件已停止'));
    }
    _waits.clear();
  }
}

/// One bounded iteration per dispatch; no detached JS loops or native timers.
class PluginWorkerPolicy {
  static List<Map<String, dynamic>> validate(Object? value) {
    if (value == null) return [];
    if (value is! List || value.length > 8)
      throw const FormatException('workers 最多声明 8 项');
    final names = <String>{};
    return value.map((raw) {
      if (raw is! Map ||
          raw['name'] is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$').hasMatch(raw['name']) ||
          !names.add(raw['name']))
        throw const FormatException('worker 名称无效或重复');
      final interval = raw['intervalMs'] ?? 5000;
      if (interval is! int || interval < 1000 || interval > 86400000)
        throw const FormatException('worker intervalMs 范围为 1000 至 86400000');
      return <String, dynamic>{'name': raw['name'], 'intervalMs': interval};
    }).toList();
  }

  static int backoff(int interval, int failures) =>
      (interval * (1 << failures.clamp(0, 6))).clamp(
        interval,
        interval > 300000 ? interval : 300000,
      );
}
