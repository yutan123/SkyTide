import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PluginDeviceAccess {
  static const _storage = FlutterSecureStorage();
  static const labels = <String, String>{
    'overlay': '悬浮窗',
    'location': '位置',
    'microphone': '麦克风',
    'photos': '图片',
    'videos': '视频',
    'motion': '设备动作与方向',
  };
  static const channel = MethodChannel('skytide.plugin.device');

  static Set<String> declared(Map<String, dynamic> manifest) {
    final values = manifest['systemPermissions'];
    return {
      if (values is List)
        for (final key in labels.keys)
          if (values.contains(key)) key,
    };
  }

  static String _key(String id) => 'plugin_device_permissions_$id';
  static Future<Set<String>> granted(String id) async =>
      (await _storage.read(key: _key(id)) ?? '')
          .split(',')
          .where(labels.containsKey)
          .toSet();

  static Future<void> save(String id, Set<String> grants) => grants.isEmpty
      ? _storage.delete(key: _key(id))
      : _storage.write(key: _key(id), value: grants.join(','));

  static Future<void> requireAccess(
    String id,
    Map<String, dynamic> manifest,
    String key,
  ) async {
    if (!Platform.isAndroid ||
        !declared(manifest).contains(key) ||
        !(await granted(id)).contains(key) ||
        !await available(key)) {
      throw StateError('未授权：${labels[key]}');
    }
  }

  static Permission? _runtime(String key) => switch (key) {
    'overlay' => Permission.systemAlertWindow,
    'location' => Permission.locationWhenInUse,
    'microphone' => Permission.microphone,
    _ => null,
  };

  static Future<bool> available(String key) async {
    if (!Platform.isAndroid) return false;
    final permission = _runtime(key);
    return permission == null || (await permission.status).isGranted;
  }

  static Future<bool> authorize(String key) async {
    if (!Platform.isAndroid) return false;
    final permission = _runtime(key);
    return permission == null ||
        (await permission.status).isGranted ||
        (await permission.request()).isGranted;
  }

  static Future<void> close(String id) => revoke(id, const {});

  static Future<void> revoke(String id, Set<String> retained) async {
    if (!Platform.isAndroid) return;
    try {
      await channel.invokeMethod<void>('revoke', {
        'id': id,
        'overlay': !retained.contains('overlay'),
        'microphone': !retained.contains('microphone'),
      });
    } on MissingPluginException {
      // Background engines do not own UI windows.
    }
  }
}
