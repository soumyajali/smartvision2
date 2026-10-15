// Pure-Dart pre/post-processing for Ultralytics YOLOv8 TFLite exports.
//
// This file intentionally has no Flutter imports so it can run inside a
// background isolate and be unit tested with `flutter test` / `dart test`.
//
// Supported model layouts (validated against assets/models/yolov8n.tflite):
//   input  : [1, 3, H, W] (NCHW) or [1, H, W, 3] (NHWC), float32, RGB 0..1
//   output : [1, 4 + C, N] or [1, N, 4 + C], float32,
//            box = (cx, cy, w, h) either normalised (0..1) or in input pixels.
import 'dart:math' as math;
import 'dart:typed_data';

enum TensorLayout { nhwc, nchw }

/// Shape information for the model input tensor.
class ModelInputSpec {
  const ModelInputSpec({
    required this.width,
    required this.height,
    required this.layout,
  });

  final int width;
  final int height;
  final TensorLayout layout;

  /// Returns null when [shape] is not a supported RGB image tensor.
  static ModelInputSpec? fromShape(List<int> shape) {
    if (shape.length != 4 || shape[0] != 1) return null;
    if (shape[3] == 3 && shape[1] > 3 && shape[2] > 3) {
      return ModelInputSpec(
        width: shape[2],
        height: shape[1],
        layout: TensorLayout.nhwc,
      );
    }
    if (shape[1] == 3 && shape[2] > 3 && shape[3] > 3) {
      return ModelInputSpec(
        width: shape[3],
        height: shape[2],
        layout: TensorLayout.nchw,
      );
    }
    return null;
  }

  int get elementCount => width * height * 3;

  @override
  String toString() =>
      '${layout == TensorLayout.nchw ? 'NCHW' : 'NHWC'} ${width}x$height';
}

/// Aspect-preserving resize + padding (the same "letterbox" Ultralytics uses).
class Letterbox {
  const Letterbox({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.inputWidth,
    required this.inputHeight,
    required this.contentWidth,
    required this.contentHeight,
    required this.padX,
    required this.padY,
  });

  factory Letterbox.compute(
    int sourceWidth,
    int sourceHeight,
    int inputWidth,
    int inputHeight,
  ) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      throw ArgumentError('Image size must be positive '
          '(got ${sourceWidth}x$sourceHeight).');
    }
    final scale =
        math.min(inputWidth / sourceWidth, inputHeight / sourceHeight);
    final contentWidth =
        math.max(1, math.min(inputWidth, (sourceWidth * scale).round()));
    final contentHeight =
        math.max(1, math.min(inputHeight, (sourceHeight * scale).round()));
    return Letterbox(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      inputWidth: inputWidth,
      inputHeight: inputHeight,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
      padX: (inputWidth - contentWidth) ~/ 2,
      padY: (inputHeight - contentHeight) ~/ 2,
    );
  }

  final int sourceWidth;
  final int sourceHeight;
  final int inputWidth;
  final int inputHeight;
  final int contentWidth;
  final int contentHeight;
  final int padX;
  final int padY;

  double get scaleX => contentWidth / sourceWidth;
  double get scaleY => contentHeight / sourceHeight;

  /// Maps an x coordinate in model-input pixels to a normalised (0..1)
  /// coordinate of the original (upright) source image.
  double inputXToSource(double x) => ((x - padX) / contentWidth).clamp(0.0, 1.0).toDouble();

  /// Maps a y coordinate in model-input pixels to a normalised (0..1)
  /// coordinate of the original (upright) source image.
  double inputYToSource(double y) =>
      ((y - padY) / contentHeight).clamp(0.0, 1.0).toDouble();
}

