import 'dart:convert';
import 'dart:io';
import 'package:tide_bot/backup_credential_cipher.dart';
import 'package:tide_bot/model_credential_codec.dart';
import 'package:tide_bot/transfer_archive.dart';

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

final sample = <String, String>{
  'model_key_demo': 'model-secret-demo',
  'model_key_search': 'search-secret-demo',
  'mcp_headers_demo': jsonEncode({'Authorization': 'Bearer mcp-secret-demo'}),
  'skill_headers_demo': jsonEncode({'X-Api-Key': 'skill-secret-demo'}),
};

Future<void> mustReject(Map<String, dynamic> value) async {
  var rejected = false;
  try {
    await BackupCredentialCipher.decrypt(jsonEncode(value));
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'Invalid or modified envelope must be rejected');
}

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == 'restore') {
    final restored = await BackupCredentialCipher.decrypt(
      await File(args[1]).readAsString(),
    );
    check(
      jsonEncode(restored) == jsonEncode(sample),
      'Another process must decrypt without original device state',
    );
    print('Portable restoration passed.');
    return;
  }
  final first = await BackupCredentialCipher.encrypt(sample);
  final second = await BackupCredentialCipher.encrypt(sample);
  check(first != second, 'Every export must use a fresh nonce');
  for (final secret in sample.values) {
    check(
      !first.contains(secret),
      'Envelope must not contain plaintext secrets',
    );
  }
  check(
    jsonEncode(await BackupCredentialCipher.decrypt(first)) ==
        jsonEncode(sample),
    'All credential types must round-trip',
  );
  check(
    jsonEncode(await BackupCredentialCipher.decrypt(jsonEncode(sample))) ==
        jsonEncode(sample),
    'Legacy plaintext credential maps must remain readable',
  );
  check(
    (await BackupCredentialCipher.decrypt(
      await BackupCredentialCipher.encrypt({}),
    )).isEmpty,
    'Empty credential backups must round-trip',
  );

  for (final field in ['nonce', 'ciphertext', 'tag']) {
    final envelope = Map<String, dynamic>.from(jsonDecode(first) as Map);
    final bytes = base64Decode(envelope[field] as String);
    bytes[0] ^= 1;
    envelope[field] = base64Encode(bytes);
    await mustReject(envelope);
  }
  for (final entry in {
    'version': 99,
    'keyId': 'unknown',
    'algorithm': 'none',
    'format': 'unknown',
    'nonce': '',
    'tag': '',
  }.entries) {
    final envelope = Map<String, dynamic>.from(jsonDecode(first) as Map);
    envelope[entry.key] = entry.value;
    await mustReject(envelope);
  }
  await mustReject({'model_key_demo': 123});

  final workspace = Directory.fromUri(
    Platform.script.resolve('../.dart_tool/'),
  );
  await workspace.create(recursive: true);
  final root = await workspace.createTemp('credential_backup_check_');
  try {
    final payload = File('${root.path}/tool_credentials.json');
    await payload.writeAsString(first);
    final zip = File('${root.path}/backup.zip');
    await writeTransferZip(zip.path, {'tool_credentials.json': payload.path});
    final zipBytes = await zip.readAsBytes();
    final zipText = latin1.decode(zipBytes);
    for (final secret in [
      'model-secret-demo',
      'search-secret-demo',
      'mcp-secret-demo',
      'skill-secret-demo',
    ]) {
      check(
        !zipText.contains(secret),
        'ZIP must not contain plaintext secrets',
      );
    }
    final imported = await Directory('${root.path}/another-device').create();
    await extractTransferZip(zip.path, imported.path);
    final path = '${imported.path}/tool_credentials.json';
    final otherDevice = await Process.run(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      'restore',
      path,
    ]);
    check(
      otherDevice.exitCode == 0,
      'Separate process restore: ${otherDevice.stderr}',
    );
    final restored = await BackupCredentialCipher.decrypt(
      await File(path).readAsString(),
    );
    final provider = jsonEncode([
      {'api_key': '${ModelCredentialCodec.reference}model_key_demo'},
    ]);
    final resolved = await ModelCredentialCodec.resolve(
      provider,
      (id) async => restored[id],
    );
    check(
      (jsonDecode(resolved) as List).first['api_key'] == 'model-secret-demo',
      'Restored provider reference must resolve',
    );
    check(
      await ModelCredentialCodec.resolveKey(
            'web_search_api_key',
            '${ModelCredentialCodec.reference}model_key_search',
            (id) async => restored[id],
          ) ==
          'search-secret-demo',
      'Restored search reference must resolve',
    );
  } finally {
    await root.delete(recursive: true);
  }
  print(
    'Encrypted ZIP, separate-process restore, legacy compatibility and corruption checks passed.',
  );
}
