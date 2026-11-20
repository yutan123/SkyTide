import 'dart:convert';
import 'package:skytide/model_credential_codec.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final store = <String, String>{};
  Future<void> write(String key, String value) async {
    store[key] = value;
  }

  Future<String?> read(String key) async => store[key];
  final original = jsonEncode([
    {
      'id': 'one',
      'name': 'chat',
      'url': 'https://example.com',
      'key': 'secret-one',
    },
    {'id': 'two', 'api_key': 'secret-two', 'key': '', 'model': 'speech'},
  ]);
  final protected = await ModelCredentialCodec.protect(original, write);
  check(
    !protected.contains('secret-one') && !protected.contains('secret-two'),
    'Database JSON must not contain plaintext credentials',
  );
  check(
    await ModelCredentialCodec.resolve(protected, read) == original,
    'Saving and loading must preserve all fields',
  );
  check(
    await ModelCredentialCodec.protect(protected, write) == protected,
    'Repeated startup migration must preserve existing references',
  );
  check(store.length == 2, 'Migration must not duplicate existing secrets');

  // Simulate exporting the secret payload and importing it on another device.
  final exported = jsonEncode(store);
  final imported = Map<String, String>.from(jsonDecode(exported) as Map);
  check(
    await ModelCredentialCodec.resolve(
          protected,
          (key) async => imported[key],
        ) ==
        original,
    'Restoring on another device must recover the same provider credentials',
  );

  var missingFailed = false;
  try {
    await ModelCredentialCodec.resolve(protected, (_) async => null);
  } on StateError {
    missingFailed = true;
  }
  check(
    missingFailed,
    'A missing credential must not be sent as a reference token',
  );

  var writeFailed = false;
  try {
    await ModelCredentialCodec.protect(
      original,
      (_, _) async => throw StateError('unavailable'),
    );
  } on StateError {
    writeFailed = true;
  }
  check(
    writeFailed,
    'Failed secure writes must prevent replacing the database config',
  );

  for (final key in [
    'provider_list',
    'stt_provider_list',
    'tts_provider_list',
    'providers_chat',
  ]) {
    check(
      ModelCredentialCodec.handles(key),
      'Missing provider configuration: $key',
    );
  }
  print('Model credential migration and backup round-trip checks passed.');
}
