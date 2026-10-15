# Test fixtures

* `test_image_yolov8n_output.bin` – raw float32 (little-endian) output tensor
  `[1, 84, 2100]` of `assets/models/yolov8n.tflite` for `test_image.png`
  (1024×1024), letterboxed to the model's `[1, 3, 320, 320]` input.
* `test_image_expected.json` – detections produced from that tensor by an
  independent Python implementation (validated against OpenCV letterboxing +
  `cv2.dnn.NMSBoxes`) at confidence 0.25, IoU 0.45, max 100.

`test/yolo_codec_test.dart` decodes the same tensor with the app's Dart
decoder and checks it reproduces the reference detections.
