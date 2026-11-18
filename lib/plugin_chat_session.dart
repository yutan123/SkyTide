import 'plugin_media_pipeline.dart';
import 'plugin_file_store.dart';
import 'plugin_operation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'plugin_media_contract.dart';

abstract class PluginChatHost {
  Future<bool> hasBot(String botId);
  Future<Map<String, dynamic>?> findMessage(String id, String botId);
  Future<void> insert(Map<String, dynamic> message);
  Future<Directory> documents();
  Future<Directory> temporary();
  Future<T> locked<T>(String key, Future<T> Function() work);
  http.Client createClient();
}

/// An explicit capability for one tool invocation; never shared as global JS state.
class PluginChatSession {
  PluginChatSession({
    required this.pluginId,
    required this.botId,
    required this.assertCurrent,
    required this.host,
    this.downloadTimeout = PluginTimeouts.media,
    this.processMedia,
    this.files,
  });
  PluginFileStore? files;
  Future<void> Function(List<String>, Future<void> Function())? processMedia;
  final PluginChatHost host;
  final Duration downloadTimeout;
  final String pluginId, botId;
  final Future<void> Function() assertCurrent;
  final token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _resources = <String, Map<String, dynamic>>{};
  final _clients = <http.Client>{};
  Future<void> _queue = Future.value();
  bool _active = true;
  int _sent = 0;

