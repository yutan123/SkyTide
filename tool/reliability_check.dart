import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:skytide/ota_daily_check.dart';
import 'package:skytide/plugin_market_routes.dart';
import 'package:skytide/tool_completion.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Future<void> rejects<E>(FutureOr<void> Function() action, String label) async {
  try {
    await action();
  } catch (error) {
    if (error is E) return;
    rethrow;
  }
  throw StateError(label);
}

Future<void> checkTools() async {
  final call = {
    'id': 'call_1',
    'function': {'name': 'choose_silence', 'arguments': '{}'},
  };
  String choice({String? reason, bool stream = true}) => jsonEncode({
    'choices': [
      {
        if (reason != null) 'finish_reason': reason,
        stream ? 'delta' : 'message': {
          'tool_calls': [call],
        },
      },
    ],
  });
  final first = 'data: ${choice()}\n\n';
  Future<(Map<String, dynamic>, bool)> read(String body) =>
      readToolCompletion(Stream.value(utf8.encode(body)));
  await rejects<FormatException>(() => read(first), 'truncated SSE accepted');
  await rejects<FormatException>(
    () => read('data: ${choice(reason: 'length')}\n\ndata: [DONE]\n\n'),
    'truncated choice accepted despite finish_reason',
  );
  await rejects<FormatException>(
    () => read(choice(reason: 'content_filter', stream: false)),
    'blocked JSON tool call accepted',
  );
  for (final valid in [
    '$first\ndata: [DONE]\n\n',
    'data: ${choice(reason: 'tool_calls')}\n\n',
    choice(stream: false),
  ]) {
    final (decoded, _) = await read(valid);
    check(
      decoded['choices'].first['message']['tool_calls'].length == 1,
      'valid tool call was lost',
    );
  }
  final ran = <String>[];
  final completed = await runToolBatch(['write', 'choose_silence', 'send'], (
    name,
  ) async {
    ran.add(name);
    return name != 'choose_silence';
  });
  check(
    !completed && ran.join(',') == 'write,choose_silence',
    'silence did not stop the batch',
  );
}

Future<void> checkMarket() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final paths = <String>[];
  final held = Completer<void>();
  server.listen((request) async {
    paths.add(request.uri.path);
    if (request.uri.path == '/hold') {
      request.response.write('partial');
      await request.response.flush();
      if (!held.isCompleted) held.complete();
      return;
    }
    request.response.write(switch (request.uri.path) {
      '/html' => '<html>gateway error</html>',
      '/wrong' => '{"unexpected":true}',
      _ => '{"plugins":[]}',
    });
    await request.response.close();
  });
  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');
  const timeout = Duration(seconds: 3);
  try {
    final result = await readMarketRoute(
      routes: ['html', 'wrong', 'good'].map(uri),
      timeout: timeout,
      connectionTimeout: timeout,
      read: (response) async {
        final body = jsonDecode(await response.transform(utf8.decoder).join());
        if (body is! Map || body['plugins'] is! List)
          throw const FormatException();
        return body['plugins'] as List;
      },
    );
    check(
      result.isEmpty && paths.join(',') == '/html,/wrong,/good',
      'invalid 200 prevented mirror fallback',
    );

    var cancelled = false;
    void Function()? abort;
    final inFlight = readMarketRoute(
      routes: ['hold', 'good'].map(uri),
      timeout: timeout,
      connectionTimeout: timeout,
      checkCancelled: () {
        if (cancelled) throw const _Cancelled();
      },
      listenForCancellation: (listener) {
        abort = listener;
        return () => abort = null;
      },
      read: (response) => response.timeout(timeout).drain<void>(),
    );
    final assertion = rejects<_Cancelled>(
      () => inFlight,
      'cancellation accepted as a failure to retry',
    );
    await held.future.timeout(timeout);
    cancelled = true;
    abort!();
    await assertion;
    check(
      paths.last == '/hold' && abort == null,
      'cancellation tried another mirror or leaked its listener',
    );
  } finally {
    await server.close(force: true);
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

Future<void> checkOta() async {
  final checkDaily = OtaDailyCheck();
  String? stored;
  var probes = 0;
  var presentations = 0;
  const date = '2026-01-01';
  final release = Completer<String>();
  Future<void> run() => checkDaily.run(
    date: date,
    readDate: () async => stored,
    writeDate: (value) async => stored = value,
    probe: () async {
      if (++probes == 1) throw const SocketException('offline');
      return release.future;
    },
    onResult: (value) async {
      check(
        stored == date && value == 'release',
        'probe result was not recorded first',
      );
      presentations++;
    },
  );
  await rejects<SocketException>(run, 'offline check should fail');
  check(stored == null, 'offline check consumed the day');
  final retry = run();
  final concurrent = run();
  check(identical(retry, concurrent), 'concurrent check did not coalesce');
  release.complete('release');
  await retry;
  await run();
  check(
    probes == 2 && presentations == 1 && stored == date,
    'successful retry was not recorded',
  );
}

Future<void> main() async {
  await checkTools();
  await checkMarket();
  await checkOta();
  print('Tool completion, market fallback and daily OTA checks passed');
}
