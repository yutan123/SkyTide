import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tide_bot/plugin_connections.dart';

Future<void> main() async {
  var checks = 0;
  void expect(bool result, String label) {
    if (!result) throw StateError(label);
    checks++;
  }

  final fixture = File.fromUri(
    Platform.script,
  ).parent.uri.resolve('fixtures/plugin_tls/');
  final context = SecurityContext()
    ..useCertificateChain(File.fromUri(fixture.resolve('cert.pem')).path)
    ..usePrivateKey(File.fromUri(fixture.resolve('key.pem')).path);
  final connections = PluginConnections();
  const permissions = [
    'network',
    'network.local',
    'network.sockets',
    'network.cleartext',
  ];
  Future<dynamic> call(String method, Map args, List endpoints) => connections
      .handle('connections.$method', args, endpoints, permissions, () async {});
  final sockets = <Socket>[];
  final tls = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  final tlsListener = tls.listen((socket) {
    sockets.add(socket);
    socket.listen(socket.add, onError: (Object _) {});
  }, onError: (Object _) {});
  final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final upgrades = <Future<void>>[];
  final listener = tcp.listen((socket) {
    sockets.add(socket);
    socket.write('220 mail ready\r\n');
    var command = '';
    late StreamSubscription<List<int>> subscription;
    subscription = socket.listen((bytes) {
      command += ascii.decode(bytes);
      if (!command.contains('\r\n')) return;
      subscription.pause();
      final work = () async {
        socket.write('220 begin TLS\r\n');
        await socket.flush();
        final secure = await SecureSocket.secureServer(
          socket,
          context,
        ).timeout(const Duration(seconds: 5));
        sockets.add(secure);
        secure.listen(secure.add, onError: (Object _) {});
      }();
      upgrades.add(work);
    }, onError: (Object _) {});
  });
  final https = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  final webSockets = <WebSocket>[];
  final httpsListener = https.listen((request) async {
    if (request.uri.path == '/ws') {
      final ws = await WebSocketTransformer.upgrade(request);
      webSockets.add(ws);
      ws.listen(ws.add, onError: (Object _) {});
    } else {
      request.response.write('secure-http');
      await request.response.close();
    }
  });
  final tlsUrl = 'tls://127.0.0.1:${tls.port}';
  final tcpUrl = 'tcp://127.0.0.1:${tcp.port}';
  try {
    var rejected = false;
    try {
      await call('connect', {'url': tlsUrl}, [tlsUrl]);
    } catch (_) {
      rejected = true;
    }
    expect(rejected, 'untrusted TLS certificate rejected');
    var httpsRejected = false;
    try {
      final url = 'https://127.0.0.1:${https.port}';
      await call('http', {'url': url}, [url]);
    } catch (_) {
      httpsRejected = true;
    }
    expect(httpsRejected, 'HTTPS factory rejects untrusted certificate');
    var wssRejected = false;
    try {
      final url = 'wss://127.0.0.1:${https.port}';
      await call('webSocket', {'url': '$url/ws'}, [url]);
    } catch (_) {
      wssRejected = true;
    }
    expect(wssRejected, 'WSS factory rejects untrusted certificate');
    SecurityContext.defaultContext.setTrustedCertificates(
      File.fromUri(fixture.resolve('cert.pem')).path,
    );
    final httpsUrl = 'https://127.0.0.1:${https.port}';
    final response = await call('http', {'url': httpsUrl}, [httpsUrl]);
    expect(response['status'] == 200, 'HTTPS validates pinned connection');
    final httpData = await call('read', response, []);
    expect(
      utf8.decode(base64Decode(httpData['data'] as String)) == 'secure-http',
      'HTTPS data',
    );
    await call('close', response, []);
    final wssUrl = 'wss://127.0.0.1:${https.port}';
    final ws = await call('webSocket', {'url': '$wssUrl/ws'}, [wssUrl]);
    await call('write', {...ws, 'text': 'secure-ws'}, []);
    expect(
      (await call('read', ws, []))['text'] == 'secure-ws',
      'WSS validates pinned connection',
    );
    await call('close', ws, []);
    final tlsHandle = await call('connect', {'url': tlsUrl}, [tlsUrl]);
    expect(tlsHandle['secure'] == true, 'direct TLS validated');
    await call('write', {...tlsHandle, 'text': 'encrypted'}, []);
    final tlsData = await call('read', tlsHandle, []);
    expect(
      utf8.decode(base64Decode(tlsData['data'] as String)) == 'encrypted',
      'direct TLS data',
    );
    await call('close', tlsHandle, []);
    final plain = await call('connect', {'url': tcpUrl}, [tcpUrl]);
    expect(plain['secure'] == false, 'STARTTLS starts with plaintext');
    final greeting = await call('read', plain, []);
    expect(
      ascii.decode(base64Decode(greeting['data'] as String)).startsWith('220'),
      'SMTP greeting',
    );
    await call('write', {...plain, 'text': 'STARTTLS\r\n'}, []);
    final ready = await call('read', plain, []);
    expect(
      ascii.decode(base64Decode(ready['data'] as String)) ==
          '220 begin TLS\r\n',
      'STARTTLS negotiation',
    );
    final secure = await call('startTls', plain, []);
    expect(secure['secure'] == true, 'upgrade succeeds on existing stream');
    await call('write', {...plain, 'text': 'EHLO plugin\r\n'}, []);
    final echoed = await call('read', plain, []);
    expect(
      ascii.decode(base64Decode(echoed['data'] as String)) == 'EHLO plugin\r\n',
      'upgraded TLS data',
    );
    await call('close', plain, []);
    await Future.wait(upgrades);
    print('Plugin TLS and STARTTLS checks passed: $checks');
  } finally {
    connections.close();
    for (final ws in webSockets) {
      unawaited(ws.close());
    }
    await httpsListener.cancel();
    await https.close(force: true);
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.cancel();
    await tcp.close();
    await tlsListener.cancel();
    await tls.close();
  }
}
