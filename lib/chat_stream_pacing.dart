import 'package:flutter/material.dart';

/// Display timing belongs to the chat client, independently of SSE chunk sizes.
Duration chatStreamInterval(int speed) => Duration(
  milliseconds: (270 - (speed.clamp(1, 100) - 1) * 202 / 99).round(),
);

/// Consume one visible character without splitting emoji or combining marks.
(String, String) takeChatStreamCharacter(String pending) {
  if (pending.isEmpty) return ('', '');
  final first = pending.characters.first;
  return (first, pending.substring(first.length));
}

/// Reveal a parsed segment at the user's pace, independently of provider chunks.
Stream<String> chatStreamText(
  String text,
  int speed, {
  String prefix = '',
}) async* {
  final interval = chatStreamInterval(speed);
  final visible = StringBuffer(prefix);
  for (final character in text.substring(prefix.length).characters) {
    await Future<void>.delayed(interval);
    visible.write(character);
    yield visible.toString();
  }
}

/// Start after 20 visible characters have accumulated, then drain at one per tick.
class ChatStreamBuffer {
  String _pending = '';
  bool _started = false;
  String visible = '';

  void add(String delta) => _pending += delta;

  bool tick() {
    if (!_started && _pending.characters.length <= 20) return false;
    if (_pending.isEmpty) return false;
    _started = true;
    final (character, remainder) = takeChatStreamCharacter(_pending);
    _pending = remainder;
    visible += character;
    return true;
  }
}
