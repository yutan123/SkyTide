import 'package:flutter/material.dart';

import 'global_notice.dart';
import 'theme.dart';
import 'ui_components.dart';

class InterfaceThemePage extends StatefulWidget {
  const InterfaceThemePage({super.key});

  @override
  State<InterfaceThemePage> createState() => _InterfaceThemePageState();
}

class _InterfaceThemePageState extends State<InterfaceThemePage> {
  static const _styles = [
    (
      id: 'default',
      asset: 'skytide',
      aspectRatio: 1253 / 844,
      name: 'SkyTide',
      color: Color(0xFF378463),
    ),
    (
      id: 'wechat',
      asset: 'wechat',
      aspectRatio: 1264 / 706,
      name: '微信',
      color: Color(0xFF168445),
    ),
    (
      id: 'telegram',
      asset: 'telegram',
      aspectRatio: 1257 / 754,
      name: 'Telegram',
      color: Color(0xFF227DAA),
    ),
    (
      id: 'qq',
      asset: 'qq',
      aspectRatio: 1249 / 753,
      name: 'QQ',
      color: Color(0xFF346AC2),
    ),
  ];

  String? _previewId;
  bool _saving = false;

  Future<void> _apply(TideTheme theme, String id) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await theme.setInterfaceTheme(id);
      if (mounted) setState(() => _previewId = id);
    } catch (_) {
      if (mounted) GlobalNotice.show('保存主题失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final preview = _styles.firstWhere(
      (style) => style.id == (_previewId ?? theme.interfaceTheme),
      orElse: () => _styles.first,
    );
    final applied = preview.id == theme.interfaceTheme;
    final canApply = !applied || preview.id != 'default';
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('界面风格'),
          backgroundColor: Colors.transparent,
          foregroundColor: theme.textStrong,
          scrolledUnderElevation: 0,
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  FrostCard(
                    liquid: true,
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        for (final style in _styles)
                          Expanded(
                            child: Semantics(
                              button: true,
                              selected: preview.id == style.id,
                              label: style.id == theme.interfaceTheme
                                  ? '${style.name}，使用中'
                                  : style.name,
                              child: ExcludeSemantics(
                                child: BouncyTap(
                                  onTap: () {
                                    if (!_saving)
                                      setState(() => _previewId = style.id);
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    constraints: const BoxConstraints(
                                      minHeight: 52,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: preview.id == style.id
                                          ? style.color.withValues(alpha: .18)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          style.id == theme.interfaceTheme
                                              ? Icons.check_circle_rounded
                                              : Icons.circle,
                                          size: 14,
                                          color: theme.isDark
                                              ? Color.lerp(
                                                  style.color,
                                                  Colors.white,
                                                  .42,
                                                )
                                              : style.color,
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          style.name,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: theme.textStrong,
                                            fontSize: 12,
                                            fontWeight: preview.id == style.id
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FrostCard(
                    liquid: true,
                    radius: 26,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: AspectRatio(
                            aspectRatio: preview.aspectRatio,
                            child: Image.asset(
                              'assets/images/theme_preview_${preview.asset}.jpg',
                              key: ValueKey(preview.id),
                              fit: BoxFit.contain,
                              semanticLabel: '${preview.name} 界面预览',
                              errorBuilder: (_, _, _) => ColoredBox(
                                color: theme.surface,
                                child: Center(
                                  child: Text(
                                    '预览暂不可用',
                                    style: TextStyle(color: theme.textWeak),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _saving || !canApply
                              ? null
                              : () => _apply(
                                  theme,
                                  applied ? 'default' : preview.id,
                                ),
                          style: FilledButton.styleFrom(
                            backgroundColor: preview.color,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                          child: Text(
                            _saving
                                ? '正在保存…'
                                : applied
                                ? (canApply ? '恢复 SkyTide 风格' : '使用中')
                                : '应用此风格',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
