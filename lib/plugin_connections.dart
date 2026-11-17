import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' as hashes;
import 'dart:typed_data';

import 'plugin_media_contract.dart';

/// Explicit endpoint grants for protocols outside the legacy HTTPS API.
class PluginConnectionPolicy {
  static const schemes = {'http', 'https', 'ws', 'wss', 'tcp', 'tls'};
  static bool validEndpoint(Object? value) {
    if (value is! String || value.length > 300) return false;
    try {
      final uri = Uri.tryParse(value);
      return uri != null &&
          schemes.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          !uri.host.contains('*') &&
          uri.userInfo.isEmpty &&
          uri.path.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          uri.port > 0 &&
          uri.port <= 65535 &&
          (!{'tcp', 'tls'}.contains(uri.scheme) || uri.hasPort);
    } on FormatException {
      return false;
    }
  }

  static bool local(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          b[0] >= 224;
    }
    if (b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255) {
      return local(
        InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
      );
    }
    // Only globally routed unicast IPv6 is allowed without network.local.
    return b[0] & 0xe0 != 0x20;
  }

  static Future<List<InternetAddress>> authorize(
    Uri uri,
    List endpoints,
    List permissions,
  ) async {
    if (!permissions.contains('network')) throw StateError('未声明 network 权限');
    final endpoint = '${uri.scheme}://${uri.authority}';
    if (!validEndpoint(endpoint) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !endpoints.any((e) {
          if (!validEndpoint(e)) return false;
          final grant = Uri.parse(e as String);
          return grant.scheme == uri.scheme &&
              grant.host == uri.host &&
              grant.port == uri.port;
        })) {
      throw StateError('连接地址未获得 networkEndpoints 授权');
    }
    if ({'http', 'ws', 'tcp'}.contains(uri.scheme) &&
        !permissions.contains('network.cleartext')) {
      throw StateError('明文连接需要 network.cleartext 权限');
    }
    final addresses = await InternetAddress.lookup(
      uri.host,
    ).timeout(const Duration(seconds: 15));
    if (addresses.isEmpty) throw StateError('无法解析连接地址');
    if (!permissions.contains('network.local') && addresses.any(local)) {
      throw StateError('本机或局域网连接需要 network.local 权限');
    }
    return addresses;
  }
}

/// Pull based, bounded streams owned by one plugin runtime. Handles never expose
/// sockets or filesystem paths to JavaScript. Connections are pinned to the DNS
/// addresses that passed authorization; TLS still validates the original host.
class PluginConnections {
  final _pipes = <String, _Pipe>{};
  int _sequence = 0;
  bool _closed = false;
  Timer? _reaper;

  void close() {
    _closed = true;
    _reaper?.cancel();
    for (final pipe in _pipes.values) {
      pipe.close();
    }
    _pipes.clear();
  }

