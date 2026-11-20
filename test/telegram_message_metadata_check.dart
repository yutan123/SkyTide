import 'package:skytide/telegram_message_metadata.dart';

void main() {
  var checks = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError(label);
    checks++;
  }

  final morning = DateTime(2026, 6, 1, 9, 5).millisecondsSinceEpoch;
  final evening = DateTime(2026, 6, 1, 23, 59).millisecondsSinceEpoch;
  final midnight = DateTime(2026, 6, 2).millisecondsSinceEpoch;
  check(telegramStartsNewDay(morning, null), 'First history item needs a date');
  check(
    !telegramStartsNewDay(evening, morning),
    'Long pauses on one day must not repeat the date',
  );
  check(
    telegramStartsNewDay(midnight, evening),
    'Local midnight needs a new date',
  );
  check(
    telegramStartsNewDay(
      DateTime(2026, 2, 1).millisecondsSinceEpoch,
      DateTime(2026, 1, 1).millisecondsSinceEpoch,
    ),
    'Same day number in another month needs a date',
  );
  check(
    telegramStartsNewDay(
      DateTime(2027, 1, 1).millisecondsSinceEpoch,
      DateTime(2026, 1, 1).millisecondsSinceEpoch,
    ),
    'Same month and day in another year needs a date',
  );
  check(
    telegramMessageTime(morning) == '09:05',
    'Message time must be local and zero padded',
  );
  check(
    telegramMessageTime(midnight) == '00:00',
    'Midnight must not render the full date',
  );
  check(
    telegramDeliveryState({'send_status': 'sending'}) ==
        TelegramDeliveryState.sending,
    'Pending messages must not show double checks',
  );
  check(
    telegramDeliveryState({'send_status': 'failed'}) ==
        TelegramDeliveryState.failed,
    'Failed sends must not show double checks',
  );
  check(
    telegramDeliveryState({'retry_status': 'failed'}) ==
        TelegramDeliveryState.failed,
    'Persisted retry failures must not show double checks',
  );
  check(
    telegramDeliveryState({'error_log': 'network error'}) ==
        TelegramDeliveryState.failed,
    'Error logs must not masquerade as successful delivery',
  );
  check(
    telegramDeliveryState({
          'is_retrying': true,
          'error_log': 'previous failure',
        }) ==
        TelegramDeliveryState.sending,
    'Retrying overrides the previous error until it finishes',
  );
  check(
    telegramDeliveryState({
          'retry_status': 'retrying',
          'send_status': 'failed',
        }) ==
        TelegramDeliveryState.sending,
    'Persisted retry-in-progress must show a clock',
  );
  check(
    telegramDeliveryState({'send_status': 'sent', 'error_log': ''}) ==
        TelegramDeliveryState.sent,
    'Successful sends show double checks',
  );
  check(
    telegramDeliveryState({}) == TelegramDeliveryState.sent,
    'Legacy persisted history has no delivery field',
  );
  print('Telegram date/time and delivery checks passed ($checks checks)');
}
