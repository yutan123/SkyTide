import 'db.dart';

/// Global switches; absent values preserve the enabled default.
class BuiltinGenerationSettings {
  static const dailyQuote = 'daily_quote_generation_enabled';
  static const worldBook = 'world_book_recording_enabled';
  static const diary = 'diary_generation_enabled';

  static Future<bool> enabled(String key) async =>
      await DBManager().getKV(key) != 'false';
}
