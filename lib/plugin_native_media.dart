import 'dart:async';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class PluginNativeMedia {
  static Future<void> execute(
    List<String> arguments,
    Future<void> Function() check,
  ) async {
    await check();
    final done = Completer<void>();
    final ended = Completer<void>();
    unawaited(
      done.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    final session = await FFmpegKit.executeWithArgumentsAsync(arguments, (
      result,
    ) async {
      try {
        if (!ReturnCode.isSuccess(await result.getReturnCode()))
          throw StateError('媒体处理失败：输入编码或格式不支持');
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      } finally {
        if (!ended.isCompleted) ended.complete();
      }
    });
    var checking = false;
    final timer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (checking || done.isCompleted) return;
      checking = true;
      try {
        await check();
      } catch (error, stack) {
        try {
          await FFmpegKit.cancel(session.getSessionId());
        } catch (_) {}
        if (!done.isCompleted) done.completeError(error, stack);
      } finally {
        checking = false;
      }
    });
    try {
      await done.future.timeout(const Duration(minutes: 5));
      await check();
    } finally {
      timer.cancel();
      try {
        await FFmpegKit.cancel(session.getSessionId());
      } finally {
        await ended.future;
      }
    }
  }
}
