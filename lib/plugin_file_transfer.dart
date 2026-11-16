import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'plugin_file_store.dart';
import 'plugin_media_contract.dart';
import 'plugin_operation.dart';

/// Stream private files without copying their bodies through the JS bridge.
class PluginFileTransfer {
  PluginFileTransfer({http.Client Function()? createClient})
    : createClient = createClient ?? http.Client.new;
  final http.Client Function() createClient;
  final _clients = <String, http.Client>{};
  final _states = <String, Map<String, dynamic>>{};
  void close() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }

  dynamic control(String method, Map args) {
    final id = args['requestId'];
    if (id is! String) throw const FormatException('requestId 必须为字符串');
    if (method == 'http.fileProgress') return _states[id];
    final client = _clients[id];
    if (client == null || _states[id]?['state'] != 'running') return false;
    _states[id]?['state'] = 'cancelled';
    client.close();
    return true;
  }

  Future<dynamic> request(
    String method,
    Map args,
    List origins,
    PluginFileStore files,
    Future<void> Function() check,
  ) async {
    final id = args['requestId'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        _clients.containsKey(id))
      throw const FormatException('requestId 无效或正在使用');
    final timeoutMs =
        args['timeoutMs'] ?? PluginTimeouts.network.inMilliseconds;
    if (timeoutMs is! int ||
        timeoutMs < 1 ||
        timeoutMs > PluginTimeouts.network.inMilliseconds)
      throw const FormatException('timeoutMs 无效');
    var uri = PluginMediaContract.uri(args['url'], origins);
    final headers = PluginMediaContract.headers(args['headers']);
    if (_clients.length >= 8) throw StateError('最多同时传输 8 个文件');
    final client = createClient();
    _clients[id] = client;
    final state = <String, dynamic>{
      'requestId': id,
      'state': 'running',
      'bytes': 0,
    };
    _states[id] = state;
    while (_states.length > 128) {
      final old = _states.keys.firstWhere((key) => !_clients.containsKey(key));
      _states.remove(old);
    }
    Future<void> active() async {
      await check();
      if (!identical(_clients[id], client) || state['state'] != 'running')
        throw const PluginOperationCancelled();
    }

    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      state['state'] = 'timeout';
      client.close();
    });
    try {
      await active();
      http.StreamedResponse response;
      if (method == 'http.downloadFile') {
        var redirects = 0;
        while (true) {
          response = await client.send(
            http.Request('GET', uri)
              ..followRedirects = false
              ..headers.addAll(headers),
          );
          if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) break;
          final location = response.headers['location'];
          if (location == null || redirects++ >= 3)
            throw StateError('重定向过多或缺少地址');
          final next = PluginMediaContract.uri(
            uri.resolve(location).toString(),
            origins,
          );
          if (next.origin != uri.origin) {
            for (final key in [
              'authorization',
              'cookie',
              'proxy-authorization',
              'host',
            ]) {
              headers.remove(key);
            }
          }
          uri = next;
          await active();
        }
        if (response.statusCode != 200)
          throw StateError('文件下载 HTTP ${response.statusCode}');
        final result = await files.writeStream(
          args['path'],
          response.stream.asyncMap((chunk) async {
            await active();
            state['bytes'] = (state['bytes'] as int) + chunk.length;
            return chunk;
          }),
          beforeCommit: active,
        );
        await active();
        state['state'] = 'completed';
        return {
          ...result,
          'status': response.statusCode,
          'headers': response.headers,
        };
      }
      return await files.locked(() async {
        final file = await files.file(args['path']);
        final length = await file.length();
        if (length > PluginFileStore.maxFile) throw StateError('文件超过 256 MiB');
        final verb = args['method'] ?? 'PUT';
        if (!{'PUT', 'POST', 'PATCH'}.contains(verb))
          throw const FormatException('上传 method 必须为 PUT、POST 或 PATCH');
        final request = http.StreamedRequest(verb as String, uri)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..contentLength = length;
        final sending = client.send(request);
        // Observe early network failures while the request body is still streaming.
        unawaited(
          sending.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
        );
        try {
          await request.sink.addStream(
            file.openRead().asyncMap((chunk) async {
              await active();
              state['bytes'] = (state['bytes'] as int) + chunk.length;
              return chunk;
            }),
          );
          await request.sink.close();
          final response = await sending;
          final bytes = <int>[];
          await for (final chunk in response.stream) {
            await active();
            if (bytes.length + chunk.length > 512 * 1024)
              throw StateError('上传响应超过 512 KiB');
            bytes.addAll(chunk);
          }
          await active();
          state['state'] = 'completed';
          return {
            'status': response.statusCode,
            'headers': response.headers,
            'bodyBase64': const Base64Codec().encode(bytes),
          };
        } finally {
          unawaited(request.sink.close().catchError((Object _) {}));
        }
      });
    } catch (_) {
      if (state['state'] == 'running') state['state'] = 'failed';
      rethrow;
    } finally {
      timer.cancel();
      client.close();
      _clients.remove(id);
    }
  }
}
