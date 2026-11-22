import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ChatFileUnsupported extends FormatException {
  const ChatFileUnsupported(super.message);
}

class ChatFileEndpointMissing extends ChatFileUnsupported {
  const ChatFileEndpointMissing() : super('原文件接口不可用');
}

bool isFileCapabilityErrorBody(String body) {
  final decoded = _decode(body);
  final error = _responseError(decoded);
  if (error != null) return isFileCapabilityError(error);
  if (decoded is! Map) return isFileCapabilityError(body);
  final details = decoded['detail'];
  if (details is! List) return isFileCapabilityError(details ?? decoded);
  return details.whereType<Map>().any((item) {
    final input = item['input'];
    return isFileCapabilityError({
      'message': item['msg'],
      'param': item['loc'],
      'code': item['type'],
      if (const {'file', 'input_file', 'document'}.contains(input))
        'details': input,
    });
  });
}

bool isMissingFileEndpoint(int status, String body) {
  if (status != 404 && status != 405 && status != 501) return false;
  final decoded = _decode(body);
  final error =
      _responseError(decoded) ?? (decoded is Map ? decoded['detail'] : null);
  final text = (error ?? body).toString().trim().toLowerCase();
  if (RegExp(
    r'model|permission|auth|access denied|file not found|file_not_found',
  ).hasMatch(text))
    return false;
  return status != 404 ||
      RegExp(
        r'(?:route|endpoint|path).{0,100}(?:not found|not_found|does not exist|not supported)|(?:unknown|invalid) (?:route|endpoint|url)|cannot post(?: |$)|^(?:404\s*(?:[:-]\s*)?(?:page\s+)?)?not found$',
      ).hasMatch(text);
}

bool isFileCapabilityError(Object? error) {
  if (error == null) return false;
  if (error is Map) {
    final code =
        '${error['code'] ?? ''} ${error['type'] ?? ''} ${error['status'] ?? ''}'
            .toLowerCase();
    final transportCode = code.replaceAll(RegExp(r'\bextra_forbidden\b'), '');
    if (RegExp(
      r'auth|permission|forbidden|rate.limit|quota|resource_exhausted|timeout|not_found',
    ).hasMatch(transportCode))
      return false;
  }
  final text =
      (error is Map
              ? [
                  error['code'],
                  error['type'],
                  error['message'],
                  error['param'],
                  error['details'],
                ].where((value) => value != null).join(' ')
              : error.toString())
          .toLowerCase();
  if (RegExp(
    r'access denied|api key|insufficient permissions?|unauthori[sz]ed|permission denied|rate limit|quota|timed out|time.?out|超时|无权|未授权|权限|限流|额度',
  ).hasMatch(text))
    return false;
  if (RegExp(
    r'\b(?:unsupported_(?:file(?:_type|_format)?|document|mime_type)|file_(?:type_|format_)?not_supported)\b',
  ).hasMatch(text))
    return true;
  final file = RegExp(
    r'\b(?:input_files?|file_?(?:id|data|type|format)|document|pdf|files?|mimetype|mime_type)\b|文件|文档',
  );
  final rejected = RegExp(
    r"not support|not currently support|doesn['’]t support|unsupported|not (?:accepted|implemented)|unknown (?:field|type|parameter|value|name)|literal_error|extra_forbidden|input should be|unrecognized|unexpected (?:field|type|value|parameter)|invalid (?:enum )?value|only supports?|only accepts?|不支持|未支持|仅支持",
  );
  return file.hasMatch(text) && rejected.hasMatch(text);
}

/// Checks only the response prelude, before any model output reaches the caller.
/// The owner of [inner] still controls its lifetime and cancellation.
class ChatFileCapabilityClient extends http.BaseClient {
  ChatFileCapabilityClient(
    this.inner, {
    this.inspectFiles = true,
    this.allowMissingEndpoint = false,
  });

  final http.Client inner;
  final bool inspectFiles;
  final bool allowMissingEndpoint;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    final status = response.statusCode;
    final missing =
        allowMissingEndpoint && const {404, 405, 501}.contains(status);
    if (!missing &&
        (!inspectFiles || !const {200, 400, 415, 422}.contains(status)))
      return response;
    final type = response.headers['content-type'] ?? '';
    final sse = status == 200 && type.contains('text/event-stream');
    if (status == 200 && !sse && !type.contains('json')) return response;
    final iterator = StreamIterator(response.stream);
    final chunks = <List<int>>[];
    var length = 0;
    var pending = <int>[];
    var errorEvent = false;
    try {
      while (length < 32768 && await iterator.moveNext()) {
        final bytes = iterator.current;
        chunks.add(bytes);
        length += bytes.length;
        if (!sse) continue;
        pending.addAll(bytes.take(32768 - pending.length));
        var start = 0;
        var done = false;
        for (var i = 0; i < pending.length; i++) {
          if (pending[i] != 10) continue;
          final line = utf8
              .decode(pending.sublist(start, i), allowMalformed: true)
              .trim();
          start = i + 1;
          if (line.isEmpty) errorEvent = false;
          if (line.startsWith('event:'))
            errorEvent = line.substring(6).trim() == 'error';
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          final frame = _decode(data);
          if (isFileCapabilityError(
            _responseError(frame) ?? (errorEvent ? frame ?? data : null),
          )) {
            throw const ChatFileUnsupported('模型不支持原文件输入');
          }
          if (!_streamMetadata(frame)) {
            done = true;
            break;
          }
        }
        if (done) break;
        pending = pending.sublist(start);
      }
      if (!sse) {
        final body = utf8.decode(
          chunks.expand((c) => c).take(32768).toList(),
          allowMalformed: true,
        );
        if (missing && isMissingFileEndpoint(status, body)) {
          throw const ChatFileEndpointMissing();
        }
        if (inspectFiles &&
            (status == 200
                ? isFileCapabilityError(_responseError(_decode(body)))
                : const {400, 415, 422}.contains(status) &&
                      isFileCapabilityErrorBody(body))) {
          throw const ChatFileUnsupported('模型不支持原文件输入');
        }
      }
    } catch (_) {
      await iterator.cancel();
      rethrow;
    }
    Stream<List<int>> replay() async* {
      try {
        yield* Stream.fromIterable(chunks);
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
      } finally {
        await iterator.cancel();
      }
    }

    return http.StreamedResponse(
      replay(),
      status,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

Object? _responseError(Object? body) {
  if (body is! Map) return null;
  final response = body['response'];
  return body['error'] ??
      (response is Map ? response['error'] : null) ??
      (body['type'] == 'error' ? body : null);
}

bool _streamMetadata(Object? frame) {
  if (frame is! Map) return false;
  if (const {
    'response.created',
    'response.in_progress',
    'message_start',
    'ping',
  }.contains(frame['type']))
    return true;
  final choices = frame['choices'];
  if (choices is! List) return false;
  return choices.every((choice) {
    if (choice is! Map || choice['finish_reason'] != null) return false;
    final delta = choice['delta'];
    return delta is Map &&
        delta.entries.every(
          (entry) =>
              entry.key == 'role' || entry.value == null || entry.value == '',
        );
  });
}
