import 'dart:async';

/// Serializes refreshes and folds requests arriving during a read into one retry.
class CoalescedRefresh {
  CoalescedRefresh(this.refresh);

  final Future<void> Function() refresh;
  Future<void>? _active;
  bool _pending = false;

  Future<void> request() {
    _pending = true;
    return _active ??= Future<void>(_drain);
  }

  Future<void> _drain() async {
    try {
      do {
        _pending = false;
        await refresh();
        await Future<void>.delayed(Duration.zero);
      } while (_pending);
    } finally {
      _active = null;
    }
  }
}
