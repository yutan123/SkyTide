import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'chat_api_endpoint.dart';
import 'package:crypto/crypto.dart';

/// Stateless text generation using configured providers without sharing credentials.
class PluginAI {
  PluginAI({
    required this.check,
    required this.providers,
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 120),
  }) : clientFactory = clientFactory ?? http.Client.new;
  final Future<List<Map<String, dynamic>>> Function() providers;
  final http.Client Function() clientFactory;
  final Duration timeout;
  final _cancelled = <String>{};
  static String providerId(Map provider) =>
      sha256.convert(utf8.encode(provider['id'].toString())).toString();
  final Future<void> Function() check;
  final _clients = <String, http.Client>{};
  bool _closed = false;
  Future<dynamic> call(String method, Map args) async {
    await check();
    if (_closed) throw StateError('插件已停止');
    if (method == 'ai.cancel') {
      final client = _clients[args['requestId']];
      if (client != null) {
        _cancelled.add(args['requestId'] as String);
        client.close();
      }
      return client != null;
    }
    final available = await providers();
    await check();
    if (_closed) throw StateError('插件已停止');
    if (method == 'ai.listModels') {
      return [
        for (final p in available)
          {
            'id': providerId(p),
            'name': p['name'],
            'models': p['model']
                .toString()
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
          },
      ];
    }
    if (method != 'ai.generate') throw StateError('未知 AI 接口');
    final id = args['requestId'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id))
      throw const FormatException('requestId 无效');
    if (_clients.containsKey(id) || _clients.length >= 2)
      throw StateError('AI 请求重复或超过并发上限 2');
    final matches = available.where((p) => providerId(p) == args['providerId']);
    if (matches.isEmpty) throw StateError('模型提供商不存在');
    final provider = matches.first;
    final models = provider['model']
        .toString()
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final model = args['model'] ?? (models.isEmpty ? '' : models.first);
    if (!models.contains(model))
      throw const FormatException('model 不在提供商已配置的模型中');
    final messages = args['messages'];
    if (messages is! List ||
        messages.isEmpty ||
        messages.length > 64 ||
        messages.any(
          (m) =>
              m is! Map ||
              !{'system', 'user', 'assistant'}.contains(m['role']) ||
              m['content'] is! String,
        ))
      throw const FormatException('messages 必须包含 1 至 64 条文本消息');
    if (utf8.encode(jsonEncode(messages)).length > 256 * 1024)
      throw const FormatException('messages 超过 256 KiB');
    final maxTokens = args['maxTokens'] ?? 2048;
    final temperature = args['temperature'] ?? 0.7;
    if (maxTokens is! int ||
        maxTokens < 1 ||
        maxTokens > 8192 ||
        temperature is! num ||
        !temperature.isFinite ||
        temperature < 0 ||
        temperature > 2)
      throw const FormatException('maxTokens 或 temperature 无效');
    await check();
    if (_closed || _clients.containsKey(id) || _clients.length >= 2)
      throw StateError('AI 请求不可启动');
    final client = clientFactory();
    _clients[id] = client;
    try {
      return await (() async {
        final request =
            http.Request(
                'POST',
                Uri.parse(chatApiEndpoint(provider['base_url'].toString())),
              )
              ..followRedirects = false
              ..headers.addAll({
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${provider['api_key']}',
              })
              ..body = jsonEncode({
                'model': model,
                'messages': [
                  for (final m in messages)
                    {'role': m['role'], 'content': m['content']},
                ],
                'stream': false,
                'max_tokens': maxTokens,
                'temperature': temperature,
              });
        final response = await client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300)
          throw StateError('AI 服务返回 HTTP ${response.statusCode}');
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 512 * 1024)
            throw StateError('AI 响应超过 512 KiB');
          bytes.addAll(chunk);
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map;
        final choices = body['choices'];
        if (choices is! List ||
            choices.isEmpty ||
            choices.first is! Map ||
            choices.first['message'] is! Map)
          throw StateError('模型响应结构无效');
        final content = choices.first['message']['content'];
        if (content is! String) throw StateError('模型未返回文本');
        await check();
        if (_closed || _cancelled.contains(id)) throw StateError('AI 请求已取消');
        return {'text': content, 'model': model, 'requestId': id};
      })().timeout(timeout);
    } on FormatException {
      throw StateError('AI 服务配置或响应格式无效');
    } on TimeoutException {
      throw StateError('AI 请求超时');
    } on http.ClientException {
      throw StateError('AI 请求已取消或连接失败');
    } finally {
      client.close();
      if (identical(_clients[id], client)) {
        _clients.remove(id);
        _cancelled.remove(id);
      }
    }
  }

  void close() {
    _closed = true;
    for (final client in _clients.values) {
      client.close();
    }
    // IDs stay reserved until each request has finished cleanup.
  }
}