/// One decoded detection. Coordinates are normalised to the upright source
/// image (0..1), so they can be drawn over any view that shows that image
/// without cropping.
class YoloDetection {
  const YoloDetection({
    required this.classIndex,
    required this.score,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int classIndex;
  final double score;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get area => math.max(0.0, width) * math.max(0.0, height);
}

const double _padValue = 114 / 255;

void _writePixel(
  Float32List out,
  ModelInputSpec spec,
  int x,
  int y,
  double r,
  double g,
  double b,
) {
  if (spec.layout == TensorLayout.nchw) {
    final plane = spec.width * spec.height;
    final index = y * spec.width + x;
    out[index] = r;
    out[plane + index] = g;
    out[2 * plane + index] = b;
  } else {
    final index = (y * spec.width + x) * 3;
    out[index] = r;
    out[index + 1] = g;
    out[index + 2] = b;
  }
}

Float32List _paddedTensor(ModelInputSpec spec) {
  final out = Float32List(spec.elementCount);
  out.fillRange(0, out.length, _padValue);
  return out;
}

/// Letterboxes an RGBA8888 buffer (4 bytes per pixel, tightly packed) into a
/// float32 RGB tensor using bilinear sampling.
Float32List letterboxRgba({
  required Uint8List rgba,
  required int width,
  required int height,
  required ModelInputSpec spec,
  required Letterbox letterbox,
}) {
  if (rgba.length < width * height * 4) {
    throw ArgumentError('RGBA buffer is smaller than ${width}x$height.');
  }
  final out = _paddedTensor(spec);
  final cw = letterbox.contentWidth;
  final ch = letterbox.contentHeight;

  // Pre-compute horizontal sample positions once per column.
  final x0s = Int32List(cw);
  final x1s = Int32List(cw);
  final wxs = Float64List(cw);
  for (var ox = 0; ox < cw; ox++) {
    final sx =
        ((ox + 0.5) * width / cw - 0.5).clamp(0.0, width - 1.0).toDouble();
    final x0 = sx.floor();
    x0s[ox] = x0;
    x1s[ox] = math.min(x0 + 1, width - 1);
    wxs[ox] = sx - x0;
  }

  for (var oy = 0; oy < ch; oy++) {
    final sy =
        ((oy + 0.5) * height / ch - 0.5).clamp(0.0, height - 1.0).toDouble();
    final y0 = sy.floor();
    final y1 = math.min(y0 + 1, height - 1);
    final wy = sy - y0;
    final row0 = y0 * width * 4;
    final row1 = y1 * width * 4;
    for (var ox = 0; ox < cw; ox++) {
      final a = row0 + x0s[ox] * 4;
      final b = row0 + x1s[ox] * 4;
      final c = row1 + x0s[ox] * 4;
      final d = row1 + x1s[ox] * 4;
      final wx = wxs[ox];
      final w00 = (1 - wx) * (1 - wy);
      final w01 = wx * (1 - wy);
      final w10 = (1 - wx) * wy;
      final w11 = wx * wy;
      final r = rgba[a] * w00 + rgba[b] * w01 + rgba[c] * w10 + rgba[d] * w11;
      final g = rgba[a + 1] * w00 +
          rgba[b + 1] * w01 +
          rgba[c + 1] * w10 +
          rgba[d + 1] * w11;
      final bl = rgba[a + 2] * w00 +
          rgba[b + 2] * w01 +
          rgba[c + 2] * w10 +
          rgba[d + 2] * w11;
      _writePixel(
        out,
        spec,
        ox + letterbox.padX,
        oy + letterbox.padY,
        r / 255,
        g / 255,
        bl / 255,
      );
    }
  }
  return out;
}

/// Rotation (clockwise) needed to make a sensor frame upright.
int normaliseRotation(int degrees) {
  final value = ((degrees % 360) + 360) % 360;
  if (value % 90 != 0) {
    throw ArgumentError('Rotation must be a multiple of 90 (got $degrees).');
  }
  return value;
}

/// Size of a sensor frame after applying [rotation] degrees clockwise.
({int width, int height}) uprightSize(int width, int height, int rotation) {
  final r = normaliseRotation(rotation);
  return (r == 90 || r == 270)
      ? (width: height, height: width)
      : (width: width, height: height);
}

/// Maps an upright pixel (ux, uy) back to the sensor pixel it came from.
/// Returns the sensor index packed as (sx, sy) through [outXY].
void uprightToSensor(
  int ux,
  int uy,
  int sensorWidth,
  int sensorHeight,
  int rotation,
  Int32List outXY,
) {
  switch (rotation) {
    case 90:
      outXY[0] = uy;
      outXY[1] = sensorHeight - 1 - ux;
      break;
    case 180:
      outXY[0] = sensorWidth - 1 - ux;
      outXY[1] = sensorHeight - 1 - uy;
      break;
    case 270:
      outXY[0] = sensorWidth - 1 - uy;
      outXY[1] = ux;
      break;
    default:
      outXY[0] = ux;
      outXY[1] = uy;
  }
}

int _clampByte(double value) {
  if (value <= 0) return 0;
  if (value >= 255) return 255;
  return value.toInt();
}

/// Converts a YUV_420_888 camera frame (three planes, any row/pixel stride)
/// directly into a letterboxed model tensor, rotating it upright on the way.
/// Uses nearest-neighbour sampling (camera frames are already small).
Float32List letterboxYuv420({
  required Uint8List yPlane,
  required Uint8List uPlane,
  required Uint8List vPlane,
  required int yRowStride,
  required int uvRowStride,
  required int uvPixelStride,
  required int sensorWidth,
  required int sensorHeight,
  required int rotation,
  required ModelInputSpec spec,
  required Letterbox letterbox,
}) {
  final rot = normaliseRotation(rotation);
  final upright = uprightSize(sensorWidth, sensorHeight, rot);
  if (letterbox.sourceWidth != upright.width ||
      letterbox.sourceHeight != upright.height) {
    throw ArgumentError('Letterbox was computed for a different frame size.');
  }
  final out = _paddedTensor(spec);
  final cw = letterbox.contentWidth;
  final ch = letterbox.contentHeight;
  final sensorXY = Int32List(2);
  for (var oy = 0; oy < ch; oy++) {
    final uy = math.min(upright.height - 1, (oy * upright.height) ~/ ch);
    for (var ox = 0; ox < cw; ox++) {
      final ux = math.min(upright.width - 1, (ox * upright.width) ~/ cw);
      uprightToSensor(ux, uy, sensorWidth, sensorHeight, rot, sensorXY);
      final sx = sensorXY[0];
      final sy = sensorXY[1];
      final yIndex = sy * yRowStride + sx;
      final uvIndex = (sy >> 1) * uvRowStride + (sx >> 1) * uvPixelStride;
      if (yIndex >= yPlane.length ||
          uvIndex >= uPlane.length ||
          uvIndex >= vPlane.length) {
        continue;
      }
      final yValue = yPlane[yIndex].toDouble();
      final u = uPlane[uvIndex] - 128.0;
      final v = vPlane[uvIndex] - 128.0;
      final r = _clampByte(yValue + 1.402 * v);
      final g = _clampByte(yValue - 0.344136 * u - 0.714136 * v);
      final b = _clampByte(yValue + 1.772 * u);
      _writePixel(
        out,
        spec,
        ox + letterbox.padX,
        oy + letterbox.padY,
        r / 255,
        g / 255,
        b / 255,
      );
    }
  }
  return out;
}

/// Converts a BGRA8888 frame (iOS camera stream) into a letterboxed tensor.
Float32List letterboxBgra({
  required Uint8List bgra,
  required int rowStride,
  required int sensorWidth,
  required int sensorHeight,
  required int rotation,
  required ModelInputSpec spec,
  required Letterbox letterbox,
}) {
  final rot = normaliseRotation(rotation);
  final upright = uprightSize(sensorWidth, sensorHeight, rot);
  final out = _paddedTensor(spec);
  final cw = letterbox.contentWidth;
  final ch = letterbox.contentHeight;
  final sensorXY = Int32List(2);
  for (var oy = 0; oy < ch; oy++) {
    final uy = math.min(upright.height - 1, (oy * upright.height) ~/ ch);
    for (var ox = 0; ox < cw; ox++) {
      final ux = math.min(upright.width - 1, (ox * upright.width) ~/ cw);
      uprightToSensor(ux, uy, sensorWidth, sensorHeight, rot, sensorXY);
      final index = sensorXY[1] * rowStride + sensorXY[0] * 4;
      if (index + 2 >= bgra.length) continue;
      _writePixel(
        out,
        spec,
        ox + letterbox.padX,
        oy + letterbox.padY,
        bgra[index + 2] / 255,
        bgra[index + 1] / 255,
        bgra[index] / 255,
      );
    }
  }
  return out;
}

double intersectionOverUnion(YoloDetection a, YoloDetection b) {
  final left = math.max(a.left, b.left);
  final top = math.max(a.top, b.top);
  final right = math.min(a.right, b.right);
  final bottom = math.min(a.bottom, b.bottom);
  final w = right - left;
  final h = bottom - top;
  if (w <= 0 || h <= 0) return 0;
  final intersection = w * h;
  final union = a.area + b.area - intersection;
  return union <= 0 ? 0 : intersection / union;
}

/// Decodes a raw YOLOv8 output tensor into detections in source-image
/// coordinates, applying the confidence threshold, NMS and the max-detections
/// cap. [classAgnostic] matches the FastAPI backend (`agnostic_nms=True`).
List<YoloDetection> decodeYoloOutput({
  required Float32List output,
  required List<int> shape,
  required int numClasses,
  required Letterbox letterbox,
  required double confidenceThreshold,
  required double iouThreshold,
  required int maxDetections,
  bool classAgnostic = true,
  int maxCandidates = 300,
}) {
  if (shape.length != 3 || shape[0] != 1) {
    throw ArgumentError('Unsupported YOLO output shape $shape.');
  }
  final channels = numClasses + 4;
  final bool channelsFirst;
  if (shape[1] == channels) {
    channelsFirst = true;
  } else if (shape[2] == channels) {
    channelsFirst = false;
  } else {
    throw ArgumentError(
        'YOLO output $shape does not match $numClasses class labels.');
  }
  final count = channelsFirst ? shape[2] : shape[1];
  if (output.length < count * channels) {
    throw ArgumentError('YOLO output buffer is too small for shape $shape.');
  }

  double valueAt(int candidate, int channel) => channelsFirst
      ? output[channel * count + candidate]
      : output[candidate * channels + channel];

  // Ultralytics exports either normalised (0..1) or pixel boxes depending on
  // the exporter version. Decide once for the whole tensor.
  var maxCoordinate = 0.0;
  for (var i = 0; i < count; i++) {
    final cx = valueAt(i, 0).abs();
    final cy = valueAt(i, 1).abs();
    if (cx.isFinite && cx > maxCoordinate) maxCoordinate = cx;
    if (cy.isFinite && cy > maxCoordinate) maxCoordinate = cy;
  }
  final normalisedBoxes = maxCoordinate <= 2.0;
  final sx = normalisedBoxes ? letterbox.inputWidth.toDouble() : 1.0;
  final sy = normalisedBoxes ? letterbox.inputHeight.toDouble() : 1.0;

  final candidates = <YoloDetection>[];
  final threshold = confidenceThreshold.clamp(0.0, 1.0).toDouble();
  for (var i = 0; i < count; i++) {
    var best = -1.0;
    var bestClass = -1;
    for (var c = 0; c < numClasses; c++) {
      final score = valueAt(i, 4 + c);
      if (score > best) {
        best = score;
        bestClass = c;
      }
    }
    if (bestClass < 0 || !best.isFinite || best < threshold) continue;

    final cx = valueAt(i, 0) * sx;
    final cy = valueAt(i, 1) * sy;
    final w = valueAt(i, 2) * sx;
    final h = valueAt(i, 3) * sy;
    if (!cx.isFinite || !cy.isFinite || !w.isFinite || !h.isFinite) continue;
    if (w <= 0 || h <= 0) continue;

    final left = letterbox.inputXToSource(cx - w / 2);
    final top = letterbox.inputYToSource(cy - h / 2);
    final right = letterbox.inputXToSource(cx + w / 2);
    final bottom = letterbox.inputYToSource(cy + h / 2);
    if (right - left <= 0 || bottom - top <= 0) continue;
    candidates.add(YoloDetection(
      classIndex: bestClass,
      score: best,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    ));
  }

  candidates.sort((a, b) => b.score.compareTo(a.score));
  final pool = candidates.length > maxCandidates
      ? candidates.sublist(0, maxCandidates)
      : candidates;
  final limit = math.max(1, maxDetections);
  final iou = iouThreshold.clamp(0.0, 1.0).toDouble();
  final kept = <YoloDetection>[];
  for (final candidate in pool) {
    var suppressed = false;
    for (final existing in kept) {
      if (!classAgnostic && existing.classIndex != candidate.classIndex) {
        continue;
      }
      if (intersectionOverUnion(existing, candidate) > iou) {
        suppressed = true;
        break;
      }
    }
    if (!suppressed) {
      kept.add(candidate);
      if (kept.length >= limit) break;
    }
  }
  return kept;
}
