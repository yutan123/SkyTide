import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

class MediaPreprocessor {
  static const MethodChannel _channel = MethodChannel('skytide.native.channel');

  // 防止单个附件占满聊天上下文。
  static const int _maxDocumentBytes = 10 * 1024 * 1024;
  static const int _maxExtractedCharacters = 120000;
  static const int _maxOfficeXmlBytes = 8 * 1024 * 1024;

  static const Set<String> _textExtensions = {
    'txt',
    'md',
    'markdown',
    'json',
    'csv',
    'xml',
    'html',
    'htm',
    'yaml',
    'yml',
    'log',
    'ini',
  };
  static const Set<String> _officeExtensions = {'docx', 'xlsx', 'pptx'};

  Future<String> imageFallbackText(String path) async {
    final file = File(path);
    if (!await file.exists()) return '[图片文件不存在，无法读取内容]';

    final stat = await file.stat();
    final name = path.split(Platform.pathSeparator).last;
    try {
      final text = await _channel.invokeMethod<String>('recognizeText', {
        'path': path,
      });
      final normalized = text?.trim() ?? '';
      if (normalized.isNotEmpty) {
        return '[图片 OCR 文字（文件：$name，${stat.size} bytes）]\n$normalized';
      }
    } on PlatformException catch (_) {
      // 设备 OCR 不可用时仍向模型提供文件元数据。
    }
    return '[图片元数据：文件=$name，大小=${stat.size} bytes。未配置识图模型，且未识别到可用文字。]';
  }

  Future<String> documentText(String path) async {
    final file = File(path);
    final extension = path
        .split(Platform.pathSeparator)
        .last
        .split('.')
        .last
        .toLowerCase();
    try {
      if (!await file.exists()) throw const FormatException('文档文件不存在');
      if (await file.length() > _maxDocumentBytes) {
        throw const FormatException('文档超过 10 MiB 的本机提取上限');
      }
      final String text;
      if (_textExtensions.contains(extension)) {
        text = await file.readAsString();
      } else if (_officeExtensions.contains(extension)) {
        text = await _officeText(file, extension);
      } else if (extension == 'pdf') {
        text = await _pdfText(path);
      } else {
        throw const FormatException('此文件格式无法在本机提取文本');
      }
      final normalized = _normalizeText(text);
      if (normalized.isEmpty) throw const FormatException('未提取到可用正文');
      return normalized.length > _maxExtractedCharacters
          ? '${normalized.substring(0, _maxExtractedCharacters)}\n[正文已截断]'
          : normalized;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('本机正文提取失败');
    }
  }

  Future<String> _pdfText(String path) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'extractPdfText',
      {'path': path, 'maxPages': 3, 'maxChars': _maxExtractedCharacters},
    );
    if (result == null) throw StateError('PDF OCR 未返回结果');
    final error = result['error']?.toString().trim() ?? '';
    if (error.isNotEmpty) throw StateError(error);
    final text = result['text']?.toString().trim() ?? '';
    if (text.isEmpty) throw const FormatException('PDF 未识别到可用文字');
    final processed = result['pagesProcessed'];
    final total = result['pageCount'];
    final failures = result['failedPages'];
    return [
      if (processed is int && total is int && processed < total)
        '[PDF OCR 仅处理前 $processed/$total 页]',
      if (failures is int && failures > 0) '[其中 $failures 页 OCR 失败]',
      text,
      if (result['truncated'] == true) '[PDF OCR 正文已截断]',
    ].join('\n');
  }

  Future<String> _officeText(File file, String extension) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final entries = <ArchiveFile>[];

    for (final entry in archive.files) {
      final entryPath = entry.name;
      final wanted = switch (extension) {
        'docx' =>
          entryPath == 'word/document.xml' ||
              (entryPath.startsWith('word/') &&
                  entryPath.endsWith('.xml') &&
                  !entryPath.contains('/_rels/')),
        'xlsx' =>
          entryPath == 'xl/sharedStrings.xml' ||
              (entryPath.startsWith('xl/worksheets/') &&
                  entryPath.endsWith('.xml')),
        'pptx' =>
          entryPath.startsWith('ppt/slides/') && entryPath.endsWith('.xml'),
        _ => false,
      };
      if (wanted && entry.isFile) entries.add(entry);
    }

    entries.sort((a, b) => a.name.compareTo(b.name));
    final buffer = StringBuffer();
    var remainingBytes = _maxOfficeXmlBytes;
    for (final entry in entries) {
      if (entry.size < 0 ||
          entry.size > remainingBytes ||
          buffer.length >= _maxExtractedCharacters) {
        if (buffer.toString().trim().isEmpty) {
          throw const FormatException('文档正文超过本机解压上限');
        }
        buffer.writeln('[Office 文档仅提取部分正文]');
        break;
      }
      remainingBytes -= entry.size;
      final xml = utf8.decode(entry.content, allowMalformed: true);
      buffer.writeln(_xmlToText(xml));
    }
    return buffer.toString();
  }

  String _xmlToText(String xml) {
    // Office XML uses tags to separate text runs. Strip those tags here;
    // unknown XML entities are intentionally retained rather than risking
    // malformed content or false text conversion.
    return xml.replaceAll(RegExp(r'<[^>]+>'), ' ');
  }

  String _normalizeText(String value) => value
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  Future<Map<String, dynamic>> prepareVideo(String path) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'prepareVideo',
      {'path': path, 'intervalMs': 3000},
    );
    return result ?? {'error': '视频预处理未返回结果'};
  }
}
