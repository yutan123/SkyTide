import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'model_credential_codec.dart';
import 'package:sqflite/sqflite.dart';

class ModelCredentials {
  static const storage = FlutterSecureStorage();
  static const prefix = ModelCredentialCodec.prefix;
  static const reference = ModelCredentialCodec.reference;
  static bool handles(String key) => ModelCredentialCodec.handles(key);
  static Future<String> protect(String value) => ModelCredentialCodec.protect(
    value,
    (key, secret) => storage.write(key: key, value: secret),
  );
  static Future<String> resolve(String value) =>
      ModelCredentialCodec.resolve(value, (key) => storage.read(key: key));
  static Future<String> protectKey(String key, String value) =>
      ModelCredentialCodec.protectKey(
        key,
        value,
        (id, secret) => storage.write(key: id, value: secret),
      );
  static Future<String> resolveKey(String key, String value) =>
      ModelCredentialCodec.resolveKey(
        key,
        value,
        (id) => storage.read(key: id),
      );

  // Run under the database write transaction; backups capture secrets under
  // the same database lock before releasing their snapshot.
  static Future<void> removeUnused(DatabaseExecutor db) async {
    final used = <String>{};
    for (final row in await db.query('kv_store')) {
      final key = row['key'] as String;
      if (handles(key)) {
        try {
          used.addAll(
            ModelCredentialCodec.references(key, row['value'] as String),
          );
        } on FormatException {
          // Keep secrets when a damaged configuration cannot be inspected.
          return;
        }
      }
    }
    for (final key in (await storage.readAll()).keys) {
      if (key.startsWith(prefix) && !used.contains(key)) {
        await storage.delete(key: key);
      }
    }
  }
}