  _Pipe _reserve() {
    if (_closed) throw StateError('插件连接已停止');
    if (_pipes.length >= 8) throw StateError('最多八个连接或流，请关闭已使用的句柄');
    final pipe = _Pipe('connection_${++_sequence}');
    _pipes[pipe.id] = pipe;
    _reaper ??= Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      final stale = _pipes.values
          .where((p) => now.difference(p.touched).inMinutes >= 2)
          .toList();
      for (final p in stale) {
        _pipes.remove(p.id);
        p.close();
      }
    });
    return pipe;
  }

  _Pipe _get(Map args) {
    if (_closed) throw StateError('插件连接已停止');
    final pipe = _pipes[args['connectionId']];
    if (pipe == null) throw StateError('连接句柄无效或已过期');
    pipe.touched = DateTime.now();
    return pipe;
  }

  Future<dynamic> handle(
    String method,
    Map args,
    List endpoints,
    List permissions,
    Future<void> Function() check,
  ) async {
    if (method == 'connections.close') {
      final pipe = _pipes.remove(args['connectionId']);
      pipe?.close();
      return pipe != null;
    }
    if (method == 'connections.read')
      return _get(args).read(args['timeoutMs'] ?? 30000);
    if (method == 'connections.write') {
      final p = _get(args);
      if (p.writing || p.upgrading) throw StateError('连接正在写入或升级 TLS');
      final bytes = _body(args, 64 * 1024);
      if (p.closed || p.done) throw StateError('连接已关闭');
      p.writing = true;
      try {
        if (p.webSocket != null) {
          if (args['base64'] != null) {
            p.webSocket!.add(bytes);
          } else {
            p.webSocket!.add(args['text'] as String? ?? '');
          }
        } else if (p.socket != null) {
          p.socket!.add(bytes);
          await p.socket!.flush().timeout(const Duration(seconds: 30));
        } else {
          throw StateError('HTTP 响应流不可写入');
        }
        await check();
        return bytes.length;
      } finally {
        p.writing = false;
      }
    }
    if (method == 'connections.startTls') {
      final p = _get(args);
      if (p.socket == null ||
          p.webSocket != null ||
          p.secure ||
          p.closed ||
          p.done ||
          p.reading ||
          p.writing ||
          p.upgrading ||
          p.queue.isNotEmpty) {
        throw StateError('STARTTLS 需要没有未读数据及进行中操作的 TCP 连接');
      }
      // The plugin must first complete the protocol's STARTTLS negotiation.
      p.upgrading = true;
      try {
        p.subscription?.pause();
        p.subscription = null;
        final secure = await SecureSocket.secure(
          p.socket!,
          host: p.host,
        ).timeout(const Duration(seconds: 30));
        if (p.closed || _closed) {
          secure.destroy();
          throw StateError('连接已停止');
        }
        p.socket = secure;
        p.secure = true;
        p.attach(secure);
        await check();
        return {'connectionId': p.id, 'secure': true};
      } catch (_) {
        _pipes.remove(p.id);
        p.close();
        rethrow;
      } finally {
        p.upgrading = false;
      }
    }
    if (!{
      'connections.connect',
      'connections.webSocket',
      'connections.http',
    }.contains(method)) {
      throw StateError('未知连接 API');
    }
    if (args['format'] != null && !{'binary', 'sse'}.contains(args['format'])) {
      throw const FormatException('format 必须为 binary 或 sse');
    }
    final uri = Uri.parse(args['url'] as String);
    final socketMode = method == 'connections.connect';
    final webSocketMode = method == 'connections.webSocket';
    if (socketMode && !{'tcp', 'tls'}.contains(uri.scheme) ||
        webSocketMode && !{'ws', 'wss'}.contains(uri.scheme) ||
        !socketMode &&
            !webSocketMode &&
            !{'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException('连接协议与 API 不匹配');
    }
    if (socketMode && (uri.path.isNotEmpty || uri.hasQuery)) {
      throw const FormatException('套接字地址不能包含路径或查询参数');
    }
    if (socketMode && !permissions.contains('network.sockets')) {
      throw StateError('未声明 network.sockets 权限');
    }
    final p = _reserve();
    try {
      final addresses = await PluginConnectionPolicy.authorize(
        uri,
        endpoints,
        permissions,
      );
      await check();
      if (p.closed) throw StateError('连接已停止');
      p.host = uri.host;
      if (socketMode) {
        final socket = await Socket.connect(
          addresses.first,
          uri.port,
          timeout: const Duration(seconds: 30),
        );
        if (p.closed) {
          socket.destroy();
          throw StateError('连接已停止');
        }
        p.socket = socket;
        if (uri.scheme == 'tls') {
          final secure = await SecureSocket.secure(
            socket,
            host: uri.host,
          ).timeout(const Duration(seconds: 30));
          if (p.closed) {
            secure.destroy();
            throw StateError('连接已停止');
          }
          p.socket = secure;
          p.secure = true;
        }
        p.attach(p.socket!);
        await check();
        return {'connectionId': p.id, 'secure': p.secure};
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30);
      p.client = client;
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (_, _, _) async {
        final task = await Socket.startConnect(addresses.first, uri.port);
        Socket? connected;
        var cancelled = false;
        final future = task.socket.then<Socket>((socket) async {
          connected = socket;
          try {
            if (cancelled || p.closed) throw StateError('连接已停止');
            if ({'https', 'wss'}.contains(uri.scheme)) {
              // A custom HttpClient factory must perform TLS itself. Keep DNS
              // pinning while validating the certificate against the URI host.
              final secure = await SecureSocket.secure(
                socket,
                host: uri.host,
              ).timeout(const Duration(seconds: 30));
              connected = secure;
            }
            if (cancelled || p.closed) throw StateError('连接已停止');
            return connected!;
          } catch (_) {
            connected?.destroy();
            rethrow;
          }
        });
        return ConnectionTask.fromSocket(future, () {
          cancelled = true;
          task.cancel();
          connected?.destroy();
        });
      };
      if (webSocketMode) {
        final handshakeUri = uri.replace(
          scheme: uri.scheme == 'wss' ? 'https' : 'http',
        );
        final request = await _openAuthorizedHttp(
          client,
          'GET',
          handshakeUri,
        ).timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        PluginMediaContract.headers(
          args['headers'],
        ).forEach(request.headers.set);
        final random = Random.secure();
        final key = base64Encode(List.generate(16, (_) => random.nextInt(256)));
        request.headers.set('connection', 'Upgrade');
        request.headers.set('upgrade', 'websocket');
        request.headers.set('sec-websocket-version', '13');
        request.headers.set('sec-websocket-key', key);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        final expected = base64Encode(
          hashes.sha1
              .convert(
                ascii.encode(
                  '$key'
                  '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
                ),
              )
              .bytes,
        );
        if (response.statusCode != 101 ||
            response.headers.value('sec-websocket-accept') != expected ||
            response.headers.value('upgrade')?.toLowerCase() != 'websocket' ||
            !(response.headers.value('connection') ?? '')
                .toLowerCase()
                .split(',')
                .any((v) => v.trim() == 'upgrade') ||
            response.headers.value('sec-websocket-protocol') != null ||
            response.headers.value('sec-websocket-extensions') != null) {
          throw StateError('WebSocket 握手失败');
        }
        final socket = await response.detachSocket();
        final ws = WebSocket.fromUpgradedSocket(socket, serverSide: false);
        if (p.closed) {
          socket.destroy();
          throw StateError('连接已停止');
        }
        p.socket = socket;
        p.webSocket = ws;
        ws.pingInterval = const Duration(seconds: 30);
        p.attach(ws);
        await check();
        return {'connectionId': p.id, 'protocol': ws.protocol};
      }
      final verb = (args['method'] as String? ?? 'GET').toUpperCase();
      if (!{
        'GET',
        'POST',
        'PUT',
        'PATCH',
        'DELETE',
        'HEAD',
        'OPTIONS',
      }.contains(verb)) {
        throw const FormatException('HTTP 方法不支持');
      }
      final request = await _openAuthorizedHttp(
        client,
        verb,
        uri,
      ).timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      PluginMediaContract.headers(args['headers']).forEach(request.headers.set);
      final body = _body(args, 768 * 1024);
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (p.closed) throw StateError('连接已停止');
      if (args['format'] == 'sse') {
        if (!(response.headers.contentType?.mimeType == 'text/event-stream'))
          throw StateError('响应不是 SSE');
        p.attach(pluginSseEvents(response));
      } else {
        p.attach(response);
      }
      await check();
      final headers = <String, String>{};
      response.headers.forEach((k, v) => headers[k] = v.join(', '));
      return {
        'connectionId': p.id,
        'status': response.statusCode,
        'headers': headers,
      };
    } catch (_) {
      _pipes.remove(p.id);
      p.close();
      rethrow;
    }
  }

  // Only called after endpoint, cleartext and local-network authorization.
  // Flutter's HTTP hook supports this zone override; keep the app-wide Android
  // cleartext policy restricted and scope the exception to this request.
  static Future<HttpClientRequest> _openAuthorizedHttp(
    HttpClient client,
    String method,
    Uri uri,
  ) => runZoned(
    () => client.openUrl(method, uri),
    zoneValues: {#flutter.io.allow_http: true},
  );

  static List<int> _body(Map args, int max) {
    if (args['base64'] != null && args['text'] != null) {
      throw const FormatException('text 与 base64 不能同时设置');
    }
    final value = args['base64'] ?? args['text'] ?? '';
    if (value is! String || value.length > max * 2)
      throw const FormatException('数据过长');
    final bytes = args['base64'] == null
        ? utf8.encode(value)
        : base64Decode(value);
    if (bytes.length > max) throw const FormatException('数据超过大小限制');
    return bytes;
  }
}

class _Pipe {
  _Pipe(this.id);
  final String id;
  DateTime touched = DateTime.now();
  final queue = Queue<Object>();
  int buffered = 0;
  bool closed = false, done = false, secure = false;
  bool reading = false, writing = false, upgrading = false;
  Object? error;
  String host = '';
  Socket? socket;
  WebSocket? webSocket;
  HttpClient? client;
  StreamSubscription<dynamic>? subscription;
  Completer<void>? wake;

  void signal() {
    final w = wake;
    wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void attach(Stream<dynamic> stream) {
    subscription = stream.listen(
      (dynamic data) {
        if (closed) return;
        final size = data is Map
            ? utf8.encode(jsonEncode(data)).length
            : data is String
            ? utf8.encode(data).length
            : (data as List<int>).length;
        if (webSocket != null && size > 64 * 1024) {
          error = StateError('WebSocket 单条消息超过 64 KiB');
          close();
          return;
        }
        final items = data is String || data is Map
            ? 1
            : ((data as List<int>).length + 65535) ~/ 65536;
        if (queue.length + items > 1024 || buffered + size > 1024 * 1024) {
          error = StateError('连接接收缓冲超过 1 MiB 或 1024 项');
          close();
          return;
        }
        if (data is String || data is Map) {
          queue.add(data);
        } else {
          final bytes = data as List<int>;
          for (var i = 0; i < bytes.length; i += 65536) {
            queue.add(
              Uint8List.fromList(
                bytes.sublist(i, (i + 65536).clamp(0, bytes.length)),
              ),
            );
          }
        }
        buffered += size;
        if (buffered >= 128 * 1024) subscription?.pause();
        signal();
      },
      onDone: () {
        done = true;
        signal();
      },
      onError: (Object e) {
        error = e;
        close();
      },
    );
  }

  Future<Map<String, dynamic>> read(Object timeout) async {
    if (timeout is! int || timeout < 1 || timeout > 30000) {
      throw const FormatException('读取超时必须为 1–30000 毫秒');
    }
    if (reading || upgrading) throw StateError('每个连接只能有一个读取操作');
    reading = true;
    try {
      if (queue.isEmpty && !done && !closed) {
        wake ??= Completer<void>();
        try {
          await wake!.future.timeout(Duration(milliseconds: timeout));
        } on TimeoutException {
          return {'data': '', 'done': false, 'timedOut': true};
        }
      }
      if (error != null) throw StateError('连接读取失败：$error');
      if (queue.isEmpty) return {'data': '', 'done': true};
      final data = queue.removeFirst();
      final bytes = data is Map
          ? utf8.encode(jsonEncode(data))
          : data is String
          ? utf8.encode(data)
          : data as List<int>;
      buffered -= bytes.length;
      if (buffered < 64 * 1024) subscription?.resume();
      if (data is Map)
        return {'data': '', 'done': false, 'type': 'event', 'event': data};
      return {
        'data': base64Encode(bytes),
        'done': false,
        'type': data is String ? 'text' : 'binary',
        if (data is String) 'text': data,
      };
    } finally {
      reading = false;
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    done = true;
    queue.clear();
    buffered = 0;
    webSocket?.pingInterval = null;
    unawaited(subscription?.cancel());
    socket?.destroy();
    unawaited(webSocket?.close());
    client?.close(force: true);
    signal();
  }
}

/// Incremental UTF-8 SSE parser with bounded lines/events and CR/LF support.
Stream<Map<String, dynamic>> pluginSseEvents(Stream<List<int>> source) async* {
  var line = '', event = '', lastId = '';
  final data = <String>[];
  var size = 0, skipLf = false, first = true;
  int? retry;
  await for (var chunk in source.transform(utf8.decoder)) {
    if (first && chunk.isNotEmpty) {
      first = false;
      if (chunk.startsWith('\ufeff')) chunk = chunk.substring(1);
    }
    for (final code in chunk.codeUnits) {
      if (skipLf && code == 10) {
        skipLf = false;
        continue;
      }
      skipLf = false;
      if (code != 10 && code != 13) {
        line += String.fromCharCode(code);
        if (line.length > 32768) throw StateError('SSE 行超过 32 Ki 字符');
        continue;
      }
      skipLf = code == 13;
      if (line.isEmpty) {
        if (data.isNotEmpty)
          yield {
            'data': data.join('\n'),
            'event': event.isEmpty ? 'message' : event,
            'id': lastId,
            if (retry != null) 'retry': retry,
          };
        data.clear();
        size = 0;
        event = '';
      } else if (!line.startsWith(':')) {
        final colon = line.indexOf(':');
        final field = colon < 0 ? line : line.substring(0, colon);
        var value = colon < 0 ? '' : line.substring(colon + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        switch (field) {
          case 'data':
            size += value.length + 1;
            if (size > 32768) throw StateError('SSE 事件超过 32 Ki 字符');
            data.add(value);
          case 'event':
            event = value;
          case 'id':
            if (!value.contains('\x00')) lastId = value;
          case 'retry':
            if (RegExp(r'^[0-9]+$').hasMatch(value))
              retry = int.tryParse(value);
        }
      }
      line = '';
    }
  }
}
