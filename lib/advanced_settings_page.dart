import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_log_service.dart';
import 'db.dart';
import 'device_capability_service.dart';
import 'global_notice.dart';
import 'log_session_detail_page.dart';
import 'theme.dart';
import 'ui_components.dart';

class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage({super.key});

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage> {
  bool _imageCompression = true;
  bool _audioCompression = true;
  bool _videoCompression = true;
  bool _haptics = false;
  bool _extraContext = false;
  final Map<String, String> _boundBotNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await TideHaptics.load();
    final prefs = await SharedPreferences.getInstance();
    final capability = DeviceCapabilityService.instance;
    final bots = await DBManager().getAllBots();
    final db = DBManager();
    final botNames = <String, String>{};
    for (final feature in const [DeviceCapabilityService.contextFeature]) {
      final id = await capability.boundBot(feature);
      if (id != null && id.isNotEmpty) {
        final bot = bots.cast<Map<String, dynamic>>().firstWhere(
          (item) => item['id']?.toString() == id,
          orElse: () => const {},
        );
        botNames[feature] = bot['name']?.toString() ?? id;
      }
    }
    final audioCompression =
        await db.getKV('audio_compression_enabled') != 'false';
    final videoCompression =
        await db.getKV('video_compression_enabled') != 'false';
    final imageCompression =
        await db.getKV('image_compression_enabled') != 'false';
    if (mounted) {
      setState(() {
        _imageCompression = imageCompression;
        _audioCompression = audioCompression;
        _videoCompression = videoCompression;
        _haptics = prefs.getBool('tide_haptics_enabled') ?? true;
        _extraContext = prefs.getBool('extra_context_enabled') ?? false;
        _boundBotNames
          ..clear()
          ..addAll(botNames);
      });
    }
  }

  Future<void> _setProtectedToggle({
    required String key,
    required String feature,
    required bool value,
    required String title,
    required String description,
    required Set<String> defaultWhitelist,
    required ValueChanged<bool> update,
  }) async {
    final capability = DeviceCapabilityService.instance;
    if (!value) {
      await (await SharedPreferences.getInstance()).setBool(key, false);
      if (mounted) setState(() => update(false));
      return;
    }
    if (!mounted) return;
    final approved =
        await TideDialogs.show<bool>(
          context: context,
          builder: (ctx) => TideDialogSurface(
            title: Text(title, style: const TextStyle(fontFamily: 'TideFont')),
            content: Text(
              description,
              style: const TextStyle(fontFamily: 'TideFont'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('配置授权'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved || !mounted) return;
    final bots = await DBManager().getAllBots();
    if (!mounted || bots.isEmpty) return;
    final botId = await showTideSheet<String>(
      context: context,
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('选择可使用此能力的机器人')),
            for (final bot in bots)
              ListTile(
                title: Text(bot['name']?.toString() ?? '未命名机器人'),
                subtitle: Text(bot['id']?.toString() ?? ''),
                onTap: () => Navigator.pop(context, bot['id']?.toString()),
              ),
          ],
        ),
      ),
    );
    if (botId == null || botId.isEmpty) return;
    await capability.bindBot(feature, botId);
    final selected = await _chooseWhitelist(feature, defaultWhitelist);
    if (selected == null || selected.isEmpty) return;
    await capability.setWhitelist(feature, selected);
    await _requestMissingSystemPermissions(feature, selected);
    await (await SharedPreferences.getInstance()).setBool(key, true);
    if (mounted) setState(() => update(true));
  }

  Future<Set<String>?> _chooseWhitelist(
    String feature,
    Set<String> defaults,
  ) async {
    final existing = await DeviceCapabilityService.instance.whitelist(feature);
    final values = <String>{...defaults, ...existing};
    final labels = feature == DeviceCapabilityService.contextFeature
        ? const {
            'battery': '电量',
            'location': '位置（用于当地天气等按需信息）',
            'notifications': '最近通知内容',
            'app_usage': '应用使用时长',
          }
        : const {
            'back': '返回',
            'home': '回到桌面',
            'recents': '打开最近任务',
            'notifications': '展开通知栏',
            'click': '按坐标点击',
            'click_selector': '按文字、描述或资源 ID 点击',
            'input': '向当前输入框填入文字',
            'scroll_up': '向上滚动',
            'scroll_down': '向下滚动',
            'open_app': '打开应用',
            'close_app': '关闭应用后台进程',
            'jump_tidebot': '跳转 TideBot',
          };
    values.removeWhere((value) => !labels.containsKey(value));
    values.addAll(defaults);
    if (!mounted) return null;
    return TideDialogs.show<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setLocal) => TideDialogSurface(
          title: const Text('选择允许项目', style: TextStyle(fontFamily: 'TideFont')),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.58,
            ),
            child: Scrollbar(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in labels.entries)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: values.contains(entry.key),
                      title: Text(
                        entry.value,
                        style: const TextStyle(fontFamily: 'TideFont'),
                      ),
                      onChanged: (checked) => setLocal(() {
                        if (checked == true) {
                          values.add(entry.key);
                        } else {
                          values.remove(entry.key);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, values),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _manageFeature(String feature, Set<String> defaults) async {
    final bots = await DBManager().getAllBots();
    if (!mounted || bots.isEmpty) {
      if (mounted) GlobalNotice.show('请先创建机器人');
      return;
    }
    final currentId = await DeviceCapabilityService.instance.boundBot(feature);
    final selectedId = await showTideSheet<String>(
      context: context,
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('选择授权机器人')),
            for (final bot in bots)
              ListTile(
                selected: bot['id']?.toString() == currentId,
                title: Text(bot['name']?.toString() ?? '未命名机器人'),
                subtitle: Text(bot['id']?.toString() ?? ''),
                onTap: () => Navigator.pop(context, bot['id']?.toString()),
              ),
          ],
        ),
      ),
    );
    if (selectedId == null || selectedId.isEmpty) return;
    await DeviceCapabilityService.instance.bindBot(feature, selectedId);
    final selected = await _chooseWhitelist(feature, defaults);
    if (selected == null) return;
    await DeviceCapabilityService.instance.setWhitelist(feature, selected);
    await _requestMissingSystemPermissions(feature, selected);
    await _load();
  }

  Future<void> _requestMissingSystemPermissions(
    String feature,
    Set<String> selected,
  ) async {
    final capability = DeviceCapabilityService.instance;
    final state = await capability.capabilityState();
    Future<void> explain(String message, Future<void> Function() open) async {
      if (!mounted) return;
      GlobalNotice.show(message, color: TideTheme.of(context).primary);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await open();
    }

    if (feature == DeviceCapabilityService.contextFeature) {
      if (selected.contains('location') &&
          state['locationPermission'] != true) {
        await Permission.location.request();
      }
      if (selected.contains('app_usage') && state['usageAccess'] != true) {
        await explain(
          '请在系统页面允许 TideBot 查看使用情况访问权限',
          capability.openUsageAccessSettings,
        );
      }
      if (selected.contains('notifications') &&
          state['notificationAccess'] != true) {
        await explain(
          '请在系统页面开启 TideBot 通知使用权',
          capability.openNotificationListenerSettings,
        );
      }
    }
  }

  Widget _featureFooter(String feature, Set<String> defaults) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '启用的机器人：${_boundBotNames[feature] ?? '未绑定'}',
        style: const TextStyle(fontFamily: 'TideFont', fontSize: 13),
      ),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        onPressed: () => _manageFeature(feature, defaults),
        icon: const Icon(Icons.admin_panel_settings_outlined),
        label: const Text('管理权限'),
      ),
    ],
  );
  Widget _settingToggle({
    required String title,
    required String description,
    required bool value,
    required String setting,
    required void Function(bool) update,
  }) {
    final theme = TideTheme.of(context);
    return FrostCard(
      padding: const EdgeInsets.all(16),
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(
          title,
          style: TextStyle(fontFamily: 'TideFont', color: theme.textStrong),
        ),
        subtitle: Text(
          description,
          style: TextStyle(
            fontFamily: 'TideFont',
            color: theme.textWeak,
            fontSize: 12,
          ),
        ),
        value: value,
        activeThumbColor: theme.primary,
        onChanged: (enabled) async {
          await DBManager().setKV(setting, '$enabled');
          if (mounted) update(enabled);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            '高级设置',
            style: TextStyle(
              fontFamily: 'TideFont',
              color: theme.textStrong,
              fontWeight: FontWeight.w700,
            ),
          ),
          iconTheme: IconThemeData(color: theme.iconMuted),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            FrostCard(
              padding: const EdgeInsets.all(16),
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '自动压缩画质',
                  style: TextStyle(
                    fontFamily: 'TideFont',
                    color: theme.textStrong,
                  ),
                ),
                subtitle: Text(
                  '默认开启，收发图片保存后自动压缩为最高 1080p 的 JPEG，节省本地空间；小图不放大，动图保留。关闭后保留原图。',
                  style: TextStyle(
                    fontFamily: 'TideFont',
                    color: theme.textWeak,
                    fontSize: 12,
                  ),
                ),
                value: _imageCompression,
                activeThumbColor: theme.primary,
                onChanged: (value) async {
                  await DBManager().setKV(
                    'image_compression_enabled',
                    '$value',
                  );
                  if (mounted) setState(() => _imageCompression = value);
                },
              ),
            ),
            const SizedBox(height: 12),
            _settingToggle(
              title: '音频自动压缩',
              description:
                  '默认开启，语音和音频先发送，再后台转为 M4A / AAC 保存；单声道最高 64 kbps，双声道最高 96 kbps。机器人音频同样处理。',
              value: _audioCompression,
              setting: 'audio_compression_enabled',
              update: (value) => setState(() => _audioCompression = value),
            ),
            const SizedBox(height: 12),
            _settingToggle(
              title: '视频自动压缩',
              description:
                  '默认开启，视频先发送，再后台转为 MP4 保存；最高 1080p、30 帧，保持比例，小视频不放大。机器人视频同样处理。',
              value: _videoCompression,
              setting: 'video_compression_enabled',
              update: (value) => setState(() => _videoCompression = value),
            ),
            const SizedBox(height: 12),
            FrostCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '触感反馈',
                    style: TextStyle(
                      fontFamily: 'TideFont',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: theme.textStrong,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '开启后，使用 TideBot 的按钮和卡片时会有轻微震动。',
                    style: TextStyle(
                      fontFamily: 'TideFont',
                      color: theme.textWeak,
                      fontSize: 13,
                    ),
                  ),
                  Switch.adaptive(
                    value: _haptics,
                    activeThumbColor: theme.primary,
                    onChanged: (value) async {
                      await TideHaptics.setEnabled(value);
                      if (mounted) setState(() => _haptics = value);
                      if (value) TideHaptics.tap();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FrostCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '额外信息感知',
                      style: TextStyle(fontFamily: 'TideFont'),
                    ),
                    subtitle: const Text(
                      '仅在你绑定机器人并授予所需权限后，按需提供设备状态。',
                      style: TextStyle(fontFamily: 'TideFont'),
                    ),
                    value: _extraContext,
                    onChanged: (value) => _setProtectedToggle(
                      key: 'extra_context_enabled',
                      feature: DeviceCapabilityService.contextFeature,
                      value: value,
                      title: '授权额外信息感知',
                      description: '启用后仍需逐项选择允许的信息；信息只在与当前问题有关时注入上下文。',
                      defaultWhitelist: const {'battery'},
                      update: (v) => _extraContext = v,
                    ),
                  ),
                  _featureFooter(DeviceCapabilityService.contextFeature, const {
                    'battery',
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LogHistoryPage extends StatelessWidget {
  const LogHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            '历史日志',
            style: TextStyle(
              fontFamily: 'TideFont',
              color: theme.textStrong,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: FutureBuilder<List<AppLogSession>>(
          future: AppLogService.instance.history(),
          builder: (_, snapshot) {
            final logs = snapshot.data ?? const <AppLogSession>[];
            if (snapshot.connectionState != ConnectionState.done)
              return Center(
                child: CircularProgressIndicator(color: theme.primary),
              );
            if (logs.isEmpty)
              return Center(
                child: Text(
                  '暂无已保存日志',
                  style: TextStyle(
                    fontFamily: 'TideFont',
                    color: theme.textFaint,
                  ),
                ),
              );
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: logs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final session = logs[i];
                return FrostCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  LogSessionDetailPage(session: session),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${session.startedAt.toLocal()} · ${session.entries.length} 条${session.hasError ? ' · 含错误' : ''}',
                                style: TextStyle(
                                  fontFamily: 'TideFont',
                                  color: session.hasError
                                      ? Colors.redAccent
                                      : theme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                session.entries.isEmpty
                                    ? '空日志'
                                    : session.entries.first.message,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'TideFont',
                                  color: theme.textStrong,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () async {
                          await AppLogService.instance.deleteSession(
                            session.id,
                          );
                          if (context.mounted)
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const LogHistoryPage(),
                              ),
                            );
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
