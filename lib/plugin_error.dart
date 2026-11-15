import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'plugin_operation.dart';

/// Versioned error envelope transported through the existing string bridge.
String pluginHostError(Object error) {
  final code = error is PluginOperationCancelled
      ? 'CANCELLED'
      : error is TimeoutException
      ? 'TIMEOUT'
      : error is FormatException || error is TypeError || error is ArgumentError
      ? 'INVALID_ARGUMENT'
      : error is SocketException ||
            error is HttpException ||
            error is http.ClientException
      ? 'NETWORK'
      : error is StateError
      ? 'INVALID_STATE'
      : 'HOST_ERROR';
  final message = error.toString();
  return jsonEncode({
    'tideError': 1,
    'code': code,
    'message': message.substring(0, message.length.clamp(0, 2000)),
    'retryable': code == 'TIMEOUT' || code == 'NETWORK',
  });
}
