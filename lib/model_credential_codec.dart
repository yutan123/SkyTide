import 'dart:convert';
import 'dart:math';

/// Keeps provider credentials out of database configuration JSON.
class ModelCredentialCodec {
  static const prefix = 'model_key_';
  static const reference = '__tide_model_secret__:';

  static bool handles(String key) =>
      key == 'web_search_api_key' ||
      key == 'provider_list' ||
      key == 'stt_provider_list' ||
      key == 'tts_provider_list' ||
      key.startsWith('providers_');

  static String configuration(String key, String value) =>
      key == 'web_search_api_key' ? jsonEncode({'api_key': value}) : value;

  static Future<String> protectKey(
    String key,
    String value,
    Future<void> Function(String, String) write,
  ) async {
    final result = await protect(configuration(key, value), write);
    return key == 'web_search_api_key'
        ? (jsonDecode(result) as Map)['api_key'] as String
        : result;
  }

  static Future<String> resolveKey(
    String key,
    String value,
    Future<String?> Function(String) read,
  ) async {
    final result = await resolve(configuration(key, value), read);
    return key == 'web_search_api_key'
        ? (jsonDecode(result) as Map)['api_key'] as String
        : result;
  }

  static Set<String> references(String key, String value) {
    final result = <String>{};
    void visit(dynamic node) {
      if (node is String && node.startsWith('$reference$prefix')) {
        result.add(node.substring(reference.length));
      } else if (node is List) {
        node.forEach(visit);
      } else if (node is Map) {
        node.values.forEach(visit);
      }
    }

    visit(jsonDecode(configuration(key, value)));
    return result;
  }

  static Future<String> protect(
    String value,
    Future<void> Function(String, String) write,
  ) async {
    final decoded = jsonDecode(value);
    Future<dynamic> visit(dynamic node) async {
      if (node is List) return Future.wait(node.map(visit));
      if (node is Map) {
        final result = <String, dynamic>{};
        for (final entry in node.entries) {
          final field = entry.key.toString();
          final secret = entry.value;
          if ((field == 'key' || field == 'api_key' || field == 'apiKey') &&
              secret is String &&
              secret.isNotEmpty &&
              !secret.startsWith(reference)) {
            final random = Random.secure();
            final id =
                '$prefix${base64UrlEncode(List.generate(24, (_) => random.nextInt(256)))}';
            await write(id, secret);
            result[field] = '$reference$id';
          } else {
            result[field] = await visit(secret);
          }
        }
        return result;
      }
      return node;
    }

    return jsonEncode(await visit(decoded));
  }

  static Future<String> resolve(
    String value,
    Future<String?> Function(String) read,
  ) async {
    Future<dynamic> visit(dynamic node) async {
      if (node is String && node.startsWith('$reference$prefix')) {
        final secret = await read(node.substring(reference.length));
        if (secret == null) throw StateError('模型密钥缺失，请重新填写或恢复完整备份');
        return secret;
      }
      if (node is List) return Future.wait(node.map(visit));
      if (node is Map) {
        final result = <String, dynamic>{};
        for (final entry in node.entries) {
          result[entry.key.toString()] = await visit(entry.value);
        }
        return result;
      }
      return node;
    }

    return jsonEncode(await visit(jsonDecode(value)));
  }
}
