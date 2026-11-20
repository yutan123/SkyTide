import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skytide/plugin_contract.dart';
import 'package:skytide/plugin_file_store.dart';
import 'package:skytide/plugin_file_transfer.dart';
import 'package:skytide/plugin_media_pipeline.dart';
import 'package:skytide/plugin_task_timing.dart';
import 'package:skytide/plugin_chat_session.dart';
import 'plugin_chat_session_check.dart' as fixture;

int checks = 0;
void expect(bool value, String label) {
  if (!value) throw StateError(label);
  checks++;
}

Future<void> rejects(FutureOr<dynamic> Function() work, String label) async {
  try {
    await work();
  } catch (_) {
    checks++;
    return;
  }
  throw StateError('Expected rejection: $label');
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('plugin-expansion-');
  var active = true;
  Future<void> current() async {
    if (!active) throw StateError('invalidated');
  }

  Future<T> locked<T>(Future<T> Function() work) => work();
  final files = PluginFileStore(
    Directory('${root.path}/private'),
    check: current,
    locked: locked,
  );
  try {
    final schema = {
      'type': 'object',
      'properties': {
        'rows': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 2,
          'items': {
            'type': 'object',
            'properties': {
              'count': {'type': 'integer', 'minimum': 1, 'default': 2},
            },
            'required': ['count'],
          },
        },
      },
      'required': ['rows'],
    };
    final values = PluginContract.values(schema, {
      'rows': [{}],
    });
    expect(values['rows'][0]['count'] == 2, 'nested defaults');
    await rejects(
      () => PluginContract.values(schema, {
        'rows': [
          {'count': 0},
        ],
      }),
      'nested bounds',
    );
    await rejects(
      () => PluginContract.values(schema, {'rows': []}),
      'minItems',
    );
    await rejects(
      () => PluginContract.values(schema, {
        'rows': [
          {'extra': 2},
        ],
      }),
      'nested unknown keys',
    );
    var deep = <String, dynamic>{'type': 'string'};
    for (var i = 0; i < 18; i++) {
      deep = {'type': 'array', 'items': deep};
    }
    await rejects(
      () => PluginContract.schema({
        'type': 'object',
        'properties': {'deep': deep},
      }),
      'schema recursion',
    );
    await files.call('files.write', {'path': 'data/a.txt', 'data': 'hello'});
    await files.call('files.write', {
      'path': 'data/a.txt',
      'data': '世界',
      'append': true,
    });
    expect(
      (await files.call('files.read', {'path': 'data/a.txt'}))['data'] ==
          'hello世界',
      'UTF8 append',
    );
    final binary = List.generate(256, (i) => i);
    await files.call('files.write', {
      'path': 'binary',
      'data': base64Encode(binary),
      'encoding': 'base64',
    });
    final part = await files.call('files.read', {
      'path': 'binary',
      'offset': 250,
      'length': 6,
      'encoding': 'base64',
    });
    expect(
      base64Decode(part['data']).last == 255 && part['eof'],
      'binary slicing',
    );
    for (final name in [
      '../outside',
      '/absolute',
      'a/../b',
      'a\\b',
      '.pending-x',
    ]) {
      await rejects(() => files.file(name), 'path isolation');
    }
    await Link('${files.root.path}/link').create(root.path);
    await rejects(() => files.file('link/outside'), 'symbolic link');
    await rejects(
      () => files.writeStream(
        'data/a.txt',
        Stream<List<int>>.error(StateError('connection lost')),
      ),
      'atomic error',
    );
    expect(
      (await files.call('files.read', {'path': 'data/a.txt'}))['data'] ==
          'hello世界',
      'failed overwrite preserves original',
    );
    expect(
      (await files.call('files.list', {'directory': 'data'})).length == 1,
      'directory listing',
    );
    await rejects(
      () => files.call('files.write', {
        'path': 'large',
        'data': 'x' * (PluginFileStore.chunkSize + 1),
      }),
      'RPC chunk limit',
    );
    active = false;
    await rejects(
      () => files.call('files.read', {'path': 'binary'}),
      'lifecycle',
    );
    active = true;

    for (final name in ['quota-a', 'quota-b']) {
      final handle = await File(
        (await files.file(name)).path,
      ).open(mode: FileMode.write);
      await handle.truncate(PluginFileStore.maxFile);
      await handle.close();
    }
    await rejects(
      () => files.writeStream('over-quota', Stream.value([1])),
      'aggregate quota',
    );
    expect(
      await files.call('files.stat', {'path': 'over-quota'}) == null,
      'quota failure cleans temporary file',
    );
    await files.call('files.delete', {'path': 'quota-a'});
    await files.call('files.delete', {'path': 'quota-b'});
    final requests = <http.Request>[];
    final transfer = PluginFileTransfer(
      createClient: () => MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/redirect')
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.test/file'},
          );
        if (request.method == 'PUT') {
          expect(
            request.bodyBytes.length == 256 && request.bodyBytes.last == 255,
            'stream upload bytes',
          );
          return http.Response('stored', 201);
        }
        if (request.url.path == '/denied') return http.Response('', 403);
        return http.Response.bytes(binary, 200);
      }),
    );
    final downloaded = await transfer.request(
      'http.downloadFile',
      {
        'url': 'https://api.test/redirect',
        'path': 'download',
        'requestId': 'get',
        'headers': {'Cookie': 'secret', 'Referer': 'https://api.test'},
      },
      ['https://api.test', 'https://cdn.test'],
      files,
      current,
    );
    expect(downloaded['size'] == 256, 'download bytes');
    expect(
      requests.last.headers['cookie'] == null &&
          requests.last.headers['referer'] == 'https://api.test',
      'cross origin credential stripping',
    );
    final uploaded = await transfer.request(
      'http.uploadFile',
      {'url': 'https://api.test/upload', 'path': 'binary', 'requestId': 'put'},
      ['https://api.test'],
      files,
      current,
    );
    expect(
      uploaded['status'] == 201 &&
          utf8.decode(base64Decode(uploaded['bodyBase64'])) == 'stored',
      'upload response',
    );
    expect(
      transfer.control('http.fileProgress', {'requestId': 'get'})['state'] ==
          'completed',
      'progress',
    );
    await rejects(
      () => transfer.request(
        'http.downloadFile',
        {
          'url': 'https://api.test/denied',
          'path': 'download',
          'requestId': 'bad',
        },
        ['https://api.test'],
        files,
        current,
      ),
      'HTTP failure',
    );
    expect(
      (await files.call('files.stat', {'path': 'download'}))['size'] == 256,
      'HTTP failure preserves destination',
    );
    await rejects(
      () => transfer.request(
        'http.downloadFile',
        {
          'url': 'https://evil.test/file',
          'path': 'download',
          'requestId': 'evil',
        },
        ['https://api.test'],
        files,
        current,
      ),
      'network policy',
    );
    await files.call('files.write', {'path': 'cancelled', 'data': 'original'});
    final gate = Completer<http.Response>();
    final cancellable = PluginFileTransfer(
      createClient: () => MockClient((_) => gate.future),
    );
    final pending = cancellable.request(
      'http.downloadFile',
      {
        'url': 'https://api.test/file',
        'path': 'cancelled',
        'requestId': 'cancel',
      },
      ['https://api.test'],
      files,
      current,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      cancellable.control('http.cancelFile', {'requestId': 'cancel'}),
      'cancel active request',
    );
    await rejects(
      () => cancellable.request(
        'http.downloadFile',
        {
          'url': 'https://api.test/file',
          'path': 'other',
          'requestId': 'cancel',
        },
        ['https://api.test'],
        files,
        current,
      ),
      'cancelled request reserves ID until cleanup',
    );
    gate.complete(http.Response('', 200));
    await rejects(() => pending, 'cancelled transfer');
    expect(
      (await files.call('files.read', {'path': 'cancelled'}))['data'] ==
          'original',
      'cancelled empty response preserves destination',
    );
    await cancellable.request(
      'http.downloadFile',
      {'url': 'https://api.test/file', 'path': 'other', 'requestId': 'cancel'},
      ['https://api.test'],
      files,
      current,
    );
    expect(
      cancellable.control('http.fileProgress', {
            'requestId': 'cancel',
          })['state'] ==
          'completed',
      'request ID reusable after cleanup',
    );
    cancellable.close();
    transfer.close();

    final hls = await Directory('${root.path}/hls').create();
    final addresses = <String>[];
    final input = await PluginMediaPipeline.hls(
      url: 'https://origin.test/start',
      directory: hls,
      check: current,
      download: (url, file) async {
        addresses.add(url);
        if (url.endsWith('/start')) {
          await file.writeAsString(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200\nhigh.m3u8',
          );
          return 'https://cdn.test/base/master.m3u8';
        }
        if (url.endsWith('/low.m3u8')) {
          await file.writeAsString(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST',
          );
        } else {
          await file.writeAsBytes([1, 2, 3]);
        }
        return url;
      },
    );
    expect(await File(input).exists(), 'mirrored playlist');
    expect(
      addresses.contains('https://cdn.test/base/part.ts') &&
          addresses.contains('https://cdn.test/base/key') &&
          !addresses.any((url) => url.endsWith('high.m3u8')),
      'redirect base, key, variant selection',
    );
    expect(
      !(await File(input).readAsString()).contains('https://'),
      'local master only',
    );
    await rejects(
      () => PluginMediaPipeline.hls(
        url: 'https://live.test/list',
        directory: hls,
        check: current,
        download: (url, file) async {
          await file.writeAsString('#EXTM3U\nsegment.ts');
          return url;
        },
      ),
      'live playlist',
    );
    final args = PluginMediaPipeline.arguments(
      {'operation': 'merge'},
      ['v', 'a'],
      'out.mp4',
    );
    expect(
      args.contains('0:v:0') && args.contains('1:a:0') && args.contains('copy'),
      'merge stream mapping',
    );
    await rejects(
      () => PluginMediaPipeline.arguments({'operation': 'exec'}, ['x'], 'out'),
      'closed media operations',
    );
    expect(
      PluginTaskTiming.next(1000, 60000, 181000) == 241000,
      'missed periods skipped',
    );
    expect(PluginTaskTiming.next(1000, 60000, 1000) == 61000, 'next cadence');
    await rejects(
      () => PluginTaskTiming.interval(59999),
      'interval lower bound',
    );
    expect(PluginTaskTiming.interval(0) == 0, 'disable recurring');

    final host = fixture.Host(root);
    final session = PluginChatSession(
      pluginId: 'tidebot.expansion',
      botId: 'bot',
      assertCurrent: current,
      host: host,
      files: files,
      processMedia: (args, check) async {
        await check();
        await File(
          args.last,
        ).writeAsBytes([0, 0, 0, 24, ...ascii.encode('ftypisom'), 0, 0, 0, 0]);
      },
    );
    await files.call('files.write', {
      'path': 'video',
      'encoding': 'base64',
      'data': base64Encode([
        0,
        0,
        0,
        24,
        ...ascii.encode('ftypisom'),
        0,
        0,
        0,
        0,
      ]),
    });
    final resource = await session.call(
      'media.fromFile',
      {'path': 'video', 'kind': 'video'},
      ['media.download', 'files'],
      [],
    );
    final result = await session.call(
      'media.process',
      {'operation': 'transcode', 'resourceId': resource['resourceId']},
      ['media.download', 'media.process'],
      [],
    );
    expect(
      result['kind'] == 'video' && !result.containsKey('path'),
      'processing resource registration',
    );
    await session.call(
      'media.saveFile',
      {'resourceId': result['resourceId'], 'path': 'processed.mp4'},
      ['media.download', 'files'],
      [],
    );
    expect(
      await files.call('files.stat', {'path': 'processed.mp4'}) != null,
      'save result to private file',
    );
    await rejects(
      () => session.call(
        'media.process',
        {'operation': 'transcode', 'resourceId': resource['resourceId']},
        ['media.download'],
        [],
      ),
      'media process permission',
    );
    await session.close();
    expect(
      await files.call('files.stat', {'path': 'processed.mp4'}) != null,
      'private file survives context',
    );
    print('Plugin expansion: $checks checks passed');
  } finally {
    await root.delete(recursive: true);
  }
}
