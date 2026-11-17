import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'qq_theme_widgets.dart';
import 'theme.dart';
import 'wechat_theme_widgets.dart';

/// Compact voice controls. The chat row owns avatars and Telegram's outer bubble.
class MessagingVoiceMessage extends StatelessWidget {
  const MessagingVoiceMessage({
    super.key,
    required this.isUser,
    required this.duration,
    required this.position,
    required this.playing,
    required this.onToggle,
    required this.onSeek,
  });

  final bool isUser;
  final Duration duration;
  final Duration position;
  final bool playing;
  final VoidCallback onToggle;
  final ValueChanged<Duration>? onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final seconds = (duration.inMilliseconds / 1000).ceil();
    final known = seconds > 0;
    final label = known ? '$seconds″' : '语音';
    final foreground = theme.isWechat
        ? (isUser || !theme.isDark ? const Color(0xFF111111) : theme.textStrong)
        : theme.isQq && isUser
        ? Colors.white
        : theme.textStrong;
    final width = theme.isTelegram
        ? 216.0
        : theme.isQq
        ? (112.0 + seconds.clamp(0, 30) * 4).clamp(112.0, 192.0)
        : (74.0 + seconds.clamp(0, 60) * 3).clamp(80.0, 200.0);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: constraints.constrainWidth(width),
        child: theme.isTelegram
            ? _telegram(context)
            : Semantics(
                button: true,
                label:
                    '${playing ? '暂停' : '播放'}语音${known ? '，$seconds 秒' : ''}',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggle,
                  child: theme.isQq
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isUser ? qqBlue : theme.surface,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Row(
                            children: [
                              _playButton(foreground, size: 26, subtle: true),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _VoiceBars(
                                  color: foreground,
                                  progress: _progress,
                                  playing: playing,
                                  compact: true,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                label,
                                style: TextStyle(
                                  color: foreground,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        )
                      : WechatBubble(
                          isUser: isUser,
                          child: Row(
                            mainAxisAlignment: isUser
                                ? MainAxisAlignment.end
                                : MainAxisAlignment.start,
                            children: [
                              if (isUser) ...[
                                Flexible(
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 7),
                              ],
                              WechatVoiceIcon(
                                isUser: isUser,
                                color: foreground,
                                playing: playing,
                              ),
                              if (!isUser) ...[
                                const SizedBox(width: 7),
                                Flexible(
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
              ),
      ),
    );
  }

  double get _progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  Widget _playButton(
    Color color, {
    required double size,
    bool subtle = false,
  }) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: subtle ? color.withValues(alpha: .16) : color,
    ),
    child: Icon(
      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      size: size * .65,
      color: subtle ? color : Colors.white,
    ),
  );

  Widget _telegram(BuildContext context) {
    final theme = TideTheme.of(context);
    final accent = theme.isDark
        ? const Color(0xFF71C991)
        : const Color(0xFF49BD83);
    final muted = theme.isDark
        ? const Color(0xFFA1BDAC)
        : const Color(0xFF82A38F);
    final elapsed = !isUser || playing || position > Duration.zero
        ? position
        : duration;
    final seconds = elapsed.inSeconds;
    final time = duration > Duration.zero
        ? '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
        : '00:00';
    return Row(
      children: [
        Semantics(
          button: true,
          label: playing ? '暂停语音' : '播放语音',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: _playButton(accent, size: 44),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 27,
                child: isUser
                    ? LayoutBuilder(
                        builder: (_, constraints) => Semantics(
                          label: '语音播放进度',
                          value: '${(_progress * 100).round()}%',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: onSeek == null
                                ? null
                                : (details) => _seek(
                                    details.localPosition.dx,
                                    constraints.maxWidth,
                                  ),
                            onHorizontalDragUpdate: onSeek == null
                                ? null
                                : (details) => _seek(
                                    details.localPosition.dx,
                                    constraints.maxWidth,
                                  ),
                            child: _VoiceBars(
                              color: accent,
                              progress: _progress,
                            ),
                          ),
                        ),
                      )
                    : SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          disabledActiveTrackColor: accent,
                          disabledInactiveTrackColor: accent.withValues(
                            alpha: .18,
                          ),
                          disabledThumbColor: accent,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                          trackShape: const RectangularSliderTrackShape(),
                        ),
                        child: Slider(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          value: _progress,
                          activeColor: accent,
                          inactiveColor: accent.withValues(alpha: .18),
                          onChanged: onSeek == null
                              ? null
                              : (value) => onSeek!(
                                  Duration(
                                    milliseconds:
                                        (duration.inMilliseconds * value)
                                            .round(),
                                  ),
                                ),
                        ),
                      ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time, style: TextStyle(color: muted, fontSize: 12)),
                  if (isUser) ...[
                    const SizedBox(width: 4),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _seek(double x, double width) {
    if (width <= 0) return;
    onSeek?.call(
      Duration(
        milliseconds: (duration.inMilliseconds * (x / width).clamp(0.0, 1.0))
            .round(),
      ),
    );
  }
}

/// Decorative bars indicate playback; they do not claim to represent PCM samples.
class _VoiceBars extends StatelessWidget {
  const _VoiceBars({
    required this.color,
    required this.progress,
    this.playing = false,
    this.compact = false,
  });
  final Color color;
  final double progress;
  final bool playing;
  final bool compact;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: compact ? 20 : 24,
    width: double.infinity,
    child: CustomPaint(
      painter: _VoiceBarsPainter(color, progress, playing, compact),
    ),
  );
}

class _VoiceBarsPainter extends CustomPainter {
  const _VoiceBarsPainter(
    this.color,
    this.progress,
    this.playing,
    this.compact,
  );
  final Color color;
  final double progress;
  final bool playing;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final count = compact ? 5 : math.max(1, (size.width / 3.4).floor());
    final spacing = size.width / count;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = compact ? 2.2 : 1.8;
    for (var i = 0; i < count; i++) {
      final pattern = compact
          ? const [.65, 1.0, .8, .5, .9]
          : const [.15, .2, .35, .8, .95, .4, .65, .3, .5, .9, .25, .45];
      final amplitude = pattern[i % pattern.length];
      final pulse = compact && playing
          ? .75 + .25 * math.sin(progress * 40 + i).abs()
          : 1.0;
      final height = math.max(2.0, size.height * amplitude * pulse);
      paint.color = compact || i / count < progress
          ? color
          : color.withValues(alpha: .35);
      final x = spacing * (i + .5);
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceBarsPainter old) =>
      old.color != color ||
      old.progress != progress ||
      old.playing != playing ||
      old.compact != compact;
}
