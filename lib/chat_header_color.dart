import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Keep the toolbar brightness aligned with the selected wallpaper.
Color chatHeaderSurface(Color sample, {required bool dark}) => sample;

Future<Color?> sampleChatHeaderColor(String path) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
      targetWidth: 48,
      targetHeight: 48,
      allowUpscaling: false,
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    double red = 0, green = 0, blue = 0, weight = 0;
    // Use the whole thumbnail. Sampling only the top third can select a
    // darker local patch from a gradient wallpaper.
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final offset = (y * image.width + x) * 4;
        final alpha = data.getUint8(offset + 3) / 255;
        red += data.getUint8(offset) * alpha;
        green += data.getUint8(offset + 1) * alpha;
        blue += data.getUint8(offset + 2) * alpha;
        weight += alpha;
      }
    }
    if (weight == 0) return null;
    return Color.fromARGB(
      255,
      (red / weight).round(),
      (green / weight).round(),
      (blue / weight).round(),
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
