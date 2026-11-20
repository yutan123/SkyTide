import 'dart:convert';
import 'package:cryptography/cryptography.dart';

/// Portable credential protection, not protection against app reverse engineering.
/// Keys in this versioned keyring must remain available for old backups.
class BackupCredentialCipher {
  static const _format = 'skytide.credentials';
  static const _legacyFormat = 'tidebot.credentials';
  static const _keyId = 'backup-v1';
  static const _keys = <String, List<int>>{
    'backup-v1': [
      0x9a,
      0x47,
      0x1d,
      0x65,
      0xc3,
      0xe8,
      0x2f,
      0x04,
      0x76,
      0xbb,
      0xa2,
      0x50,
      0x19,
      0xdf,
      0x83,
      0x6c,
      0x35,
      0xf1,
      0x08,
      0xad,
      0xe6,
      0x92,
      0x7b,
      0x43,
      0xd0,
      0x5e,
      0xca,
      0x21,
      0x8f,
      0x64,
      0xb7,
      0x0d,
    ],
  };
  static final _cipher = AesGcm.with256bits();
  static List<int> _aad(String keyId, [String format = _format]) =>
      utf8.encode('$format:1:$keyId:AES-256-GCM');

  static Future<String> encrypt(Map<String, String> credentials) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(credentials)),
      secretKey: SecretKey(_keys[_keyId]!),
      nonce: _cipher.newNonce(),
      aad: _aad(_keyId),
    );
    return jsonEncode({
      'format': _format,
      'version': 1,
      'keyId': _keyId,
      'algorithm': 'AES-256-GCM',
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
  }

  /// Legacy credential maps remain readable; a malformed encrypted envelope
  /// never falls back to plaintext. No device storage or platform APIs needed.
  static Future<Map<String, String>> decrypt(
    String payload, {
    bool allowLegacyPlaintext = true,
  }) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) throw const FormatException();
      if (!decoded.containsKey('format')) {
        if (!allowLegacyPlaintext) throw const FormatException();
        return _credentialMap(decoded);
      }
      final keyId = decoded['keyId'];
      final format = decoded['format'];
      if ((format != _format && format != _legacyFormat) ||
          decoded['version'] != 1 ||
          decoded['algorithm'] != 'AES-256-GCM' ||
          keyId is! String ||
          !_keys.containsKey(keyId)) {
        throw const FormatException('不支持的备份凭据加密版本，请更新 SkyTide');
      }
      List<int> bytes(String field) {
        final value = decoded[field];
        if (value is! String) throw const FormatException();
        return base64Decode(value);
      }

      final nonce = bytes('nonce');
      final tag = bytes('tag');
      if (nonce.length != 12 || tag.length != 16) throw const FormatException();
      final plaintext = await _cipher.decrypt(
        SecretBox(bytes('ciphertext'), nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(_keys[keyId]!),
        aad: _aad(keyId, format as String),
      );
      return _credentialMap(jsonDecode(utf8.decode(plaintext)));
    } on SecretBoxAuthenticationError {
      throw const FormatException('备份凭据校验失败，文件可能已损坏');
    } on FormatException catch (error) {
      if (error.message.startsWith('不支持的备份') ||
          error.message.startsWith('备份凭据'))
        rethrow;
      throw const FormatException('备份凭据格式无效');
    }
  }

  static Map<String, String> _credentialMap(dynamic value) {
    if (value is! Map ||
        value.entries.any(
          (entry) => entry.key is! String || entry.value is! String,
        )) {
      throw const FormatException('备份凭据格式无效');
    }
    return Map<String, String>.from(value);
  }
}
