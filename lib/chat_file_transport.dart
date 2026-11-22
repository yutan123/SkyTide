import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;

import 'chat_api_endpoint.dart';
import 'chat_attachment_access.dart';
import 'chat_file_capability.dart';
import 'chat_provider_cache.dart';
import 'native_chat_api.dart';

enum ChatFileProtocol {
  openAIResponses,
  openAIChat,
  claude,
  gemini,
  grok,
  deepSeek,
  qwenLong,
  unsupported;

  static ChatFileProtocol resolve(
    ChatProviderCache provider,
    String model,
    NativeChatApi? nativeApi,
  ) => switch (provider) {
    ChatProviderCache.gpt => openAIResponses,
    ChatProviderCache.compatible || ChatProviderCache.gitee => openAIChat,
    ChatProviderCache.claude when nativeApi == NativeChatApi.claude => claude,
    ChatProviderCache.gemini when nativeApi == NativeChatApi.gemini => gemini,
    ChatProviderCache.grok => grok,
    ChatProviderCache.deepSeek when model == 'deepseek-flash' => deepSeek,
    ChatProviderCache.dashScope when model == 'qwen-long' => qwenLong,
    _ => unsupported,
  };
}

typedef ChatFileUpload =
    Future<String> Function(Future<String> Function(http.Client) action);

class ChatFileDeliveryException implements Exception {
  const ChatFileDeliveryException([
    this.statusCode,
    this.extractedText = false,
  ]);

  final int? statusCode;
  final bool extractedText;

  String get message {
    final input = extractedText ? '附件正文' : '原文件';
    final status = statusCode == null ? '' : '（HTTP $statusCode）';
    return '携带$input的请求失败$status，模型未能确认读取。';
  }
}

/// Owns the byte budget and uploaded file IDs for one initial/tool request chain.
class ChatFileTransport {
  ChatFileTransport(
    this.protocol, {
    required this.baseUrl,
    required this.apiKey,
  });

  final ChatFileProtocol protocol;
  final String baseUrl;
  final String apiKey;
  final _references = <String>[];
  final _attached = <int>{};
  final _rawParts = Map<Map<String, dynamic>, ChatFileReference>.identity();
  final _qwenFiles = <ChatFileReference>[];
  Map<String, dynamic>? _qwenUser;
  Map<String, dynamic>? _qwenReferenceMessage;
  var _textOnly = false;
  var _textRemaining = 48000;
  var _remaining = chatFileTurnByteLimit;

  bool get hasRawAttachments => _rawParts.isNotEmpty;
  bool get usedTextFallback => _textRemaining < 48000;

  bool get hasAttachments => _attached.isNotEmpty;
  bool contains(int number) => _attached.contains(number);

  Uri get _filesEndpoint {
    final base = Uri.parse(chatApiBase(baseUrl)).removeFragment();
    final path =
        protocol == ChatFileProtocol.deepSeek &&
            base.host == 'api.deepseek.com' &&
            base.path == '/v1'
        ? ''
        : base.path;
    return base.replace(path: '$path/files');
  }

