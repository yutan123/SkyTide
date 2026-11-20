import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:skytide/plugin_connections.dart';
import 'package:skytide/plugin_crypto.dart';

Future<void> main() async {
  var checks = 0;
  void expect(bool result, String label) {
    if (!result) throw StateError(label);
    checks++;
  }

  Future<void> rejects(Future<dynamic> Function() work, String label) async {
    try {
      await work();
    } catch (_) {
      checks++;
      return;
    }
    throw StateError('Expected rejection: $label');
  }

  final connections = PluginConnections();
  const permissions = [
    'network',
    'network.sockets',
    'network.cleartext',
    'network.local',
  ];
  Future<dynamic> call(
    String method,
    Map args,
    List endpoints, [
    List grants = permissions,
  ]) => connections.handle(
    'connections.$method',
    args,
    endpoints,
    grants,
    () async {},
  );
  final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <Socket>[];
  final listener = tcp.listen((socket) {
    sockets.add(socket);
    socket.listen((bytes) {
      socket.add(bytes);
    }, onError: (Object _) {});
  });
  final tcpUrl = 'tcp://127.0.0.1:${tcp.port}';
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final webSockets = <WebSocket>[];
  final httpListener = http.listen((request) async {
    if (request.uri.path == '/ws') {
      final ws = await WebSocketTransformer.upgrade(request);
      webSockets.add(ws);
      ws.listen(ws.add);
    } else if (request.uri.path == '/redirect') {
      request.response.statusCode = 302;
      request.response.headers.set('location', 'http://127.0.0.1:1/private');
      await request.response.close();
    } else if (request.uri.path == '/events') {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'id: 7\r\nevent: mail\r\ndata: 你好\r\ndata: world\r\n\r\n',
      );
      await request.response.close();
    } else {
      request.response.add([0, 255, 128, 1]);
      await request.response.close();
    }
  });
  final httpOrigin = 'http://127.0.0.1:${http.port}';
  final wsOrigin = 'ws://127.0.0.1:${http.port}';
  try {
    expect(
      PluginConnectionPolicy.validEndpoint('tls://mail.example.com:993'),
      'TLS endpoint',
    );
    expect(
      !PluginConnectionPolicy.validEndpoint('tcp://host'),
      'TCP requires port',
    );
    expect(
      !PluginConnectionPolicy.validEndpoint('tls://host:abc'),
      'invalid port is rejected',
    );
    expect(
      !PluginConnectionPolicy.validEndpoint('http://host:0'),
      'zero port is rejected',
    );
    expect(
      !PluginConnectionPolicy.validEndpoint('http://*.example.com'),
      'no wildcard',
    );
    expect(
      !PluginConnectionPolicy.validEndpoint('https://host/path'),
      'no endpoint paths',
    );
    for (final address in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '192.168.1.1',
      '::1',
      '::ffff:127.0.0.1',
      'fe80::1',
    ]) {
      expect(
        PluginConnectionPolicy.local(InternetAddress(address)),
        'local $address',
      );
    }
    expect(
      !PluginConnectionPolicy.local(InternetAddress('8.8.8.8')),
      'public IPv4',
    );
    await rejects(() => call('connect', {'url': tcpUrl}, []), 'endpoint grant');
    await rejects(
      () => call('connect', {'url': tcpUrl}, [tcpUrl], [
        'network',
        'network.sockets',
      ]),
      'cleartext grant',
    );
    await rejects(
      () => call('connect', {'url': tcpUrl}, [tcpUrl], [
        'network',
        'network.sockets',
        'network.cleartext',
      ]),
      'local grant',
    );
    await rejects(
      () => call('connect', {'url': tcpUrl}, [tcpUrl], [
        'network',
        'network.local',
        'network.cleartext',
      ]),
      'socket grant',
    );
    final connected = await call('connect', {'url': tcpUrl}, [tcpUrl]);
    final id = connected['connectionId'];
    await call('write', {'connectionId': id, 'base64': 'AP+A'}, []);
    final read = await call('read', {'connectionId': id}, []);
    expect(read['data'] == 'AP+A', 'binary TCP roundtrip');
    final timeout = await call('read', {
      'connectionId': id,
      'timeoutMs': 10,
    }, []);
    expect(
      timeout['timedOut'] == true && timeout['done'] == false,
      'read timeout is not EOF',
    );
    final pending = call('read', {'connectionId': id}, []);
    await rejects(
      () => call('read', {'connectionId': id}, []),
      'concurrent read',
    );
    await call('close', {'connectionId': id}, []);
    expect((await pending)['done'] == true, 'close wakes reader');
    await rejects(
      () => call('write', {'connectionId': id, 'text': 'late'}, []),
      'closed handle',
    );
    final response = await call(
      'http',
      {'url': '$httpOrigin/binary'},
      [httpOrigin],
    );
    expect(response['status'] == 200, 'HTTP headers returned');
    final chunk = await call('read', {
      'connectionId': response['connectionId'],
    }, []);
    expect(chunk['data'] == 'AP+AAQ==', 'binary HTTP response');
    await call('close', response, []);
    final redirect = await call(
      'http',
      {'url': '$httpOrigin/redirect'},
      [httpOrigin],
    );
    expect(redirect['status'] == 302, 'HTTP redirect not followed');
    await call('close', redirect, []);
    final ws = await call('webSocket', {'url': '$wsOrigin/ws'}, [wsOrigin]);
    await call('write', {'connectionId': ws['connectionId'], 'text': '消息'}, []);
    expect(
      (await call('read', ws, []))['text'] == '消息',
      'WebSocket text roundtrip',
    );
    await call('write', {
      'connectionId': ws['connectionId'],
      'base64': 'AP+A',
    }, []);
    expect(
      (await call('read', ws, []))['data'] == 'AP+A',
      'WebSocket binary roundtrip',
    );
    await call('close', ws, []);
    await rejects(
      () => call('webSocket', {'url': '$wsOrigin/redirect'}, [wsOrigin]),
      'WebSocket redirect rejected',
    );
    final sse = await call(
      'http',
      {'url': '$httpOrigin/events', 'format': 'sse'},
      [httpOrigin],
    );
    final event = (await call('read', sse, []))['event'];
    expect(
      event['data'] == '你好\nworld' &&
          event['event'] == 'mail' &&
          event['id'] == '7',
      'SSE parsed',
    );
    await call('close', sse, []);
    final encoded = utf8.encode(
      '\ufeffid: 1\rdata: 你好\r\ndata: 二\n\nevent: ignored\ndata: incomplete',
    );
    final events = await pluginSseEvents(
      Stream.fromIterable(encoded.map((b) => [b])),
    ).toList();
    expect(
      events.length == 1 && events.first['data'] == '你好\n二',
      'SSE split UTF-8 and CRLF',
    );
    await rejects(
      () => pluginSseEvents(
        Stream.value(utf8.encode('data: ${'x' * 33000}')),
      ).toList(),
      'SSE line bound',
    );
    for (var i = 0; i < 8; i++) {
      await call('connect', {'url': tcpUrl}, [tcpUrl]);
    }
    await rejects(
      () => call('connect', {'url': tcpUrl}, [tcpUrl]),
      'connection quota',
    );
    connections.close();
    await rejects(
      () => call('connect', {'url': tcpUrl}, [tcpUrl]),
      'closed runtime',
    );
    final digest = await PluginCrypto.call('crypto.digest', {
      'base64': base64Encode(utf8.encode('abc')),
    });
    expect(
      digest['hex'] ==
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'SHA-256 vector',
    );
    final key = await PluginCrypto.call('crypto.random', {'length': 32});
    final sealed = await PluginCrypto.call('crypto.encrypt', {
      'key': key,
      'base64': 'AP+A',
    });
    expect(
      await PluginCrypto.call('crypto.decrypt', {...sealed, 'key': key}) ==
          'AP+A',
      'AES-GCM roundtrip',
    );
    await rejects(
      () => PluginCrypto.call('crypto.decrypt', {
        ...sealed,
        'key': key,
        'mac': base64Encode(List.filled(16, 0)),
      }),
      'GCM authentication',
    );
    final pkce = await PluginCrypto.call('auth.createPkce', {});
    final challenge = await PluginCrypto.call('crypto.digest', {
      'base64': base64Encode(ascii.encode(pkce['verifier'] as String)),
    });
    expect(
      pkce['challenge'] ==
          (challenge['base64'] as String)
              .replaceAll('+', '-')
              .replaceAll('/', '_')
              .replaceAll('=', ''),
      'PKCE S256',
    );
    print('Plugin connection and crypto checks passed: $checks');
  } finally {
    connections.close();
    for (final ws in webSockets) {
      unawaited(ws.close());
    }
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.cancel();
    await tcp.close();
    await httpListener.cancel();
    await http.close(force: true);
  }
}
