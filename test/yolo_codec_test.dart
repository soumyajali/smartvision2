import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_vision/services/yolo_codec.dart';

void main() {
  group('ModelInputSpec', () {
    test('accepts the bundled channels-first model [1,3,320,320]', () {
      final spec = ModelInputSpec.fromShape([1, 3, 320, 320]);
      expect(spec, isNotNull);
      expect(spec!.layout, TensorLayout.nchw);
      expect(spec.width, 320);
      expect(spec.height, 320);
    });

    test('accepts channels-last models [1,640,640,3]', () {
      final spec = ModelInputSpec.fromShape([1, 640, 640, 3]);
      expect(spec!.layout, TensorLayout.nhwc);
      expect(spec.width, 640);
    });

    test('rejects non-image tensors', () {
      expect(ModelInputSpec.fromShape([1, 84, 2100]), isNull);
      expect(ModelInputSpec.fromShape([2, 3, 320, 320]), isNull);
    });
  });

  group('Letterbox', () {
    test('landscape image is padded top and bottom', () {
      final lb = Letterbox.compute(1280, 720, 320, 320);
      expect(lb.contentWidth, 320);
      expect(lb.contentHeight, 180);
      expect(lb.padX, 0);
      expect(lb.padY, 70);
      // Centre of the model input maps to the centre of the image.
      expect(lb.inputXToSource(160), closeTo(0.5, 1e-9));
      expect(lb.inputYToSource(160), closeTo(0.5, 1e-9));
      // Padding maps outside the image and is clamped.
      expect(lb.inputYToSource(10), 0);
    });

    test('portrait image is padded left and right', () {
      final lb = Letterbox.compute(480, 640, 320, 320);
      expect(lb.contentWidth, 240);
      expect(lb.contentHeight, 320);
      expect(lb.padX, 40);
      expect(lb.padY, 0);
    });
  });

  group('letterboxRgba', () {
    test('writes planar RGB for NCHW and pads with 114/255', () {
      const spec =
          ModelInputSpec(width: 4, height: 4, layout: TensorLayout.nchw);
      // 4x2 solid red image -> content rows 1..2, padding rows 0 and 3.
      final rgba = Uint8List(4 * 2 * 4);
      for (var i = 0; i < 8; i++) {
        rgba[i * 4] = 255;
        rgba[i * 4 + 3] = 255;
      }
      final lb = Letterbox.compute(4, 2, 4, 4);
      final tensor = letterboxRgba(
          rgba: rgba, width: 4, height: 2, spec: spec, letterbox: lb);
      expect(tensor.length, 48);
      expect(tensor[0], closeTo(114 / 255, 1e-6)); // R plane, padding
      expect(tensor[1 * 4 + 1], closeTo(1.0, 1e-6)); // R plane, content
      expect(tensor[16 + 1 * 4 + 1], closeTo(0.0, 1e-6)); // G plane, content
    });
  });

  group('uprightToSensor', () {
    test('90 degree rotation maps the top-left to the sensor bottom-left', () {
      final xy = Int32List(2);
      uprightToSensor(0, 0, 640, 480, 90, xy);
      expect(xy, [0, 479]);
      uprightToSensor(479, 0, 640, 480, 90, xy);
      expect(xy, [0, 0]);
    });

    test('270 degree rotation maps the top-left to the sensor top-right', () {
      final xy = Int32List(2);
      uprightToSensor(0, 0, 640, 480, 270, xy);
      expect(xy, [639, 0]);
    });

    test('upright size swaps for 90/270', () {
      expect(uprightSize(640, 480, 90), (width: 480, height: 640));
      expect(uprightSize(640, 480, 0), (width: 640, height: 480));
    });
  });

  group('decodeYoloOutput', () {
    Float32List synthetic(List<List<double>> candidates, int classes) {
      // channels-first [1, 4 + classes, N]
      final n = candidates.length;
      final out = Float32List((4 + classes) * n);
      for (var i = 0; i < n; i++) {
        for (var c = 0; c < 4 + classes; c++) {
          out[c * n + i] = candidates[i][c];
        }
      }
      return out;
    }

    test('maps normalised boxes back through the letterbox', () {
      final lb = Letterbox.compute(1280, 720, 320, 320);
      // Box covering the whole content area: cx=0.5, cy=0.5, w=1, h=180/320.
      final out = synthetic([
        [0.5, 0.5, 1.0, 180 / 320, 0.9, 0.1],
      ], 2);
      final dets = decodeYoloOutput(
        output: out,
        shape: const [1, 6, 1],
        numClasses: 2,
        letterbox: lb,
        confidenceThreshold: 0.25,
        iouThreshold: 0.45,
        maxDetections: 10,
      );
      expect(dets, hasLength(1));
      expect(dets.first.classIndex, 0);
      expect(dets.first.left, closeTo(0, 1e-6));
      expect(dets.first.top, closeTo(0, 1e-6));
      expect(dets.first.right, closeTo(1, 1e-6));
      expect(dets.first.bottom, closeTo(1, 1e-6));
    });

    test('applies confidence threshold, NMS and max detections', () {
      final lb = Letterbox.compute(320, 320, 320, 320);
      final out = synthetic([
        [0.5, 0.5, 0.2, 0.2, 0.9, 0.0], // kept
        [0.505, 0.5, 0.2, 0.2, 0.8, 0.0], // overlaps -> suppressed
        [0.1, 0.1, 0.1, 0.1, 0.0, 0.7], // separate -> kept
        [0.9, 0.9, 0.1, 0.1, 0.1, 0.0], // below threshold
      ], 2);
      final dets = decodeYoloOutput(
        output: out,
        shape: const [1, 6, 4],
        numClasses: 2,
        letterbox: lb,
        confidenceThreshold: 0.25,
        iouThreshold: 0.45,
        maxDetections: 10,
      );
      expect(dets.map((d) => d.classIndex), [0, 1]);

      final capped = decodeYoloOutput(
        output: out,
        shape: const [1, 6, 4],
        numClasses: 2,
        letterbox: lb,
        confidenceThreshold: 0.25,
        iouThreshold: 0.45,
        maxDetections: 1,
      );
      expect(capped, hasLength(1));
    });

    test('rejects outputs that do not match the labels', () {
      expect(
        () => decodeYoloOutput(
          output: Float32List(10),
          shape: const [1, 5, 2],
          numClasses: 80,
          letterbox: Letterbox.compute(10, 10, 320, 320),
          confidenceThreshold: 0.25,
          iouThreshold: 0.45,
          maxDetections: 10,
        ),
        throwsArgumentError,
      );
    });

    test('matches the Python reference on real yolov8n.tflite output', () {
      // Fixture produced by running assets/models/yolov8n.tflite on
      // test_image.png (see test/fixtures/README.md).
      final raw = File('test/fixtures/test_image_yolov8n_output.bin')
          .readAsBytesSync();
      final expected = jsonDecode(
              File('test/fixtures/test_image_expected.json')
                  .readAsStringSync())
          as Map<String, dynamic>;
      final output = Float32List.view(
          Uint8List.fromList(raw).buffer, 0, raw.length ~/ 4);
      final lb = Letterbox.compute(
          expected['width'] as int, expected['height'] as int, 320, 320);
      final dets = decodeYoloOutput(
        output: output,
        shape: const [1, 84, 2100],
        numClasses: 80,
        letterbox: lb,
        confidenceThreshold: 0.25,
        iouThreshold: 0.45,
        maxDetections: 100,
      );
      final reference = (expected['detections'] as List).cast<Map>();
      expect(dets.length, reference.length);
      for (var i = 0; i < dets.length; i++) {
        expect(dets[i].classIndex, reference[i]['class']);
        expect(dets[i].score, closeTo(reference[i]['score'] as num, 1e-4));
        final box = (reference[i]['box'] as List).cast<num>();
        expect(dets[i].left, closeTo(box[0], 1e-4));
        expect(dets[i].top, closeTo(box[1], 1e-4));
        expect(dets[i].right, closeTo(box[2], 1e-4));
        expect(dets[i].bottom, closeTo(box[3], 1e-4));
      }
    });
  });
}