  Future<Map<String, dynamic>> attach(
    ChatFileReference file, {
    ChatFileUpload? upload,
  }) async {
    if (protocol == ChatFileProtocol.unsupported) {
      throw const ChatFileUnsupported('当前提供商或模型没有可用的原文件聊天接口');
    }
    final extension = p.extension(file.name).toLowerCase();
    final mime = chatFileMimeType(extension);
    if (mime == null ||
        (protocol == ChatFileProtocol.claude && extension != '.pdf') ||
        (protocol == ChatFileProtocol.gemini &&
            mime != 'application/pdf' &&
            mime != 'text/plain') ||
        (protocol == ChatFileProtocol.openAIChat && extension != '.pdf') ||
        (protocol == ChatFileProtocol.qwenLong &&
            !const {
              '.txt',
              '.docx',
              '.pdf',
              '.xlsx',
              '.epub',
              '.mobi',
              '.md',
              '.csv',
              '.json',
            }.contains(extension))) {
      throw const ChatFileUnsupported('当前聊天接口不支持此原文件格式');
    }
    final bytes = await readChatFileBytes(file, remainingBytes: _remaining);
    final Map<String, dynamic> part;
    switch (protocol) {
      case ChatFileProtocol.grok:
      case ChatFileProtocol.deepSeek:
      case ChatFileProtocol.qwenLong:
        if (upload == null) throw StateError('No upload client configured');
        final id = await upload((client) async {
          final request = http.MultipartRequest('POST', _filesEndpoint)
            ..followRedirects = false
            ..headers['Authorization'] = 'Bearer $apiKey';
          switch (protocol) {
            case ChatFileProtocol.grok:
              request.fields.addAll({
                'purpose': 'assistants',
                'expires_after': '3600',
              });
            case ChatFileProtocol.deepSeek:
              request.fields.addAll({
                'purpose':
                    const {
                      '.pdf',
                      '.doc',
                      '.docx',
                      '.ppt',
                      '.pptx',
                    }.contains(extension)
                    ? 'rich_layout_recognition'
                    : 'user_data',
                'expires_after[anchor]': 'created_at',
                'expires_after[seconds]': '3600',
              });
            case ChatFileProtocol.qwenLong:
              request.fields['purpose'] = 'file-extract';
            default:
              throw StateError('Not a file upload protocol');
          }
          request.files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: file.name,
              contentType: MediaType.parse(mime),
            ),
          );
          final httpResponse = client
              .send(request)
              .then(http.Response.fromStream);
          final response = await httpResponse.timeout(
            Duration(seconds: protocol == ChatFileProtocol.deepSeek ? 250 : 90),
            onTimeout: () => throw const FormatException('等待原文件上传超时'),
          );
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final status = response.statusCode;
            if (isMissingFileEndpoint(status, response.body) ||
                (const {400, 415, 422}.contains(status) &&
                    isFileCapabilityErrorBody(response.body))) {
              throw const ChatFileUnsupported('厂商上传接口不支持此原文件');
            }
            throw FormatException('原文件上传失败（HTTP $status）');
          }
          final Object? body;
          try {
            body = jsonDecode(response.body);
          } on FormatException {
            throw const FormatException('原文件上传返回了非 JSON 响应');
          }
          final id = body is Map ? body['id'] : null;
          if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
            throw const FormatException('原文件上传未返回有效的文件编号');
          }
          _references.add(id);
          return id;
        });
        part = {
          'type': protocol == ChatFileProtocol.deepSeek ? 'file' : 'input_file',
          'file_id': id,
        };
      default:
        final data = 'data:$mime;base64,${base64Encode(bytes)}';
        part = protocol == ChatFileProtocol.openAIChat
            ? {
                'type': 'file',
                'file': {'filename': file.name, 'file_data': data},
              }
            : {'type': 'input_file', 'filename': file.name, 'file_data': data};
    }
    _remaining -= bytes.length;
    _attached.add(file.number);
    _rawParts[part] = file;
    return part;
  }

  Future<Map<String, dynamic>> attachWithTextFallback(
    ChatFileReference file, {
    required Future<String> Function(String) extract,
    ChatFileUpload? upload,
  }) async {
    if (!_textOnly) {
      try {
        return await attach(file, upload: upload);
      } on ChatFileUnsupported {
        // Only a capability rejection permits a text retry.
      }
    }
    return _textPart(file, extract);
  }

  Future<Map<String, dynamic>> _textPart(
    ChatFileReference file,
    Future<String> Function(String) extract,
  ) async {
    if (_textRemaining <= 0) throw const FormatException('本轮附件提取文本已达到上限');
    final text = await extract(file.path);
    if (text.trim().isEmpty) throw const FormatException('未提取到可用正文');
    var end = text.length > _textRemaining ? _textRemaining : text.length;
    if (end < text.length && (text.codeUnitAt(end - 1) & 0xfc00) == 0xd800)
      end--;
    if (end == 0) throw const FormatException('本轮附件提取文本已达到上限');
    _textRemaining -= end;
    _attached.add(file.number);
    return {
      'type': 'text',
      'text':
          '${file.label}（仅提取文本，未提供原文件）\n${text.substring(0, end)}'
          '${end < text.length ? '\n[受本轮文本上限限制，正文已截断]' : ''}',
    };
  }

  static Object userContent(List<dynamic> parts) =>
      parts.every((part) => part is Map && part['type'] == 'text')
      ? parts.map((part) => part['text']).join('\n')
      : parts;

  /// Retries the same request, without asking the caller to replay tool calls.
  Future<http.StreamedResponse> sendWithTextFallback({
    required http.Client client,
    required List<Map<String, dynamic>> messages,
    required Future<String> Function(String) extract,
    required Future<http.StreamedResponse> Function(http.Client) send,
    void Function()? onMissingEndpoint,
  }) async {
    if (!hasRawAttachments && onMissingEndpoint == null) return send(client);
    try {
      return await send(
        ChatFileCapabilityClient(
          client,
          inspectFiles: hasRawAttachments,
          allowMissingEndpoint: onMissingEndpoint != null,
        ),
      );
    } on ChatFileUnsupported catch (error) {
      if (error is ChatFileEndpointMissing) onMissingEndpoint!();
      await replaceWithExtractedText(messages, extract);
      return send(client);
    }
  }

  Future<void> replaceWithExtractedText(
    List<Map<String, dynamic>> messages,
    Future<String> Function(String) extract,
  ) async {
    _textOnly = true;
    if (_qwenReferenceMessage != null) messages.remove(_qwenReferenceMessage);
    _qwenReferenceMessage = null;
    Future<Map<String, dynamic>> textFor(ChatFileReference file) async {
      try {
        return await _textPart(file, extract);
      } on FormatException catch (error) {
        _attached.remove(file.number);
        return {
          'type': 'text',
          'text': '${file.label}（未能读取附件：${error.message}）',
        };
      }
    }

    for (final message in messages) {
      if (message['role'] != 'user') continue;
      final content = message['content'];
      final qwen = identical(message, _qwenUser);
      if (!qwen && (content is! List || !content.any(_rawParts.containsKey)))
        continue;
      message['content'] = userContent([
        if (content is List)
          for (final part in content)
            if (_rawParts[part] case final file?) await textFor(file) else part,
        if (content is String && content.isNotEmpty)
          {'type': 'text', 'text': content},
        if (qwen)
          for (final file in _qwenFiles) await textFor(file),
      ]);
    }
    _rawParts.clear();
    _qwenFiles.clear();
  }

  Future<void> attachToUserMessage(
    Map<String, dynamic> message,
    List<ChatFileReference> files, {
    ChatFileUpload? upload,
    Future<String> Function(String)? extract,
  }) async {
    if (message['role'] != 'user') {
      throw const FormatException('无法定位本轮附件对应的用户消息');
    }
    final previous = message['content'];
    final qwenLong = protocol == ChatFileProtocol.qwenLong;
    if (qwenLong &&
        previous is List &&
        previous.any((part) => part is! Map || part['type'] != 'text')) {
      throw const FormatException('Qwen-Long 的文档对话不能同时输入图片或音频');
    }
    final parts = <dynamic>[
      if (previous is List) ...previous,
      if (previous is String && previous.isNotEmpty)
        {'type': 'text', 'text': previous},
    ];
    for (final file in files) {
      try {
        final part = extract == null
            ? await attach(file, upload: upload)
            : await attachWithTextFallback(
                file,
                upload: upload,
                extract: extract,
              );
        if (qwenLong && _rawParts.containsKey(part)) {
          _qwenUser = message;
          _qwenFiles.add(file);
        } else {
          parts.add(part);
        }
      } on FormatException catch (error) {
        throw FormatException('${file.label}：${error.message}');
      } on FileSystemException {
        throw FormatException('${file.label}：无法读取原文件');
      }
    }
    message['content'] = userContent(parts);
  }

  /// Qwen-Long references uploaded documents in the leading system messages.
  void addQwenReferences(List<Map<String, dynamic>> messages) {
    if (protocol != ChatFileProtocol.qwenLong || _references.isEmpty) return;
    final text = _references.map((id) => 'fileid://$id').join(',');
    if (messages.isEmpty || messages.first['role'] != 'system') {
      messages.insert(0, {'role': 'system', 'content': '请根据用户问题与所附文件回答。'});
    }
    final reference = <String, dynamic>{'role': 'system', 'content': text};
    _qwenReferenceMessage = reference;
    messages.insert(1, reference);
  }

  /// Uploads without an expiration need explicit cleanup after the chat finishes.
  Future<void> close({http.Client Function()? createClient}) async {
    if (protocol != ChatFileProtocol.qwenLong || _references.isEmpty) return;
    final references = List<String>.of(_references);
    _references.clear();
    final client = createClient?.call() ?? http.Client();
    try {
      await Future.wait(
        references.toSet().map((id) async {
          final base = _filesEndpoint;
          final request =
              http.Request('DELETE', base.replace(path: '${base.path}/$id'))
                ..followRedirects = false
                ..headers['Authorization'] = 'Bearer $apiKey';
          final response = await client.send(request);
          await response.stream.drain<void>();
        }),
      ).timeout(const Duration(seconds: 5));
    } on Exception {
      // Cleanup must not mask the result of the chat request.
    } finally {
      client.close();
    }
  }
}
