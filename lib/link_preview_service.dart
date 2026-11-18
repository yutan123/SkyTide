import 'douyin_detail.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'link_preview_models.dart';
import 'link_page_utils.dart';
import 'platform_media_parser.dart';

class LinkPreviewService {
  static final LinkPreviewService _instance = LinkPreviewService._();
  static LinkPreviewService get instance => _instance;
  LinkPreviewService._() : _client = http.Client();
  LinkPreviewService.withClient(this._client, {this.cacheDirectory});

  Future<Directory> Function()? cacheDirectory;

  final http.Client _client;
  final Map<String, LinkPreviewData> _cache = {};
  final Map<String, Future<LinkPreviewData>> _pending = {};
  final Map<String, Future<Uint8List?>> _pendingThumbnails = {};

  Future<Uint8List?> fetchThumbnail(LinkPreviewData preview) async {
    final uri = Uri.tryParse(preview.imageUrl ?? '');
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    final key = uri.toString();
    return _pendingThumbnails.putIfAbsent(
      key,
      () => _loadThumbnail(uri, preview.imageHeaders).whenComplete(() {
        _pendingThumbnails.remove(key);
      }),
    );
  }

  Future<Uint8List?> _loadThumbnail(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final file = await _cacheFile('thumbnails', uri.toString(), 'bin');
    if (file != null) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      } on FileSystemException {
        // Cache miss.
      }
    }

    const maxBytes = 512 * 1024;
    const timeout = Duration(seconds: 6);
    final abort = Completer<void>();
    final timer = Timer(timeout, abort.complete);
    Uint8List? bytes;
    try {
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      );
      request.headers.addAll(headers);
      final response = await _client.send(request);
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final isImage =
          contentType.startsWith('image/') &&
          !contentType.startsWith('image/svg+xml');
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (response.statusCode != 200 ||
            !isImage ||
            buffer.length + chunk.length > maxBytes) {
          return null;
        }
        buffer.add(chunk);
      }
      if (response.statusCode == 200 && isImage && buffer.isNotEmpty) {
        bytes = buffer.takeBytes();
      }
    } catch (_) {
      return null;
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
    if (bytes != null && file != null) {
      try {
        await _writeAtomically(file, bytes);
      } on FileSystemException {
        // The thumbnail can still be displayed without a disk copy.
      }
    }
    return bytes;
  }

  static final RegExp _urlRegex = RegExp(
    r'''https?://[^\s<>"'（）()]+''',
    caseSensitive: false,
  );
  static List<String> extractUrls(String text) => _urlRegex
      .allMatches(text)
      .map((m) => m[0]!.replaceFirst(RegExp(r'[，。！？、；：,.!?;:]+$'), ''))
      .where((url) => Uri.tryParse(url)?.host.isNotEmpty == true)
      .toSet()
      .toList();

  static LinkType identifyLinkType(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    bool matches(String domain) => host == domain || host.endsWith('.$domain');
    if (matches('douyin.com') || matches('iesdouyin.com'))
      return LinkType.douyin;
    if (matches('xiaohongshu.com') ||
        matches('xhslink.com') ||
        matches('xhslink.cn'))
      return LinkType.xiaohongshu;
    if (matches('bilibili.com') || matches('b23.tv')) return LinkType.bilibili;
    return LinkType.web;
  }

  Future<LinkPreviewData> fetchPreview(String url) {
    if (_cache.containsKey(url)) return Future.value(_cache[url]);
    return _pending.putIfAbsent(
      url,
      () => _loadPreview(url).whenComplete(() {
        _pending.remove(url);
      }),
    );
  }

  Future<LinkPreviewData> _loadPreview(String url) async {
    final file = await _cacheFile('metadata', url, 'json');
    if (file != null) {
      try {
        final stored =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final type = LinkType.values.byName(stored['type'] as String);
        // Platform media URLs may expire. Keep ordinary webpage metadata indefinitely.
        if (type == LinkType.web ||
            DateTime.now().difference(await file.lastModified()) <
                const Duration(hours: 12)) {
          final preview = LinkPreviewData(
            url: stored['url'] as String,
            title: stored['title'] as String,
            description: stored['description'] as String,
            imageUrl: stored['imageUrl'] as String?,
            videoUrl: stored['videoUrl'] as String?,
            imageHeaders: _headers(type),
            type: type,
          );
          _cache[url] = preview;
          return preview;
        }
      } catch (_) {
        // Missing or corrupt metadata is treated as a cache miss.
      }
    }

    final preview = await _fetch(url);
    if (!preview.isAvailable) return preview;
    if (preview.type != LinkType.web && preview.imageUrl == null)
      return preview;
    _cache[url] = preview;
    if (file != null) {
      try {
        await _writeAtomically(
          file,
          utf8.encode(
            jsonEncode({
              'url': preview.url,
              'title': preview.title,
              'description': preview.description,
              'imageUrl': preview.imageUrl,
              'videoUrl': preview.videoUrl,
              'type': preview.type.name,
            }),
          ),
        );
      } catch (_) {
        // A storage error should still allow the live preview to be shown.
      }
    }
    return preview;
  }

  Future<File?> _cacheFile(String group, String key, String extension) async {
    try {
      final root = await cacheDirectory?.call();
      if (root == null) return null;
      final digest = sha256.convert(utf8.encode(key));
      return File('${root.path}/link_previews/$group/$digest.$extension');
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAtomically(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final staging = await file.parent.createTemp('.write-');
    try {
      final pending = File('${staging.path}/entry');
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<LinkPreviewData?> _douyinPreview(String url) async {
    final id = videoId(url);
    if (id == null) return null;
    final item = await fetchDouyinDetail(_client, id);
    if (item == null) return null;
    final cover = douyinCoverUrl(item);
    final video = item['images'] is List && (item['images'] as List).isNotEmpty
        ? null
        : douyinVideoUrl(item);
    if (cover == null && video == null) return null;
    final author = item['author'];
    return LinkPreviewData(
      url:
          'https://www.douyin.com/${item['images'] is List && (item['images'] as List).isNotEmpty ? 'note' : 'video'}/$id',
      title: (item['desc'] ?? '抖音视频').toString(),
      description: author is Map ? (author['nickname'] ?? '').toString() : '',
      imageUrl: cover,
      videoUrl: video,
      imageHeaders: _headers(LinkType.douyin),
      type: LinkType.douyin,
    );
  }

  Future<LinkPreviewData> _fetch(String url) async {
    final type = identifyLinkType(url);
    var target = url;
    try {
      if (type == LinkType.douyin && videoId(url) != null) {
        final preview = await _douyinPreview(url);
        if (preview != null) {
          rememberPreview(url, preview);
          return preview;
        }
      }
      var page = await fetchLinkPage(_client, Uri.parse(url), _headers(type));
      target = page.uri.toString();
      // 抖音普通页通常只有 JS 壳；分享详情页提供视频结构化数据。
      if (type == LinkType.douyin) {
        final id = videoId(target);
        if (id != null) {
          if (videoId(url) == null) {
            final preview = await _douyinPreview(target);
            if (preview != null) {
              rememberPreview(url, preview);
              return preview;
            }
          }
          target = 'https://www.douyin.com/video/$id';
          try {
            final detail = await fetchLinkPage(
              _client,
              Uri.parse('https://www.iesdouyin.com/share/video/$id/'),
              _headers(type),
            );
            if (detail.response.statusCode == 200) page = detail;
          } catch (_) {
            /* 保留短链页面的元数据 */
          }
        }
      }
      if (page.response.statusCode != 200) return _fallback(target, type);
      final document = html_parser.parse(
        utf8.decode(page.response.bodyBytes, allowMalformed: true),
      );
      String? meta(String key) => document
          .querySelector('meta[property="$key"], meta[name="$key"]')
          ?.attributes['content']
          ?.trim();
      var title =
          [
            meta('og:title'),
            meta('twitter:title'),
            document.querySelector('title')?.text.trim(),
          ].whereType<String>().firstWhere(
            (value) => value.isNotEmpty,
            orElse: () => '',
          );
      var description = meta('og:description') ?? meta('description') ?? '';
      var image =
          meta('og:image') ??
          meta('twitter:image') ??
          meta('twitter:image:src') ??
          meta('image') ??
          document
              .querySelector('meta[itemprop="image"]')
              ?.attributes['content']
              ?.trim();
      // 很多中文网站没有 og:image，继续尝试 image_src、JSON-LD 和站点图标。
      image ??= document
          .querySelector('link[rel="image_src"]')
          ?.attributes['href']
          ?.trim();
      if (image == null || image.isEmpty) {
        for (final script in document.querySelectorAll(
          'script[type="application/ld+json"]',
        )) {
          try {
            final value = jsonDecode(script.text);
            final candidates = value is List ? value : [value];
            for (final candidate in candidates) {
              if (candidate is Map && candidate['image'] != null) {
                final candidateImage = candidate['image'];
                image = candidateImage is String
                    ? candidateImage
                    : candidateImage is List && candidateImage.isNotEmpty
                    ? candidateImage.first.toString()
                    : null;
                if (image != null && image.isNotEmpty) break;
              }
            }
          } catch (_) {}
          if (image != null && image.isNotEmpty) break;
        }
      }
      // A synthesized favicon cannot make an otherwise empty page a preview.
      final hasPageImage = image?.isNotEmpty == true;
      // 百度等页面可能主动不提供文章图片，使用站点图标保持卡片有视觉内容。
      if (type == LinkType.web) {
        if (image == null || image.isEmpty) {
          image =
              document.querySelector('link[rel*="icon"]')?.attributes['href'] ??
              page.uri.resolve('/favicon.ico').toString();
        }
      }
      String? video;
      final html = document.outerHtml;
      if (type == LinkType.douyin) {
        for (final state in platformPageStates(html)) {
          final item = findVideoItem(state);
          if (item == null) continue;
          title = item['desc']?.toString() ?? title;
          final author = item['author'];
          if (author is Map)
            description = author['nickname']?.toString() ?? description;
          image = douyinCoverUrl(item) ?? image;
          if (item['images'] is! List || (item['images'] as List).isEmpty) {
            video = douyinVideoUrl(item);
          }
          image ??= mediaUrl(item['images']);
          break;
        }
      } else if (type == LinkType.xiaohongshu) {
        final id = RegExp(
          r'/(?:explore|discovery/item)/([a-zA-Z0-9]+)',
        ).firstMatch(target)?.group(1);
        for (final state in platformPageStates(html)) {
          final note = findNoteData(state, id);
          if (note == null) continue;
          title =
              note['title']?.toString() ?? note['desc']?.toString() ?? title;
          description = note['desc']?.toString() ?? description;
          final images = noteImageUrls(note);
          if (images.isNotEmpty) image = images.first;
          break;
        }
      } else if (type == LinkType.bilibili) {
        final id = RegExp(
          r'BV[0-9A-Za-z]{10}',
          caseSensitive: false,
        ).firstMatch(target)?.group(0);
        if (id != null) {
          try {
            final response = await _client
                .get(
                  Uri.https('api.bilibili.com', '/x/web-interface/view', {
                    'bvid': id,
                  }),
                  headers: _headers(type),
                )
                .timeout(const Duration(seconds: 8));
            final data = jsonDecode(response.body);
            if (data['code'] == 0 && data['data'] is Map) {
              final aid = data['data']['aid'];
              if (aid is num && aid > 0) {
                final resolved = Uri.parse(target);
                target = resolved.replace(path: '/video/av$aid').toString();
              }
              title = data['data']['title'] as String? ?? title;
              image = data['data']['pic'] as String? ?? image;
              description = data['data']['desc'] as String? ?? description;
            }
          } catch (_) {
            /* 接口不可用时使用页面元数据 */
          }
        }
      }
      if (type == LinkType.douyin) video ??= pageVideoUrl(html);
      final imageUri = image == null || image.isEmpty
          ? null
          : page.uri.resolve(image);
      final validImage =
          imageUri != null &&
          ['http', 'https'].contains(imageUri.scheme) &&
          imageUri.host.isNotEmpty;
      if (title.trim().isEmpty &&
          description.trim().isEmpty &&
          (!validImage || (type == LinkType.web && !hasPageImage)) &&
          video == null) {
        return _fallback(target, type);
      }
      return LinkPreviewData(
        url: target,
        title: title.trim().isNotEmpty ? title.trim() : _fallbackTitle(type),
        description: description,
        imageUrl: validImage ? imageUri.toString() : null,
        imageHeaders: _headers(type),
        videoUrl: video,
        type: type,
      );
    } catch (_) {
      return _fallback(target, type);
    }
  }

  static String? videoId(String url) {
    final uri = Uri.tryParse(url);
    return RegExp(
          r'/(?:share/video|video|note|slides)/(\d+)',
        ).firstMatch(uri?.path ?? '')?.group(1) ??
        uri?.queryParameters['modal_id'] ??
        uri?.queryParameters['aweme_id'];
  }

  static String _fallbackTitle(LinkType type) => switch (type) {
    LinkType.douyin => '抖音视频',
    LinkType.xiaohongshu => '小红书笔记',
    LinkType.bilibili => '哔哩哔哩视频',
    _ => '网页链接',
  };
  LinkPreviewData _fallback(String url, LinkType type) => LinkPreviewData(
    url: url,
    title: _fallbackTitle(type),
    isAvailable: false,
    type: type,
  );
  static Map<String, String> _headers(LinkType type) => {
    'User-Agent': type == LinkType.douyin
        ? douyinShareUserAgent
        : 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    if (type == LinkType.douyin) 'Referer': 'https://www.douyin.com/',
    if (type == LinkType.xiaohongshu) 'Referer': 'https://www.xiaohongshu.com/',
    if (type == LinkType.bilibili) 'Referer': 'https://www.bilibili.com/',
  };
  // Media resolution already fetched the platform page; reuse its actual cover.
  void rememberPreview(String originalUrl, LinkPreviewData preview) {
    if (preview.isAvailable && preview.imageUrl?.isNotEmpty == true)
      _cache[originalUrl] = preview;
  }

  void clearCache() => _cache.clear();
  void removeCachedUrl(String url) => _cache.remove(url);
}
