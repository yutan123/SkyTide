import 'plugin_media_contract.dart';
import 'plugin_connections.dart';
import 'plugin_oauth.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'plugin_operation.dart';

/// Per-runtime HTTP handles. No local paths, cookies or automatic redirects.
class PluginNetwork {
  PluginNetwork({http.Client Function()? createClient})
    : _createClient = createClient ?? http.Client.new;
  final http.Client Function() _createClient;
  final connections = PluginConnections();
  final authorizations = PluginOAuth();
  bool _closed = false;
  final _calls = <String, _Transfer>{};
  void close() {
    _closed = true;
    connections.close();
    authorizations.close();
    for (final call in _calls.values) {
      call.cancelled = true;
      call.client.close();
    }
    _calls.clear();
  }

  dynamic control(String method, Map args) {
    final call = _calls[args['requestId']];
    if (method == 'http.cancel') {
      if (call == null || call.done) return false;
      call.cancelled = true;
      call.client.close();
      return true;
    }
    if (call == null) return null;
    return {
      'sent': call.sent,
      'received': call.received,
      'total': call.total,
      'state': call.cancelled
          ? 'cancelled'
          : call.done
          ? 'finished'
          : 'running',
    };
  }

  Future<Map<String, dynamic>> request(
    Map args,
    List origins,
    Future<void> Function() check,
  ) async {
    final id = args['requestId'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(id)) {
      throw const FormatException('requestId 无效');
    }
    if (_calls.containsKey(id)) throw StateError('requestId 已使用');
    if (_calls.values.where((c) => !c.done).length >= 8)
      throw StateError('最多八个并发网络请求');
    if (_calls.length >= 64) {
      _calls.removeWhere((_, call) => call.done);
    }
    final uri = Uri.tryParse(
      args['url'] is String ? args['url'] as String : '',
    );
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !PluginMediaContract.allows(uri, origins)) {
      throw const FormatException('请求地址必须属于已声明的 HTTPS origin');
    }
    final timeout = args['timeoutMs'] ?? PluginTimeouts.network.inMilliseconds;
    if (timeout is! int ||
        timeout < 1 ||
        timeout > PluginTimeouts.network.inMilliseconds)
      throw const FormatException('timeoutMs 无效');
    final method = (args['method'] as String? ?? 'GET').toUpperCase();
    if (!{
      'GET',
      'HEAD',
      'OPTIONS',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
    }.contains(method))
      throw const FormatException('HTTP 方法不支持');
    final request = http.Request(method, uri)..followRedirects = false;
    if (args['headers'] != null)
      request.headers.addAll(Map<String, String>.from(args['headers'] as Map));
    if (args['body'] != null && args['multipart'] != null)
      throw const FormatException('body 与 multipart 不能同时设置');
    request.body = args['body'] as String? ?? '';
    if (args['multipart'] != null) {
      final parts = args['multipart'];
      if (parts is! List || parts.length > 16)
        throw const FormatException('multipart 最多十六项');
      final multipart = http.MultipartRequest(method, uri);
      for (final part in parts) {
        if (part is! Map ||
            part['name'] is! String ||
            !RegExp(r'^[a-zA-Z0-9_.-]{1,80}$').hasMatch(part['name'] as String))
          throw const FormatException('multipart name 无效');
        if (part['base64'] != null) {
          final filename = part['filename'];
          if (filename is! String ||
              !RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(filename))
            throw const FormatException('filename 无效');
          final bytes = base64Decode(part['base64'] as String);
          if (bytes.length > 512 * 1024)
            throw const FormatException('单个上传文件超过 512 KiB');
          multipart.files.add(
            http.MultipartFile.fromBytes(
              part['name'] as String,
              bytes,
              filename: filename,
            ),
          );
        } else {
          multipart.fields[part['name'] as String] = part['value'] as String;
        }
      }
      final stream = multipart.finalize();
      request.bodyBytes = await stream.toBytes();
      request.headers['content-type'] = multipart.headers['content-type']!;
    }
    if (request.bodyBytes.length > 768 * 1024)
      throw const FormatException('请求体超过 768 KiB');
    await check();
    if (_closed) throw StateError('网络运行实例已停止');
    if (_calls.containsKey(id)) throw StateError('requestId 已使用');
    if (_calls.values.where((c) => !c.done).length >= 8)
      throw StateError('最多八个并发网络请求');
    final call = _Transfer(_createClient());
    _calls[id] = call;
    try {
      return await (() async {
        final outgoing = http.StreamedRequest(method, uri)
          ..followRedirects = false;
        outgoing.headers.addAll(request.headers);
        outgoing.contentLength = request.bodyBytes.length;
        final responseFuture = call.client.send(outgoing);
        for (
          var offset = 0;
          offset < request.bodyBytes.length;
          offset += 16384
        ) {
          if (call.cancelled) throw const PluginOperationCancelled();
          final end = (offset + 16384).clamp(0, request.bodyBytes.length);
          outgoing.sink.add(request.bodyBytes.sublist(offset, end));
          call.sent = end;
        }
        unawaited(outgoing.sink.close().catchError((Object _) {}));
        final response = await responseFuture;
        call.total = response.contentLength;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (call.cancelled) throw const PluginOperationCancelled();
          bytes.addAll(chunk);
          call.received = bytes.length;
          if (bytes.length > 1024 * 1024) throw StateError('响应超过 1 MiB');
        }
        await check();
        if (call.cancelled) throw const PluginOperationCancelled();
        return {
          'status': response.statusCode,
          'headers': response.headers,
          'body': utf8.decode(bytes, allowMalformed: true),
        };
      })().timeout(Duration(milliseconds: timeout));
    } catch (_) {
      if (call.cancelled) throw const PluginOperationCancelled();
      rethrow;
    } finally {
      call.done = true;
      call.client.close();
    }
  }
}

class _Transfer {
  _Transfer(this.client);
  final http.Client client;
  bool cancelled = false, done = false;
  int sent = 0, received = 0;
  int? total;
}
