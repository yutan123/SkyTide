/// Fixed cadence scheduling skips missed slots instead of replaying a backlog.
class PluginTaskTiming {
  static int interval(Object? value) {
    if (value == null || value == 0) return 0;
    if (value is! int || value < 60000 || value > 365 * 86400000) {
      throw const FormatException(
        'intervalMs 必须为 60000 至 31536000000 的整数，0 表示单次任务',
      );
    }
    return value;
  }

  static int next(int due, int interval, int now) =>
      due + (((now - due) ~/ interval).clamp(0, 1 << 52) + 1) * interval;
}
