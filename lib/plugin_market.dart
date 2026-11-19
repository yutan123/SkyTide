import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'db.dart';
import 'plugin_archive.dart';
import 'plugin_operation.dart';

class MarketPlugin {
  final String id,
      name,
      author,
      description,
      repository,
      version,
      commit,
      changelog;
  final String? icon;
  MarketPlugin(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      author = json['author'] as String,
      description = json['description'] as String,
      repository = json['repository'] as String,
      version = json['version'] as String,
      commit = json['commit'] as String,
      icon = json['icon'] is String ? json['icon'] as String : null,
      changelog = json['changelog'] as String? ?? '' {
    if (!RegExp(
          r'^tidebot[a-z0-9_.-]{0,57}$',
          caseSensitive: false,
        ).hasMatch(id) ||
        name.isEmpty ||
        !RegExp(
          r'^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
        ).hasMatch(repository) ||
        !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(commit) ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const FormatException('市场插件信息无效');
    }
  }
  Uri get archiveUrl => Uri.parse('$repository/archive/$commit.zip');
  Uri? get iconUrl {
    final path = icon;
    if (path == null ||
        !RegExp(r'^[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*\.(?:png|jpe?g|webp)$',
          caseSensitive: false,
        ).hasMatch(path)) return null;
    final segments = path.split('/');
    if (segments.any((segment) => segment == '.' || segment == '..')) return null;
    return Uri.https('raw.githubusercontent.com',
        '${Uri.parse(repository).path}/$commit/$path');
  }
  bool newerThan(String installed) {
    final old = installed.split('.').map(int.tryParse).toList();
    final next = version.split('.').map(int.parse).toList();
    if (old.length != 3 || old.any((v) => v == null)) return false;
    for (var i = 0; i < 3; i++) {
      if (next[i] != old[i]) return next[i] > old[i]!;
    }
    return false;
  }
}

class PluginMarket extends ChangeNotifier {
  PluginMarket._();
  static final instance = PluginMarket._();
  static final indexUrl = Uri.parse(
    'https://raw.githubusercontent.com/yutan123/TideBot-plugins/main/market/index.json',
  );

  // Ordered from the direct source to public GitHub mirrors. A route is only
  // considered successful when it returns the expected HTTP status.
  static List<Uri> _routes(Uri uri) {
    final encoded = Uri.encodeFull(uri.toString());
    return [
      uri,
      Uri.parse('https://ghproxy.net/$encoded'),
      Uri.parse('https://gh-proxy.com/$encoded'),
      Uri.parse('https://ghfast.top/$encoded'),
    ];
  }

  static Future<HttpClientResponse> _getWithFallback(
    HttpClient client,
    Uri uri, {
    required Set<int> acceptedStatusCodes,
    Duration timeout = const Duration(seconds: 20),
    void Function(HttpClientRequest)? configure,
  }) async {
    Object? lastError;
    for (final route in _routes(uri)) {
      try {
        final request = await client.getUrl(route).timeout(timeout);
        configure?.call(request);
        final response = await request.close().timeout(timeout);
        if (acceptedStatusCodes.contains(response.statusCode)) return response;
        response.drain<void>();
        lastError = HttpException('HTTP ${response.statusCode}');
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const HttpException('没有可用的下载线路');
  }

  List<MarketPlugin> plugins = [];
  bool loading = false;
  String? error;
  List<Map<String, dynamic>> _revocations = [];
  Future<void>? _refresh;

  List<MarketPlugin> _parse(String text) {
    final root = jsonDecode(text) as Map<String, dynamic>;
    final list = (root['plugins'] as List)
        .map((v) => MarketPlugin(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (list.map((p) => p.id).toSet().length != list.length) {
      throw const FormatException('市场包含重复插件 ID');
    }
    _revocations = (root['revocations'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    return list;
  }

  Future<void> refresh() =>
      _refresh ??= _load().whenComplete(() => _refresh = null);
  Future<void> _load() async {
    loading = true;
    error = null;
    notifyListeners();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final db = DBManager();
      final cache = await db.getKV('plugin_market_index');
      if (plugins.isEmpty && cache != null) {
        try {
          plugins = _parse(cache);
          notifyListeners();
        } catch (_) {}
      }
      final etag = await db.getKV('plugin_market_etag');
      final response = await _getWithFallback(
        client,
        indexUrl,
        acceptedStatusCodes: {200, 304},
        configure: (request) {
          if (cache != null && etag != null) {
            request.headers.set('If-None-Match', etag);
          }
        },
      );
      if (response.statusCode == 304 && cache != null) return;
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024)
          throw const FormatException('市场索引过大');
      }
      final text = utf8.decode(bytes);
      final parsed = _parse(text);
      await db.setKV('plugin_market_index', text);
      await db.setKV(
        'plugin_market_etag',
        response.headers.value('etag') ?? '',
      );
      plugins = parsed;
    } catch (e) {
      error = e.toString();
    } finally {
      client.close(force: true);
      loading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> source(String id) async {
    final value = await DBManager().getKV('plugin_market_source_$id');
    if (value == null || value.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(value) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSource(MarketPlugin plugin) => DBManager().setKV(
    'plugin_market_source_${plugin.id}',
    jsonEncode({
      'repository': plugin.repository,
      'commit': plugin.commit,
      'version': plugin.version,
    }),
  );
  Future<void> clearSource(String id) =>
      DBManager().setKV('plugin_market_source_$id', '');

  Future<File> download(
    MarketPlugin plugin,
    Directory temporary,
    PluginOperation operation,
    void Function(int, int) progress,
  ) async {
    if (_revocations.any(
      (r) => r['id'] == plugin.id && r['commit'] == plugin.commit,
    )) {
      throw const FormatException('该版本已撤销');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final unlisten = operation.listen(() => client.close(force: true));
    try {
      final response = await _getWithFallback(
        client,
        plugin.archiveUrl,
        acceptedStatusCodes: {200},
        timeout: const Duration(seconds: 30),
      );
      if (response.contentLength > PluginArchive.maxCompressed)
        throw const FormatException('插件包超过大小限制');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        operation.check();
        bytes.addAll(chunk);
        if (bytes.length > PluginArchive.maxCompressed)
          throw const FormatException('插件包超过大小限制');
        progress(bytes.length, response.contentLength);
      }
      operation.check();
      final package = PluginArchive.decode(bytes, githubWrapper: true);
      if (package.manifest['id'] != plugin.id ||
          package.manifest['version'] != plugin.version) {
        throw const FormatException('下载插件的 ID 或版本与市场不一致');
      }
      final archive = Archive();
      for (final entry in package.files.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      final file = File('${temporary.path}/market.zip');
      await file.writeAsBytes(ZipEncoder().encode(archive), flush: true);
      operation.check();
      return file;
    } finally {
      unlisten();
      client.close(force: true);
    }
  }
}