  String _encodeCard(Map<String, dynamic> args) {
    final size = args['size'] ?? 'regular';
    final icon = args['icon'] ?? 'note';
    final color = args['color'];
    if (!const {'compact', 'regular', 'wide'}.contains(size) ||
        !const {'note', 'task', 'calendar', 'star', 'info'}.contains(icon) ||
        (color != null && (color is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)))) {
      throw const FormatException('卡片尺寸、图标或颜色无效');
    }
    return jsonEncode({
      'title': PluginMediaContract.text(args['title'], 'title', 100, required: true),
      'body': PluginMediaContract.text(args['body'], 'body', 2000),
      'prompt': PluginMediaContract.text(args['prompt'], 'prompt', 2000),
      'actionLabel': PluginMediaContract.text(args['actionLabel'], 'actionLabel', 40),
      'size': size,
      'icon': icon,
      'color': color,
    });
  }

  Future<void> check() async {
    if (!_active) throw StateError('调用上下文已结束');
    await assertCurrent();
    if (!_active) throw StateError('调用上下文已结束');
  }

  Future<dynamic> call(
    String method,
    Map<String, dynamic> args,
    List permissions,
    List origins,
  ) {
    // Serialize effects inside a call; native locks serialize between engines.
    final result = _queue.then((_) async {
      await check();
      if (method == 'chat.context')
        return {'botId': botId, 'conversationId': botId, 'pluginId': pluginId};
      if (method.startsWith('chat.') && !permissions.contains('chat.send'))
        throw StateError('未声明 chat.send 权限');
      if (method == 'chat.status') return _status(args);
      if (method.startsWith('media.') &&
          !permissions.contains('media.download'))
        throw StateError('未声明 media.download 权限');
      if (method == 'media.process') {
        if (!permissions.contains('media.process'))
          throw StateError('未声明 media.process 权限');
        return _process(args, permissions, origins);
      }
      if (method == 'media.fromFile') {
        if (!permissions.contains('files')) throw StateError('未声明 files 权限');
        return _fromFile(args);
      }
      if (method == 'media.saveFile') {
        if (!permissions.contains('files')) throw StateError('未声明 files 权限');
        final resource = _resources[args['resourceId']];
        if (resource == null || files == null) throw StateError('媒体引用或私有文件不可用');
        return files!.writeStream(
          args['path'],
          File(resource['path'] as String).openRead(),
          beforeCommit: check,
        );
      }
      if (method == 'media.download')
        return _download(args, permissions, origins);
      if (method == 'media.inspect') {
        final resource = _resources[args['resourceId']];
        if (resource == null) throw StateError('媒体引用不存在');
        return Map<String, dynamic>.from(resource)..remove('path');
      }
      if (method == 'media.release') {
        final resource = _resources.remove(args['resourceId']);
        if (resource == null) return false;
        await File(resource['path'] as String).delete();
        return true;
      }
      if (!{
        'chat.sendText',
        'chat.sendCard',
        'chat.sendImage',
        'chat.sendVideo',
        'chat.sendAudio',
        'chat.sendDocument',
        'chat.sendFile',
      }.contains(method))
        throw StateError('未知聊天 API');
      final requestId = PluginMediaContract.text(
        args['requestId'],
        'requestId',
        128,
        required: true,
      );
      final id = _messageId(requestId);
      return host.locked('chat:$id', () async {
        await check();
        final existing = await _row(id);
        if (existing != null) return _receipt(existing, duplicate: true);
        if (_sent >= 10) throw StateError('单次工具调用最多发送 10 条消息');
        if (!await host.hasBot(botId)) throw StateError('会话已不存在');
        final kind = method.substring('chat.send'.length).toLowerCase();
        final content = kind == 'card'
            ? _encodeCard(args)
            : PluginMediaContract.text(
          kind == 'text' ? args['text'] : args['caption'],
          kind == 'text' ? 'text' : 'caption',
          kind == 'text' ? 16000 : 2000,
          required: kind == 'text',
        );
        Map<String, dynamic>? resource;
        if (kind != 'text' && kind != 'card') {
          if (args['resourceId'] != null && args['url'] != null)
            throw const FormatException('url 与 resourceId 不能同时提供');
          if (args['resourceId'] == null) {
            final downloaded = await _download(
              {...args, 'kind': kind},
              permissions,
              origins,
            );
            resource = _resources[downloaded['resourceId']];
          } else {
            resource = _resources[args['resourceId']];
          }
          if (resource == null || (kind != 'file' && resource['kind'] != kind))
            throw StateError('媒体引用不存在或类型不匹配');
        }
        final fileName = kind == 'file'
            ? PluginMediaContract.fileName(
                args['fileName'] ?? resource?['fileName'],
                fallback: 'attachment.${resource?['extension'] ?? 'bin'}',
              )
            : null;
        final duration = args['duration'] ?? 0;
        if (duration is! int || duration < 0 || duration > 86400)
          throw const FormatException('duration 必须为 0～86400 的秒数');
        File? delivered;
        final row = <String, dynamic>{
          'id': id,
          'bot_id': botId,
          'role': 'assistant',
          'type': kind,
          'content': content,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'duration': duration,
        };
        try {
          if (resource != null) {
            final docs = await host.documents();
            final folder = Directory(
              p.join(docs.path, 'chat_media', 'plugins'),
            );
            await folder.create(recursive: true);
            final destination = kind == 'file'
                ? p.join(folder.path, id, fileName!)
                : p.join(folder.path, '$id.${resource['extension']}');
            await Directory(p.dirname(destination)).create(recursive: true);
            delivered = await File(
              resource['path'] as String,
            ).copy(destination);
            row['file_path'] = delivered.path;
          }
          // Lifecycle lock makes invalidation and the final commit mutually exclusive.
          await host.locked('lifecycle', () async {
            await check();
            await host.insert(row);
          });
          _sent++;
          return _receipt(row);
        } catch (_) {
          // Notifications may fail after persistence; never remove committed media.
          final committed = await _row(id);
          if (committed != null) {
            _sent++;
            return _receipt(committed);
          }
          if (delivered != null && await delivered.exists())
            await delivered.delete();
          rethrow;
        }
      });
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  String _messageId(String key) =>
      'plugin_${sha256.convert(utf8.encode(jsonEncode([pluginId, botId, key])))}';
  Future<Map<String, dynamic>?> _row(String id) async {
    return host.findMessage(id, botId);
  }

  Map<String, dynamic> _receipt(Map row, {bool duplicate = false}) => {
    'messageId': row['id'],
    'botId': botId,
    'type': row['type'],
    'status': 'sent',
    'duplicate': duplicate,
    'timestamp': row['timestamp'],
  };
  Future<Map<String, dynamic>> _status(Map<String, dynamic> args) async {
    final key = PluginMediaContract.text(
      args['requestId'],
      'requestId',
      128,
      required: true,
    );
    final row = await _row(_messageId(key));
    return row == null ? {'status': 'not_found'} : _receipt(row);
  }

  Future<Map<String, dynamic>> _registerFile(
    File file,
    String kind, {
    String? fileName,
  }) async {
    if (_resources.length >= 4) throw StateError('单次调用最多保留 4 个媒体资源，请先释放');
    final size = await file.length();
    if (size > PluginMediaContract.limits[kind]!) throw StateError('媒体超过大小限制');
    final handle = await file.open();
    String extension;
    try {
      extension = PluginMediaContract.extension(await handle.read(64), kind);
    } finally {
      await handle.close();
    }
    await check();
    final id = 'r${Random.secure().nextInt(1 << 32)}';
    final resource = <String, dynamic>{
      'resourceId': id,
      'kind': kind,
      'size': size,
      'extension': extension,
      if (fileName != null) 'fileName': fileName,
      'path': file.path,
    };
    _resources[id] = resource;
    return Map<String, dynamic>.from(resource)..remove('path');
  }

  Future<Map<String, dynamic>> _fromFile(Map args) async {
    final store = files;
    if (store == null) throw StateError('私有文件不可用');
    final kind = args['kind'];
    if (!PluginMediaContract.limits.containsKey(kind))
      throw const FormatException('kind 无效');
    final folder = Directory(
      p.join((await host.temporary()).path, 'tide_plugin_media', token),
    );
    await folder.create(recursive: true);
    final copy = File(
      p.join(folder.path, 'import-${Random.secure().nextInt(1 << 32)}'),
    );
    try {
      await store.locked(() async {
        final source = await store.file(args['path']);
        if (await source.length() > PluginMediaContract.limits[kind]!)
          throw StateError('媒体超过大小限制');
        await source.copy(copy.path);
      });
      return await _registerFile(
        copy,
        kind as String,
        fileName: kind == 'file'
            ? PluginMediaContract.fileName(
                args['fileName'],
                fallback: p.posix.basename(args['path'] as String),
              )
            : null,
      );
    } catch (_) {
      if (await copy.exists()) await copy.delete();
      rethrow;
    }
  }

  Future<String> _fetchPart(
    String address,
    File target,
    Map headers,
    List origins,
    void Function(int) received,
  ) async {
    var uri = PluginMediaContract.uri(address, origins);
    final requestHeaders = PluginMediaContract.headers(headers);
    final client = host.createClient();
    _clients.add(client);
    try {
      return await (() async {
        for (var redirects = 0; redirects <= 3; redirects++) {
          await check();
          final response = await client.send(
            http.Request('GET', uri)
              ..followRedirects = false
              ..headers.addAll(requestHeaders),
          );
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers['location'];
            if (location == null || redirects == 3)
              throw StateError('媒体重定向过多或缺少地址');
            final next = PluginMediaContract.uri(
              uri.resolve(location).toString(),
              origins,
            );
            if (next.origin != uri.origin)
              for (final key in [
                'authorization',
                'cookie',
                'proxy-authorization',
                'host',
              ]) {
                requestHeaders.remove(key);
              }
            uri = next;
            await response.stream.drain<void>();
            continue;
          }
          if (response.statusCode != 200)
            throw StateError('媒体下载 HTTP ${response.statusCode}');
          final output = await target.open(mode: FileMode.write);
          var size = 0;
          try {
            await for (final chunk in response.stream) {
              await check();
              size += chunk.length;
              received(chunk.length);
              if (size > 256 * 1024 * 1024) throw StateError('HLS 分片超过大小限制');
              await output.writeFrom(chunk);
            }
          } finally {
            await output.close();
          }
          return uri.toString();
        }
        throw StateError('媒体重定向过多');
      })().timeout(downloadTimeout);
    } finally {
      client.close();
      _clients.remove(client);
    }
  }

  Future<Map<String, dynamic>> _process(
    Map args,
    List permissions,
    List origins,
  ) async {
    final processor = processMedia;
    if (processor == null) throw StateError('媒体处理不可用');
    if (_resources.length >= 4) throw StateError('请先释放媒体资源');
    final operation = args['operation'];
    final format = args['format'] ?? 'mp4';
    // Validate the plan before downloading inputs.
    PluginMediaPipeline.arguments(
      args,
      operation == 'merge' ? ['video', 'audio'] : ['input'],
      'output',
    );
    final work = await Directory(
      p.join((await host.temporary()).path, 'tide_plugin_media', token),
    ).create(recursive: true);
    final folder = await work.createTemp('process-');
    File? delivered;
    try {
      final inputs = <String>[];
      if (operation == 'hls') {
        if (!permissions.contains('network'))
          throw StateError('HLS 下载需要 network 权限');
        final url = args['url'];
        if (url is! String) throw const FormatException('url 必须为字符串');
        var downloaded = 0;
        final originalOrigin = PluginMediaContract.uri(url, origins).origin;
        inputs.add(
          await PluginMediaPipeline.hls(
            url: url,
            directory: folder,
            download: (address, file) {
              final headers = PluginMediaContract.headers(args['headers']);
              if (PluginMediaContract.uri(address, origins).origin !=
                  originalOrigin) {
                for (final key in [
                  'authorization',
                  'cookie',
                  'proxy-authorization',
                  'host',
                ]) {
                  headers.remove(key);
                }
              }
              return _fetchPart(address, file, headers, origins, (bytes) {
                downloaded += bytes;
                if (downloaded > 256 * 1024 * 1024)
                  throw StateError('HLS 总下载量超过 256 MiB');
              });
            },
            check: check,
          ),
        );
      } else {
        final ids = operation == 'merge'
            ? [args['videoResourceId'], args['audioResourceId']]
            : [args['resourceId']];
        for (var i = 0; i < ids.length; i++) {
          final resource = _resources[ids[i]];
          if (resource == null ||
              !{'video', 'audio'}.contains(resource['kind']))
            throw StateError('媒体引用不存在或类型不支持');
          if (operation == 'merge' &&
              resource['kind'] != (i == 0 ? 'video' : 'audio'))
            throw StateError('合并需要视频和音频引用');
          inputs.add(resource['path'] as String);
        }
      }
      final output = File(p.join(folder.path, 'output.$format'));
      await processor(
        PluginMediaPipeline.arguments(args, inputs, output.path),
        check,
      );
      await check();
      if (!await output.exists() || await output.length() >= 256 * 1024 * 1024)
        throw StateError('媒体处理输出无效或达到大小上限');
      delivered = await output.rename(
        p.join(
          work.path,
          'processed-${Random.secure().nextInt(1 << 32)}.$format',
        ),
      );
      return await _registerFile(
        delivered,
        {'mp3', 'wav', 'm4a'}.contains(format) ? 'audio' : 'video',
      );
    } catch (_) {
      if (delivered != null && await delivered.exists())
        await delivered.delete();
      rethrow;
    } finally {
      if (await folder.exists()) await folder.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> _download(
    Map<String, dynamic> args,
    List permissions,
    List origins,
  ) async {
    if (!permissions.contains('media.download') ||
        !permissions.contains('network'))
      throw StateError('下载需要 network 和 media.download 权限');
    final kind = args['kind'];
    final max = PluginMediaContract.limits[kind];
    if (max == null)
      throw const FormatException('kind 必须为 image/video/audio/document/file');
    if (_resources.length >= 4) throw StateError('单次调用最多保留 4 个媒体资源，请先释放');
    var uri = PluginMediaContract.uri(args['url'], origins);
    final fileName = kind == 'file'
        ? PluginMediaContract.fileName(
            args['fileName'],
            fallback: _urlFileName(uri),
          )
        : null;
    final headers = PluginMediaContract.headers(args['headers']);
    final timeoutMs = args['timeoutMs'];
    if (timeoutMs != null &&
        (timeoutMs is! int ||
            timeoutMs < 1 ||
            timeoutMs > PluginTimeouts.media.inMilliseconds)) {
      throw const FormatException('timeoutMs 必须为媒体超时上限以内的正整数');
    }
    final timeout = timeoutMs == null
        ? downloadTimeout
        : Duration(milliseconds: timeoutMs as int);
    final client = host.createClient();
    _clients.add(client);
    File? partial;
    RandomAccessFile? handle;
    var expired = false;
    Future<void> downloadCheck() async {
      if (expired) throw TimeoutException('媒体下载超时');
      await check();
      if (expired) throw TimeoutException('媒体下载超时');
    }

    Future<Map<String, dynamic>>? operation;
    try {
      operation = (() async {
        http.StreamedResponse? response;
        for (var redirects = 0; redirects <= 3; redirects++) {
          await downloadCheck();
          response = await client.send(
            http.Request('GET', uri)
              ..followRedirects = false
              ..headers.addAll(headers),
          );
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers['location'];
            if (location == null || redirects == 3)
              throw StateError('媒体重定向过多或缺少地址');
            final next = PluginMediaContract.uri(
              uri.resolve(location).toString(),
              origins,
            );
            if (next.origin != uri.origin) {
              headers.remove('authorization');
              headers.remove('cookie');
              headers.remove('proxy-authorization');
              headers.remove('host');
            }
            uri = next;
            await response.stream.drain<void>();
            continue;
          }
          break;
        }
        if (response == null || response.statusCode != 200)
          throw StateError('媒体下载 HTTP ${response?.statusCode}');
        if ((response.contentLength ?? 0) > max) throw StateError('媒体超过大小限制');
        final temp = await host.temporary();
        final folder = Directory(p.join(temp.path, 'tide_plugin_media', token));
        await folder.create(recursive: true);
        final resourceId =
            'r${_resources.length}_${Random.secure().nextInt(1 << 32)}';
        partial = File(p.join(folder.path, resourceId));
        handle = await partial!.open(mode: FileMode.write);
        final head = <int>[];
        var size = 0;
        await for (final chunk in response.stream) {
          await downloadCheck();
          size += chunk.length;
          if (size > max) throw StateError('媒体超过大小限制');
          if (head.length < 64) head.addAll(chunk.take(64 - head.length));
          await handle!.writeFrom(chunk);
        }
        await handle!.close();
        handle = null;
        final extension = PluginMediaContract.extension(head, kind as String);
        await downloadCheck();
        final resource = {
          'resourceId': resourceId,
          'kind': kind,
          'size': size,
          'extension': extension,
          if (fileName != null) 'fileName': fileName,
          'path': partial!.path,
        };
        _resources[resourceId] = resource;
        partial = null;
        return Map<String, dynamic>.from(resource)..remove('path');
      })();
      return await operation.timeout(
        timeout,
        onTimeout: () async {
          expired = true;
          client.close();
          // Wait for the cancelled stream to unwind before touching its file.
          try {
            await operation;
          } catch (_) {}
          throw TimeoutException('媒体下载超时');
        },
      );
    } finally {
      client.close();
      _clients.remove(client);
      await handle?.close();
      if (partial != null && await partial!.exists()) await partial!.delete();
    }
  }

  String _urlFileName(Uri uri) {
    if (uri.pathSegments.isEmpty || uri.pathSegments.last.isEmpty)
      return 'attachment.bin';
    try {
      return PluginMediaContract.fileName(uri.pathSegments.last);
    } on FormatException {
      return 'attachment.bin';
    }
  }

  void cancel() {
    _active = false;
    for (final client in _clients.toList()) {
      client.close();
    }
  }

  Future<void> close() async {
    cancel();
    await _queue;
    final temp = await host.temporary();
    final folder = Directory(p.join(temp.path, 'tide_plugin_media', token));
    if (await folder.exists()) await folder.delete(recursive: true);
    _resources.clear();
  }
}
