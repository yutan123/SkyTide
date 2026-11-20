import 'dart:async';
import 'package:skytide/coalesced_refresh.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  var calls = 0;
  var concurrent = 0;
  var peak = 0;
  final firstEntered = Completer<void>();
  final release = Completer<void>();
  final refresh = CoalescedRefresh(() async {
    calls++;
    concurrent++;
    if (concurrent > peak) peak = concurrent;
    if (calls == 1) {
      firstEntered.complete();
      await release.future;
    }
    concurrent--;
  });
  final first = refresh.request();
  for (var i = 0; i < 100; i++) {
    check(identical(first, refresh.request()), 'Burst must share one future');
  }
  await firstEntered.future;
  check(calls == 1, 'Burst must start one read');
  for (var i = 0; i < 100; i++) {
    refresh.request();
  }
  release.complete();
  await first;
  check(calls == 2, 'Changes during a read must trigger exactly one retry');
  check(peak == 1, 'Reads must never overlap');
  await refresh.request();
  check(calls == 3, 'A completed refresh must allow another read');

  var fail = true;
  final recovery = CoalescedRefresh(() async {
    if (fail) throw StateError('expected');
  });
  var caught = false;
  try {
    await recovery.request();
  } on StateError {
    caught = true;
  }
  check(caught, 'Errors must reach callers');
  fail = false;
  await recovery.request();
  print('Coalesced refresh burst, retry, serialization and recovery passed.');
}
