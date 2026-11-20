import 'dart:io';
import 'package:skytide/plugin_archive.dart';

void main() {
  final bytes = File('assets/plugins/hello.tideplugin').readAsBytesSync();
  final archive = PluginArchive.decode(bytes);
  print('id: ${archive.manifest["id"]}');
  print('version: ${archive.manifest["version"]}');
  print(
    'tools: ${(archive.manifest["tools"] as List).map((t) => t["name"]).toList()}',
  );
  print('files: ${archive.files.keys.toList()}');
  print('OK');
}