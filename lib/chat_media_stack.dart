import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'photo_image_provider.dart';
import 'theme.dart';
import 'video_poster.dart';

class ChatStackMedia {
  const ChatStackMedia({
    required this.id,
    required this.path,
    required this.isVideo,
  });
  final String id;
  final String path;
  final bool isVideo;
}

/// A fixed-size deck: decoding a photo or video poster cannot move the chat.
class ChatMediaStack extends StatefulWidget {
  const ChatMediaStack({
    super.key,
    required this.items,
    required this.onExpand,
    required this.onOpen,
    required this.onLongPress,
  });

  final List<ChatStackMedia> items;
  final VoidCallback onExpand;
  final ValueChanged<int> onOpen;
  final ValueChanged<int> onLongPress;

  @override
  State<ChatMediaStack> createState() => _ChatMediaStackState();
}

class _ChatMediaStackState extends State<ChatMediaStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  int _index = 0;
  double _drag = 0;
  double _from = 0;
  double _to = 0;
  bool _turning = false;

  double get _offset => _turning
      ? _from + (_to - _from) * Curves.easeOutCubic.transform(_motion.value)
      : _drag;

  @override
  void didUpdateWidget(covariant ChatMediaStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeId = oldWidget.items[_index % oldWidget.items.length].id;
    final nextIndex = widget.items.indexWhere((item) => item.id == activeId);
    if (nextIndex < 0 || nextIndex != _index) {
      _motion.stop();
      _turning = false;
      _drag = 0;
      _index = math.max(0, nextIndex);
    }
  }

  Future<void> _settle(double target, {required bool advance}) async {
    if (_turning || _motion.isAnimating) return;
    _turning = true;
    _from = _drag;
    _to = target;
    try {
      await _motion.forward(from: 0).orCancel;
      if (!mounted) return;
      setState(() {
        if (advance) _index = (_index + 1) % widget.items.length;
        _drag = 0;
        _turning = false;
        _motion.reset();
      });
    } on TickerCanceled {
      // The row can disappear when expanded, deleted or the chat is closed.
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(300.0, constraints.maxWidth);
        final deckWidth = math.max(70.0, width - 64);
        final cardWidth = math.max(54.0, deckWidth - 22);
        final cardHeight = (cardWidth * 1.32).clamp(110.0, 310.0);
        return SizedBox(
          width: width,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: '展开全部 ${widget.items.length} 张图片或视频',
                child: SizedBox(
                  width: 60,
                  child: Material(
                    color: theme.surface.withValues(alpha: .94),
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      onTap: widget.onExpand,
                      borderRadius: BorderRadius.circular(24),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          '展开 ${widget.items.length}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.textStrong,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: deckWidth,
                height: cardHeight + 34,
                child: AnimatedBuilder(
                  animation: _motion,
                  builder: (context, _) {
                    final dx = _offset;
                    final progress = (dx.abs() / cardWidth).clamp(0.0, 1.0);
                    return Semantics(
                      label: '媒体 ${_index + 1} / ${widget.items.length}，左右滑动翻页',
                      onIncrease: () =>
                          _settle(-cardWidth * 1.35, advance: true),
                      onDecrease: () =>
                          _settle(cardWidth * 1.35, advance: true),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          if (_turning) return;
                          setState(() => _drag += details.delta.dx);
                        },
                        onHorizontalDragEnd: (details) {
                          if (_turning) return;
                          final velocity = details.primaryVelocity ?? 0;
                          final turn =
                              _drag.abs() > cardWidth * .25 ||
                              velocity.abs() > 550;
                          final direction = _drag.abs() > 4
                              ? _drag.sign
                              : velocity.sign;
                          _settle(
                            turn ? direction * cardWidth * 1.35 : 0,
                            advance: turn,
                          );
                        },
                        onHorizontalDragCancel: () =>
                            _settle(0, advance: false),
                        onTap: () {
                          if (!_turning) widget.onOpen(_index);
                        },
                        onLongPress: () {
                          if (!_turning) widget.onLongPress(_index);
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.topCenter,
                          children: [
                            for (var depth = 2; depth >= 0; depth--)
                              Positioned(
                                top: 8,
                                child: Transform.translate(
                                  offset: depth == 0
                                      ? Offset(dx, dx.abs() * .045)
                                      : Offset(
                                          (depth == 1 ? -7 : 7) *
                                              (1 - progress),
                                          (depth * 10 - progress * 10),
                                        ),
                                  child: Transform.rotate(
                                    angle: depth == 0
                                        ? dx / cardWidth * .19
                                        : (depth == 1 ? -.035 : .035) *
                                              (1 - progress),
                                    child: Transform.scale(
                                      scale: depth == 0
                                          ? 1
                                          : 1 - depth * .055 + progress * .055,
                                      child: Opacity(
                                        opacity: depth == 0
                                            ? 1 -
                                                  ((progress - .7) / .3).clamp(
                                                    0.0,
                                                    1.0,
                                                  )
                                            : 1,
                                        child: Container(
                                          width: cardWidth,
                                          height: cardHeight,
                                          clipBehavior: Clip.antiAlias,
                                          decoration: BoxDecoration(
                                            color: theme.surface,
                                            borderRadius: BorderRadius.circular(
                                              15,
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: .5,
                                              ),
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: .13,
                                                ),
                                                blurRadius: 10,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              _StackPreview(
                                                key: ValueKey(
                                                  widget
                                                      .items[(_index + depth) %
                                                          widget.items.length]
                                                      .id,
                                                ),
                                                item:
                                                    widget.items[(_index +
                                                            depth) %
                                                        widget.items.length],
                                              ),
                                              if (depth == 0)
                                                Positioned(
                                                  right: 8,
                                                  bottom: 8,
                                                  child: Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black
                                                          .withValues(
                                                            alpha: .45,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      '${_index + 1}/${widget.items.length}',
                                                      style: const TextStyle(
                                                        fontSize: 10,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StackPreview extends StatefulWidget {
  const _StackPreview({super.key, required this.item});
  final ChatStackMedia item;

  @override
  State<_StackPreview> createState() => _StackPreviewState();
}

class _StackPreviewState extends State<_StackPreview> {
  Future<VideoPoster>? _poster;

  @override
  void initState() {
    super.initState();
    if (widget.item.isVideo)
      _poster = VideoPosterService.load(widget.item.path);
  }

  @override
  void didUpdateWidget(covariant _StackPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path ||
        oldWidget.item.isVideo != widget.item.isVideo) {
      _poster = widget.item.isVideo
          ? VideoPosterService.load(widget.item.path)
          : null;
    }
  }

  Widget _unavailable() => Center(
    child: Icon(
      Icons.broken_image_outlined,
      color: TideTheme.of(context).textWeak,
      size: 30,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.item.isVideo) {
      return Image(
        image: ResizeImage.resizeIfNeeded(
          640,
          null,
          photoImageProvider(widget.item.path),
        ),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _unavailable(),
      );
    }
    return FutureBuilder<VideoPoster>(
      future: _poster,
      builder: (context, snapshot) => Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF191C20)),
          if (snapshot.hasData)
            Image.file(
              File(snapshot.data!.path),
              fit: BoxFit.cover,
              cacheWidth: 640,
              errorBuilder: (_, __, ___) => _unavailable(),
            )
          else if (snapshot.hasError)
            _unavailable(),
          Center(
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: .4),
                border: Border.all(color: Colors.white.withValues(alpha: .7)),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
