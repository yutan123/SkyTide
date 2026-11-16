/// Telegram's double check represents successful sending, not a read receipt.
enum TelegramDeliveryState { sending, failed, sent }

TelegramDeliveryState telegramDeliveryState(Map<String, dynamic> message) {
  if (message['send_status'] == 'sending' ||
      message['is_retrying'] == true ||
      message['retry_status'] == 'retrying') {
    return TelegramDeliveryState.sending;
  }
  if (message['send_status'] == 'failed' ||
      message['retry_status'] == 'failed' ||
      message['error_log']?.toString().isNotEmpty == true) {
    return TelegramDeliveryState.failed;
  }
  // Historical, persisted messages predate send_status and are already sent.
  return TelegramDeliveryState.sent;
}

bool telegramStartsNewDay(int timestamp, int? previousTimestamp) {
  if (previousTimestamp == null) return true;
  final current = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final previous = DateTime.fromMillisecondsSinceEpoch(previousTimestamp);
  return current.year != previous.year ||
      current.month != previous.month ||
      current.day != previous.day;
}

String telegramMessageTime(int timestamp) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
  return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
