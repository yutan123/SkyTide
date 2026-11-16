import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

Color chatHeaderSurface(Color sample, {required bool dark}) => sample;

/// Read the wallpaper pixel behind the toolbar center after BoxFit.cover.
/// Preserve its RGB values without averaging or brightness adjustment.
Future<Color?> sampleChatHeaderColor(
  String path, {
  required Size viewport,
  required double toolbarCenterY,
}) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null || viewport.isEmpty) return null;
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, source, viewport);
    final crop = Alignment.center.inscribe(fitted.source, Offset.zero & source);
    final x = crop.center.dx.floor().clamp(0, image.width - 1);
    final y = (crop.top + toolbarCenterY / viewport.height * crop.height)
        .floor()
        .clamp(0, image.height - 1);
    final offset = (y * image.width + x) * 4;
    return Color.fromARGB(
      255,
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
