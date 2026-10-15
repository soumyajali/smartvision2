import 'dart:typed_data';

import 'package:camera/camera.dart';

/// A copy of one camera stream frame that can be sent to a background
/// isolate (CameraImage itself is not sendable and is recycled by the plugin).
class CameraFrameData {
  const CameraFrameData({
    required this.format,
    required this.width,
    required this.height,
    required this.planes,
    required this.rowStrides,
    required this.pixelStrides,
    required this.rotation,
    required this.mirrored,
  });

  /// 'yuv420' (Android) or 'bgra8888' (iOS).
  final String format;

  /// Sensor (un-rotated) frame size.
  final int width;
  final int height;
  final List<Uint8List> planes;
  final List<int> rowStrides;
  final List<int> pixelStrides;

  /// Clockwise rotation that makes the frame upright for a portrait UI.
  final int rotation;

  /// True for the front camera, whose preview is shown mirrored.
  final bool mirrored;

  bool get isSupported =>
      (format == 'yuv420' && planes.length >= 3) ||
      (format == 'bgra8888' && planes.isNotEmpty);

  /// Upright frame size (what the user sees in a portrait preview).
  int get uprightWidth => (rotation == 90 || rotation == 270) ? height : width;
  int get uprightHeight => (rotation == 90 || rotation == 270) ? width : height;

  static CameraFrameData fromCameraImage(
    CameraImage image, {
    required int rotation,
    required bool mirrored,
  }) {
    final String format;
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        format = 'yuv420';
        break;
      case ImageFormatGroup.bgra8888:
        format = 'bgra8888';
        break;
      default:
        format = image.format.group.name;
    }
    return CameraFrameData(
      format: format,
      width: image.width,
      height: image.height,
      // Copy the bytes: the plugin reuses the underlying buffers.
      planes: [
        for (final plane in image.planes) Uint8List.fromList(plane.bytes),
      ],
      rowStrides: [for (final plane in image.planes) plane.bytesPerRow],
      pixelStrides: [
        for (final plane in image.planes) plane.bytesPerPixel ?? 1,
      ],
      rotation: rotation,
      mirrored: mirrored,
    );
  }

  /// Converts an Android YUV_420_888 frame into NV21 for ML Kit.
  Uint8List toNv21() {
    if (format != 'yuv420' || planes.length < 3) {
      throw StateError('NV21 conversion requires a YUV420 frame.');
    }
    final yPlane = planes[0];
    final uPlane = planes[1];
    final vPlane = planes[2];
    final yRowStride = rowStrides[0];
    final uvRowStride = rowStrides[1];
    final uvPixelStride = pixelStrides[1];
    final chromaWidth = width ~/ 2;
    final chromaHeight = height ~/ 2;
    final out = Uint8List(width * height + 2 * chromaWidth * chromaHeight);
    var offset = 0;
    for (var y = 0; y < height; y++) {
      final rowStart = y * yRowStride;
      final end = rowStart + width;
      if (end <= yPlane.length) {
        out.setRange(offset, offset + width, yPlane, rowStart);
      }
      offset += width;
    }
    for (var y = 0; y < chromaHeight; y++) {
      for (var x = 0; x < chromaWidth; x++) {
        final index = y * uvRowStride + x * uvPixelStride;
        if (index < vPlane.length && index < uPlane.length) {
          out[offset] = vPlane[index];
          out[offset + 1] = uPlane[index];
        }
        offset += 2;
      }
    }
    return out;
  }
}
