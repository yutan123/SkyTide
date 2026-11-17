import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

/// Small host primitives; no additional runtime or native library.
class PluginCrypto {
  static List<int> bytes(Object? value, [int max = 256 * 1024]) {
    if (value is! String || value.length > max * 2)
      throw const FormatException('base64 数据无效或过长');
    final result = base64Decode(value);
    if (result.length > max) throw const FormatException('数据超过大小限制');
    return result;
  }

  static Future<dynamic> call(String method, Map args) async {
    if (method == 'auth.createPkce') {
      final verifier = base64UrlEncode(_random(32)).replaceAll('=', '');
      return {
        'verifier': verifier,
        'challenge': base64UrlEncode(
          hashes.sha256.convert(ascii.encode(verifier)).bytes,
        ).replaceAll('=', ''),
        'method': 'S256',
        'state': base64UrlEncode(_random(24)).replaceAll('=', ''),
      };
    }
    if (method == 'crypto.random') {
      final length = args['length'] ?? 32;
      if (length is! int || length < 1 || length > 4096)
        throw const FormatException('length 必须为 1–4096');
      return base64Encode(_random(length));
    }
    if (method == 'crypto.encode') {
      final text = args['text'];
      if (text is! String || utf8.encode(text).length > 256 * 1024)
        throw const FormatException('text 过长或无效');
      return base64Encode(utf8.encode(text));
    }
    if (method == 'crypto.decode')
      return utf8.decode(
        bytes(args['base64']),
        allowMalformed: args['allowMalformed'] == true,
      );
    if (method == 'crypto.digest' || method == 'crypto.hmac') {
      final algorithm = switch (args['algorithm'] ?? 'sha256') {
        'sha256' => hashes.sha256,
        'sha512' => hashes.sha512,
        'sha1' => hashes.sha1,
        'md5' => hashes.md5,
        _ => throw const FormatException('不支持的摘要算法'),
      };
      final data = bytes(args['base64']);
      final digest = method == 'crypto.hmac'
          ? hashes.Hmac(algorithm, bytes(args['key'], 4096)).convert(data)
          : algorithm.convert(data);
      return {'hex': digest.toString(), 'base64': base64Encode(digest.bytes)};
    }
    final cipher = AesGcm.with256bits();
    if (method == 'crypto.encrypt' || method == 'crypto.decrypt') {
      final key = bytes(args['key'], 32);
      if (key.length != 32)
        throw const FormatException('AES-GCM key 必须为 32 字节');
      final aad = args['aad'] == null ? <int>[] : bytes(args['aad']);
      if (method == 'crypto.encrypt') {
        final box = await cipher.encrypt(
          bytes(args['base64']),
          secretKey: SecretKey(key),
          aad: aad,
        );
        return {
          'base64': base64Encode(box.cipherText),
          'nonce': base64Encode(box.nonce),
          'mac': base64Encode(box.mac.bytes),
        };
      }
      final nonce = bytes(args['nonce'], 12), mac = bytes(args['mac'], 16);
      if (nonce.length != 12 || mac.length != 16)
        throw const FormatException('AES-GCM nonce/mac 无效');
      final clear = await cipher.decrypt(
        SecretBox(bytes(args['base64']), nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
        aad: aad,
      );
      return base64Encode(clear);
    }
    throw StateError('未知加密 API');
  }

  static List<int> _random(int length) {
    final random = Random.secure();
    return List.generate(length, (_) => random.nextInt(256));
  }
}
