import 'dart:async';
import 'dart:io';
import 'plugin_crypto.dart';
import 'plugin_media_contract.dart';

/// One browser authorization per runtime, using a state checked loopback callback.
class PluginOAuth {
  bool _closed = false;
  HttpServer? _server;
  Completer<Map<String, dynamic>>? _pending;

  void close() {
    _closed = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted)
      pending.completeError(StateError('授权已取消'));
    unawaited(_server?.close(force: true));
  }

  Future<Map<String, dynamic>> authorize(
    Map args,
    List origins,
    Future<void> Function() check,
    Future<bool> Function(Uri) launch,
  ) async {
    if (_closed) throw StateError('插件授权已停止');
    if (_pending != null) throw StateError('已有进行中的授权');
    final uri = PluginMediaContract.uri(args['url'], origins);
    if (uri.hasQuery)
      throw const FormatException('授权端点不能预置查询参数，请使用 parameters');
    final parameters = args['parameters'] == null
        ? <String, String>{}
        : Map<String, String>.from(args['parameters'] as Map);
    if (parameters.length > 24 ||
        parameters.values.any((v) => v.length > 4096) ||
        parameters.keys.any((k) => k.length > 80))
      throw const FormatException('授权参数过多或过长');
    if (parameters['client_id']?.isNotEmpty != true)
      throw const FormatException('授权需要 client_id');
    final pending = Completer<Map<String, dynamic>>();
    _pending = pending;
    // Attach an error listener before asynchronous bind/launch can be cancelled.
    final result = pending.future.timeout(const Duration(minutes: 3));
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    try {
      final pkce = await PluginCrypto.call('auth.createPkce', {}) as Map;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      if (_closed) throw StateError('插件授权已停止');
      final redirectUri = 'http://127.0.0.1:${server.port}/callback';
      server.listen(
        (request) async {
          try {
            request.response.headers.contentType = ContentType(
              'text',
              'plain',
              charset: 'utf-8',
            );
            request.response.headers.set('cache-control', 'no-store');
            Map<String, dynamic>? value;
            Object? failure;
            final query = request.uri.queryParameters;
            if (request.method != 'GET' ||
                request.uri.path != '/callback' ||
                query['state'] != pkce['state']) {
              request.response.statusCode = 400;
              request.response.write('Invalid authorization callback');
            } else if (!pending.isCompleted) {
              if (query['error'] != null) {
                failure = StateError('OAuth 授权被拒绝');
                request.response.write(
                  'Authorization declined. You may close this page.',
                );
              } else if (query['code']?.isNotEmpty == true &&
                  query['code']!.length <= 8192) {
                value = {
                  'code': query['code'],
                  'verifier': pkce['verifier'],
                  'redirectUri': redirectUri,
                  'state': pkce['state'],
                };
                request.response.write(
                  'Authorization received. You may close this page.',
                );
              } else {
                request.response.statusCode = 400;
                request.response.write('Missing authorization code');
              }
            }
            await request.response.close();
            if (!pending.isCompleted) {
              if (failure != null)
                pending.completeError(failure);
              else if (value != null)
                pending.complete(value);
            }
          } catch (_) {
            try {
              await request.response.close();
            } catch (_) {}
          }
        },
        onError: (Object error) {
          if (!pending.isCompleted) pending.completeError(error);
        },
      );
      await check();
      if (_closed) throw StateError('插件授权已停止');
      final target = uri.replace(
        queryParameters: {
          ...parameters,
          'response_type': 'code',
          'redirect_uri': redirectUri,
          'state': pkce['state'] as String,
          'code_challenge': pkce['challenge'] as String,
          'code_challenge_method': 'S256',
        },
      );
      if (!await launch(target)) throw StateError('无法打开授权浏览器');
      final value = await result;
      await check();
      return value;
    } finally {
      if (!pending.isCompleted) pending.completeError(StateError('授权已结束'));
      await _server?.close(force: true);
      _server = null;
      _pending = null;
    }
  }
}
