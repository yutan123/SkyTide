import 'dart:convert';
import 'dart:math';

class PluginDataPolicy {
  static String name(Object? value) {
    if (value is! String ||
        !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(value))
      throw const FormatException('集合名称无效');
    return value;
  }

  static String key(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 256 ||
        value.contains('\u0000'))
      throw const FormatException('记录 key 长度必须为 1 至 256');
    return value;
  }

  static String encode(Object? value) {
    final text = jsonEncode(value);
    if (utf8.encode(text).length > 128 * 1024)
      throw const FormatException('单条记录超过 128 KiB');
    return text;
  }

  static List<double> vector(Object? value) {
    if (value is! List ||
        value.isEmpty ||
        value.length > 2048 ||
        value.any((n) => n is! num || !n.isFinite))
      throw const FormatException('向量必须包含 1 至 2048 个有限数字');
    final result = value.map((n) => (n as num).toDouble()).toList();
    final norm = result.fold<double>(0, (v, n) => v + n * n);
    if (!norm.isFinite || norm <= 0) throw const FormatException('向量范数无效');
    final scale = sqrt(norm);
    return result.map((n) => n / scale).toList();
  }

  static double similarity(List<double> a, List<double> b) {
    if (a.length != b.length) throw const FormatException('向量维度不一致');
    var result = 0.0;
    for (var i = 0; i < a.length; i++) {
      result += a[i] * b[i];
    }
    return result.clamp(-1, 1);
  }
}
