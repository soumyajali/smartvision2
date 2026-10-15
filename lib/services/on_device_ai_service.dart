import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:video_player/video_player.dart';

import '../models/camera_frame.dart';
import '../models/detection_result.dart';
import '../models/detection_settings.dart';
import 'yolo_codec.dart';

/// Labels treated as hazards. Mirrors HAZARD_CLASSES in ai_server.py
/// (COCO only contains "knife" and "scissors"; the others never fire with the
/// bundled model but are kept for parity with the backend).
const Set<String> kHazardLabels = {'knife', 'scissors', 'gun', 'fire'};

/// On-device AI engine: YOLOv8 TFLite object detection (run in a background
/// isolate), ML Kit OCR / face detection / translation, and video sampling.
class OnDeviceAiService extends ChangeNotifier {
  OnDeviceAiService._();

  static final OnDeviceAiService instance = OnDeviceAiService._();

  static const String modelAsset = 'assets/models/yolov8n.tflite';
  static const String labelsAsset = 'assets/models/labels.txt';

  Interpreter? _interpreter;
  _DetectionWorker? _worker;
  ModelInputSpec? _inputSpec;
  List<int> _outputShape = const [];
  List<String> _labels = const [];
  String? _modelError;
  bool _isLoading = false;
  Future<void>? _loading;

  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      enableLandmarks: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );
  final FaceDetector _liveFaceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  final DrowsinessTracker _drowsiness = DrowsinessTracker();

  bool get isModelLoaded => _interpreter != null && _inputSpec != null;
  bool get isLoading => _isLoading;
  String? get modelError => _modelError;
  List<String> get labels => _labels;
  String get modelName => 'YOLOv8n TFLite · COCO ${_labels.isEmpty ? 80 : _labels.length}';

  /// Human readable description of the loaded tensors, e.g. "NCHW 320x320".
  String get modelInputDescription =>
      _inputSpec?.toString() ?? (isLoading ? 'Loading…' : 'Not loaded');
  String get modelOutputDescription =>
      _outputShape.isEmpty ? '—' : _outputShape.toString();
  bool get usesBackgroundIsolate => _worker != null;

  /// Loads the model. Never throws; the error is exposed via [modelError] so
  /// the UI can show the real reason instead of crashing.
  Future<void> initialize() {
    if (isModelLoaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    _isLoading = true;
    _modelError = null;
    notifyListeners();
    Interpreter? interpreter;
    try {
      final labels = (await rootBundle.loadString(labelsAsset))
          .split(RegExp(r'\r?\n'))
          .map((label) => label.trim())
          .where((label) => label.isNotEmpty)
          .toList(growable: false);
      if (labels.isEmpty) {
        throw StateError('$labelsAsset is empty.');
      }

      final options = InterpreterOptions()..threads = 4;
      interpreter = await Interpreter.fromAsset(modelAsset, options: options);
      interpreter.allocateTensors();
      final input = interpreter.getInputTensor(0);
      final output = interpreter.getOutputTensor(0);
      final spec = ModelInputSpec.fromShape(input.shape);
      if (spec == null || input.type != TensorType.float32) {
        throw StateError(
          'Unsupported model input tensor: shape=${input.shape}, '
          'type=${input.type}. Expected float32 [1,3,H,W] or [1,H,W,3].',
        );
      }
      final channels = labels.length + 4;
      if (output.type != TensorType.float32 ||
          output.shape.length != 3 ||
          (output.shape[1] != channels && output.shape[2] != channels)) {
        throw StateError(
          'Model output ${output.shape} (${output.type}) does not match '
          '${labels.length} labels (expected ${labels.length} + 4 channels).',
        );
      }

      _labels = labels;
      _inputSpec = spec;
      _outputShape = List<int>.from(output.shape);
      _interpreter = interpreter;

      try {
        _worker = await _DetectionWorker.start(
          address: interpreter.address,
          inputShape: List<int>.from(input.shape),
          outputShape: _outputShape,
          numClasses: labels.length,
        );
      } catch (error) {
        // Inference still works on the main isolate, only slower.
        debugPrint('Detection worker unavailable, using main isolate: $error');
        _worker = null;
      }
    } catch (error) {
      interpreter?.close();
      _interpreter = null;
      _inputSpec = null;
      _modelError = 'Could not load on-device object model: $error';
      debugPrint(_modelError);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _ensureModel() async {
    await initialize();
    if (!isModelLoaded) {
      throw StateError(_modelError ?? 'The object detection model is not loaded.');
    }
  }

  Map<String, Object?> _thresholds(DetectionSettings settings) => {
        'conf': settings.minimumConfidence,
        'iou': settings.iouThreshold,
        'maxDet': settings.maximumDetections,
      };

  Future<DetectionOutcome> _run(Map<String, Object?> job) async {
    await _ensureModel();
    final worker = _worker;
    final Map<Object?, Object?> reply;
    if (worker != null) {
      reply = await worker.run(job);
    } else {
      reply = runDetectionJob(
        _interpreter!,
        _inputSpec!,
        _outputShape,
        _labels.length,
        job,
      );
    }
    return _toOutcome(reply);
  }

  DetectionOutcome _toOutcome(Map<Object?, Object?> reply) {
    final packed = reply['dets'] as Float64List;
    final results = <DetectionResult>[];
    for (var i = 0; i + 5 < packed.length; i += 6) {
      final classIndex = packed[i].toInt();
      final label = classIndex >= 0 && classIndex < _labels.length
          ? _labels[classIndex]
          : 'class $classIndex';
      results.add(DetectionResult(
        label: label,
        confidence: packed[i + 1],
        boundingBox: Rect.fromLTRB(
          packed[i + 2],
          packed[i + 3],
          packed[i + 4],
          packed[i + 5],
        ),
        isHazard: kHazardLabels.contains(label.toLowerCase()),
      ));
    }
    return DetectionOutcome(
      results: results,
      imageWidth: reply['width'] as int,
      imageHeight: reply['height'] as int,
      preprocessMs: (reply['pre'] as num).toDouble(),
      inferenceMs: (reply['inf'] as num).toDouble(),
      postprocessMs: (reply['post'] as num).toDouble(),
    );
  }

  /// Runs detection on an encoded image (JPEG/PNG/...). EXIF orientation is
  /// applied so boxes line up with how the photo is displayed.
  Future<DetectionOutcome> detectImage(
    Uint8List bytes, {
    DetectionSettings settings = const DetectionSettings(),
  }) {
    if (bytes.isEmpty) {
      throw const FormatException('The selected file is empty.');
    }
    return _run({
      'kind': 'encoded',
      'bytes': bytes,
      ..._thresholds(settings),
    });
  }

  /// Runs detection on a live camera frame.
  Future<DetectionOutcome> detectCameraFrame(
    CameraFrameData frame, {
    DetectionSettings settings = const DetectionSettings(),
  }) {
    if (!frame.isSupported) {
      throw UnsupportedError('Unsupported camera frame format: ${frame.format}');
    }
    return _run({
      'kind': frame.format,
      'width': frame.width,
      'height': frame.height,
      'rotation': frame.rotation,
      'planes': frame.planes,
      'rowStrides': frame.rowStrides,
      'pixelStrides': frame.pixelStrides,
      ..._thresholds(settings),
    });
  }

  /// Backwards-compatible helper used by older call sites.
  Future<List<DetectionResult>> detectObjects(
    Uint8List bytes, {
    DetectionSettings settings = const DetectionSettings(),
  }) async {
    final outcome = await detectImage(bytes, settings: settings);
    return outcome.results;
  }

  // ---------------------------------------------------------------- OCR ---

  Future<String> recognizeTextFromFile(String path) async {
    final recognized = await _textRecognizer.processImage(
      InputImage.fromFilePath(path),
    );
    return recognized.text;
  }

  Future<String> recognizeTextFromBytes(Uint8List bytes) async {
    final file = await _writeTemporaryImage(bytes, 'ocr');
    try {
      return await recognizeTextFromFile(file.path);
    } finally {
      await _deleteQuietly(file);
    }
  }

  Future<List<Face>> detectFacesFromBytes(Uint8List bytes) async {
    final file = await _writeTemporaryImage(bytes, 'face-detection');
    try {
      return await _faceDetector.processImage(
        InputImage.fromFilePath(file.path),
      );
    } finally {
      await _deleteQuietly(file);
    }
  }

  Future<Map<String, dynamic>> recognizeTextFromVideo(
    String path, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final durationMs = await videoDurationMs(path);
    final lines = <String>[];
    final seen = <String>{};
    final timeline = <Map<String, dynamic>>[];
    var framesProcessed = 0;
    for (var timeMs = 0;
        timeMs < durationMs && framesProcessed < 600;
        timeMs += 1000) {
      if (isCancelled?.call() ?? false) break;
      final bytes = await videoFrame(path, timeMs);
      onProgress?.call(durationMs == 0 ? 1 : timeMs / durationMs);
      if (bytes == null) continue;
      final text = await recognizeTextFromBytes(bytes);
      framesProcessed++;
      final uniqueLines = <String>[];
      for (final line in text.split('\n').map((value) => value.trim())) {
        if (line.isEmpty || !seen.add(line.toLowerCase())) continue;
        lines.add(line);
        uniqueLines.add(line);
      }
      if (uniqueLines.isNotEmpty) {
        timeline.add({
          'seconds': timeMs / 1000,
          'timestamp': formatTimestamp(timeMs),
          'text': uniqueLines.join('\n'),
        });
      }
    }
    if (framesProcessed == 0) {
      throw StateError('No frames could be extracted from this video.');
    }
    return {
      'full_text': lines.join('\n'),
      'timeline': timeline,
      'total_frames_processed': framesProcessed,
      'truncated': durationMs > 600000,
      'cancelled': isCancelled?.call() ?? false,
    };
  }

  // ------------------------------------------------------- video review ---

  /// Samples the video and runs the object model on each sampled frame.
  /// An empty [targetObject] keeps every detected class.
  Future<Map<String, dynamic>> reviewVideo({
    required String path,
    required String targetObject,
    required DetectionSettings settings,
    int samplesPerSecond = 1,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await _ensureModel();
    final durationMs = await videoDurationMs(path);
    final stepMs = (1000 / samplesPerSecond.clamp(1, 5)).round();
    const maxFrames = 600;
    final target = targetObject.trim().toLowerCase();
    final timeline = <Map<String, dynamic>>[];
    final classCounts = <String, int>{};
    var framesProcessed = 0;
    var detectionsCount = 0;
    var inferenceMs = 0.0;
    var cancelled = false;
    for (var timeMs = 0;
        timeMs < durationMs && framesProcessed < maxFrames;
        timeMs += stepMs) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final bytes = await videoFrame(path, timeMs);
      onProgress?.call(durationMs == 0 ? 1 : timeMs / durationMs);
      if (bytes == null) continue;
      final outcome = await detectImage(bytes, settings: settings);
      framesProcessed++;
      inferenceMs += outcome.inferenceMs;
      final matching = outcome.results
          .where((item) => target.isEmpty || item.label.toLowerCase() == target)
          .toList();
      if (matching.isEmpty) continue;
      detectionsCount += matching.length;
      for (final item in matching) {
        classCounts.update(item.label, (v) => v + 1, ifAbsent: () => 1);
      }
      timeline.add({
        'seconds': timeMs / 1000,
        'timestamp': formatTimestamp(timeMs),
        'detections': matching
            .map(
              (item) => {
                'label': item.label,
                'confidence': item.confidence,
                'rect': {
                  'left': item.boundingBox.left,
                  'top': item.boundingBox.top,
                  'right': item.boundingBox.right,
                  'bottom': item.boundingBox.bottom,
                },
              },
            )
            .toList(),
      });
    }
    onProgress?.call(1);
    if (framesProcessed == 0) {
      throw StateError('No frames could be extracted from this video.');
    }
    return {
      'target': target.isEmpty ? 'all objects' : target,
      'timeline': timeline,
      'total_events': timeline.length,
      'total_detections': detectionsCount,
      'total_frames_processed': framesProcessed,
      'frames_with_target': timeline.length,
      'presence_percent': framesProcessed == 0
          ? 0.0
          : timeline.length * 100.0 / framesProcessed,
      'class_counts': classCounts,
      'samples_per_second': 1000 / stepMs,
      'duration_seconds': durationMs / 1000,
      'average_inference_ms':
          framesProcessed == 0 ? 0.0 : inferenceMs / framesProcessed,
      'truncated': timeMsLimitReached(durationMs, stepMs, maxFrames),
      'cancelled': cancelled,
    };
  }

  static bool timeMsLimitReached(int durationMs, int stepMs, int maxFrames) =>
      durationMs > stepMs * maxFrames;

  // --------------------------------------------------------- drowsiness ---

  DrowsinessTracker get drowsinessTracker => _drowsiness;

  void resetDrowsinessSession() => _drowsiness.reset();

  /// Analyses one live front-camera frame with ML Kit (eye-open probability)
  /// and updates the time-based drowsiness tracker.
  Future<Map<String, dynamic>> analyzeDrowsinessFrame(
    CameraFrameData frame, {
    required double closedEyeProbabilityThreshold,
    required double closedSecondsThreshold,
  }) async {
    final InputImage input;
    if (frame.format == 'yuv420') {
      input = InputImage.fromBytes(
        bytes: frame.toNv21(),
        metadata: InputImageMetadata(
          size: Size(frame.width.toDouble(), frame.height.toDouble()),
          rotation: InputImageRotationValue.fromRawValue(frame.rotation) ??
              InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: frame.width,
        ),
      );
    } else if (frame.format == 'bgra8888') {
      input = InputImage.fromBytes(
        bytes: frame.planes.first,
        metadata: InputImageMetadata(
          size: Size(frame.width.toDouble(), frame.height.toDouble()),
          rotation: InputImageRotationValue.fromRawValue(frame.rotation) ??
              InputImageRotation.rotation0deg,
          format: InputImageFormat.bgra8888,
          bytesPerRow: frame.rowStrides.first,
        ),
      );
    } else {
      throw UnsupportedError('Unsupported camera frame format ${frame.format}');
    }
    final faces = await _liveFaceDetector.processImage(input);
    return _drowsiness.update(
      timeMs: DateTime.now().millisecondsSinceEpoch,
      eyeOpenProbability: _eyeOpenProbability(faces),
      faceDetected: faces.isNotEmpty,
      closedEyeProbabilityThreshold: closedEyeProbabilityThreshold,
      closedSecondsThreshold: closedSecondsThreshold,
    );
  }

  /// Analyses a still image (used for video sampling).
  Future<Map<String, dynamic>> analyzeDrowsinessImage(
    Uint8List bytes, {
    required int timeMs,
    required double closedEyeProbabilityThreshold,
    required double closedSecondsThreshold,
  }) async {
    final faces = await detectFacesFromBytes(bytes);
    return _drowsiness.update(
      timeMs: timeMs,
      eyeOpenProbability: _eyeOpenProbability(faces),
      faceDetected: faces.isNotEmpty,
      closedEyeProbabilityThreshold: closedEyeProbabilityThreshold,
      closedSecondsThreshold: closedSecondsThreshold,
    );
  }

  double? _eyeOpenProbability(List<Face> faces) {
    if (faces.isEmpty) return null;
    // Use the largest face (closest to the camera).
    final face = faces.reduce((a, b) =>
        a.boundingBox.width * a.boundingBox.height >=
                b.boundingBox.width * b.boundingBox.height
            ? a
            : b);
    final probabilities = [
      face.leftEyeOpenProbability,
      face.rightEyeOpenProbability,
    ].whereType<double>().toList();
    if (probabilities.isEmpty) return null;
    return probabilities.reduce((a, b) => a + b) / probabilities.length;
  }

  Future<Map<String, dynamic>> analyzeDrowsinessVideo({
    required String path,
    required double closedEyeProbabilityThreshold,
    required double closedSecondsThreshold,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    resetDrowsinessSession();
    final durationMs = await videoDurationMs(path);
    const stepMs = 500;
    const maxFrames = 1200;
    final incidents = <Map<String, dynamic>>[];
    var framesProcessed = 0;
    var framesWithFace = 0;
    var wasDrowsy = false;
    for (var timeMs = 0;
        timeMs < durationMs && framesProcessed < maxFrames;
        timeMs += stepMs) {
      if (isCancelled?.call() ?? false) break;
      final bytes = await videoFrame(path, timeMs);
      onProgress?.call(durationMs == 0 ? 1 : timeMs / durationMs);
      if (bytes == null) continue;
      final result = await analyzeDrowsinessImage(
        bytes,
        timeMs: timeMs,
        closedEyeProbabilityThreshold: closedEyeProbabilityThreshold,
        closedSecondsThreshold: closedSecondsThreshold,
      );
      framesProcessed++;
      if (result['face_detected'] == true) framesWithFace++;
      final drowsy = result['drowsy'] == true;
      if (drowsy && !wasDrowsy) {
        incidents.add({
          'timestamp': formatTimestamp(timeMs),
          'seconds': timeMs / 1000,
          'eye_open_probability': result['eye_open_probability'],
        });
      }
      wasDrowsy = drowsy;
    }
    onProgress?.call(1);
    if (framesProcessed == 0) {
      throw StateError('No frames could be extracted from this video.');
    }
    return {
      'incidents': incidents,
      'total_incidents': incidents.length,
      'frames_analyzed': framesProcessed,
      'frames_with_face': framesWithFace,
      'sample_interval_ms': stepMs,
      'truncated': durationMs > stepMs * maxFrames,
    };
  }

  // -------------------------------------------------------------- video ---

  Future<int> videoDurationMs(String path) async {
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      final duration = controller.value.duration.inMilliseconds;
      if (duration <= 0) {
        throw StateError('The video has no readable duration.');
      }
      return duration;
    } finally {
      await controller.dispose();
    }
  }

  Future<Uint8List?> videoFrame(String path, int timeMs) {
    return const MethodChannel('com.smartvision/video_frames')
        .invokeMethod<Uint8List>(
      'getFrame',
      {
        'path': path,
        'timeMs': timeMs,
        'maxWidth': 640,
        'quality': 85,
      },
    );
  }

  static String formatTimestamp(int milliseconds) {
    final totalSeconds = milliseconds ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------- text utilities ---

  /// Extractive summary, same algorithm as POST /summarize in ai_server.py.
  String summarizeText(String text, {int maxSentences = 3}) {
    final clean = text.trim();
    if (clean.isEmpty) return '';
    final sentences = clean
        .split(RegExp(r'(?<=[.!?])\s+|\n+'))
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.length > 10)
        .toList();
    if (sentences.isEmpty) return clean;
    if (sentences.length <= maxSentences) return sentences.join(' ');

    final wordPattern = RegExp(r'\b[a-zA-Z]{3,}\b');
    final frequencies = <String, int>{};
    for (final match in wordPattern.allMatches(clean.toLowerCase())) {
      final word = match.group(0)!;
      frequencies.update(word, (count) => count + 1, ifAbsent: () => 1);
    }
    final scored = <({int index, double score})>[];
    for (var index = 0; index < sentences.length; index++) {
      final words = wordPattern
          .allMatches(sentences[index].toLowerCase())
          .map((m) => m.group(0)!)
          .toList();
      var score = words.isEmpty
          ? 0.0
          : words.fold<int>(0, (sum, w) => sum + (frequencies[w] ?? 0)) /
              words.length;
      if (index == 0) score *= 1.3;
      if (index == sentences.length - 1) score *= 1.2;
      scored.add((index: index, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final selected =
        scored.take(maxSentences).map((item) => item.index).toList()..sort();
    return selected.map((index) => sentences[index]).join(' ');
  }

  Future<String> translateText({
    required String text,
    required String targetLanguage,
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'Text must not be empty.');
    }
    final target = _translateLanguage(targetLanguage);
    if (target == null) {
      throw UnsupportedError(
        'On-device translation does not support $targetLanguage.',
      );
    }
    final identifier = LanguageIdentifier(confidenceThreshold: 0.5);
    String sourceCode;
    try {
      sourceCode = await identifier.identifyLanguage(text);
    } finally {
      await identifier.close();
    }
    final source = BCP47Code.fromRawValue(sourceCode);
    if (source == null) {
      throw StateError(
        'Could not identify the source language (detected "$sourceCode").',
      );
    }
    if (source == target) return text;

    final manager = OnDeviceTranslatorModelManager();
    final sourceReady = await manager.downloadModel(
      source.bcpCode,
      isWifiRequired: false,
    );
    final targetReady = await manager.downloadModel(
      target.bcpCode,
      isWifiRequired: false,
    );
    if (!sourceReady || !targetReady) {
      throw StateError(
        'Required on-device translation models are unavailable. '
        'Connect to the internet once so ML Kit can download them.',
      );
    }
    final translator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
    try {
      return await translator.translateText(text);
    } finally {
      await translator.close();
    }
  }

  TranslateLanguage? _translateLanguage(String name) {
    final normalized = name.trim().toLowerCase();
    final aliases = <String, String>{
      'chinese (simplified)': 'chinese',
      'hindi': 'hindi',
      'kannada': 'kannada',
      'telugu': 'telugu',
      'tamil': 'tamil',
      'marathi': 'marathi',
      'bengali': 'bengali',
      'gujarati': 'gujarati',
      'spanish': 'spanish',
      'french': 'french',
      'german': 'german',
      'japanese': 'japanese',
      'russian': 'russian',
      'arabic': 'arabic',
    };
    final language = aliases[normalized];
    if (language == null) return null;
    for (final value in TranslateLanguage.values) {
      if (value.name == language) return value;
    }
    return null;
  }

  Future<File> _writeTemporaryImage(Uint8List bytes, String prefix) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/$prefix-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temporary files are cleaned by the OS eventually.
    }
  }

  @override
  void dispose() {
    _worker?.close();
    _interpreter?.close();
    _textRecognizer.close();
    _faceDetector.close();
    _liveFaceDetector.close();
    super.dispose();
  }
}

/// Time-based drowsiness logic: eyes must stay closed for at least
/// [closedSecondsThreshold] seconds before an alert is raised.
class DrowsinessTracker {
  int? _closedSinceMs;
  int _incidents = 0;
  bool _wasDrowsy = false;

  int get incidents => _incidents;

  void reset() {
    _closedSinceMs = null;
    _incidents = 0;
    _wasDrowsy = false;
  }

  Map<String, dynamic> update({
    required int timeMs,
    required double? eyeOpenProbability,
    required bool faceDetected,
    required double closedEyeProbabilityThreshold,
    required double closedSecondsThreshold,
  }) {
    if (!faceDetected || eyeOpenProbability == null) {
      _closedSinceMs = null;
      _wasDrowsy = false;
      return {
        'face_detected': faceDetected,
        'eye_open_probability': eyeOpenProbability,
        'eyes_closed': false,
        'closed_seconds': 0.0,
        'drowsy': false,
        'incidents': _incidents,
      };
    }
    final eyesClosed = eyeOpenProbability < closedEyeProbabilityThreshold;
    if (eyesClosed) {
      _closedSinceMs ??= timeMs;
    } else {
      _closedSinceMs = null;
    }
    final closedSeconds =
        _closedSinceMs == null ? 0.0 : (timeMs - _closedSinceMs!) / 1000;
    final drowsy = eyesClosed && closedSeconds >= closedSecondsThreshold;
    if (drowsy && !_wasDrowsy) _incidents++;
    _wasDrowsy = drowsy;
    return {
      'face_detected': true,
      'eye_open_probability': eyeOpenProbability,
      'eyes_closed': eyesClosed,
      'closed_seconds': closedSeconds,
      'drowsy': drowsy,
      'incidents': _incidents,
    };
  }
}

// ------------------------------------------------------------------------
// Background isolate that owns a second handle to the same TFLite interpreter
// (via its native address) and does decoding, pre-processing, inference and
// post-processing off the UI thread.
// ------------------------------------------------------------------------

class _DetectionWorker {
  _DetectionWorker._();

  final ReceivePort _receivePort = ReceivePort();
  final Map<int, Completer<Map<Object?, Object?>>> _pending = {};
  final Completer<SendPort> _ready = Completer<SendPort>();
  Isolate? _isolate;
  SendPort? _sendPort;
  int _nextId = 0;

  static Future<_DetectionWorker> start({
    required int address,
    required List<int> inputShape,
    required List<int> outputShape,
    required int numClasses,
  }) async {
    final worker = _DetectionWorker._();
    worker._receivePort.listen(worker._onMessage);
    worker._isolate = await Isolate.spawn<List<Object?>>(
      detectionWorkerMain,
      <Object?>[
        worker._receivePort.sendPort,
        address,
        inputShape,
        outputShape,
        numClasses,
      ],
      debugName: 'smartvision-detection',
      onError: worker._receivePort.sendPort,
    );
    worker._sendPort =
        await worker._ready.future.timeout(const Duration(seconds: 10));
    return worker;
  }

  void _onMessage(dynamic message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    // Uncaught isolate errors arrive as [error, stackTrace] strings.
    if (message is List && message.length == 2 && message.first is String) {
      final error = StateError('Detection worker crashed: ${message.first}');
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final completer in _pending.values) {
        completer.completeError(error);
      }
      _pending.clear();
      _sendPort = null;
      return;
    }
    if (message is Map) {
      final id = message['id'];
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (message['ok'] == true) {
        completer.complete(message);
      } else {
        completer.completeError(
          StateError(message['error']?.toString() ?? 'Detection failed.'),
        );
      }
    }
  }

  Future<Map<Object?, Object?>> run(Map<String, Object?> job) {
    final sendPort = _sendPort;
    if (sendPort == null) {
      return Future.error(StateError('Detection worker is not running.'));
    }
    final id = _nextId++;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    sendPort.send(<String, Object?>{...job, 'id': id});
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Object detection timed out.');
      },
    );
  }

  void close() {
    _sendPort?.send(const <String, Object?>{'close': true});
    _receivePort.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    for (final completer in _pending.values) {
      completer.completeError(StateError('Detection worker closed.'));
    }
    _pending.clear();
  }
}

/// Isolate entry point. Must be a top-level function.
@pragma('vm:entry-point')
void detectionWorkerMain(List<Object?> init) {
  final mainPort = init[0] as SendPort;
  final address = init[1] as int;
  final inputShape = (init[2] as List).cast<int>();
  final outputShape = (init[3] as List).cast<int>();
  final numClasses = init[4] as int;
  final interpreter = Interpreter.fromAddress(address, allocated: true);
  final spec = ModelInputSpec.fromShape(inputShape)!;
  final port = ReceivePort();
  mainPort.send(port.sendPort);
  port.listen((dynamic message) {
    if (message is! Map) return;
    if (message['close'] == true) {
      port.close();
      return;
    }
    final id = message['id'];
    try {
      final reply =
          runDetectionJob(interpreter, spec, outputShape, numClasses, message);
      reply['id'] = id;
      mainPort.send(reply);
    } catch (error) {
      mainPort.send(<String, Object?>{
        'id': id,
        'ok': false,
        'error': error.toString(),
      });
    }
  });
}

/// Decodes/pre-processes the job input, runs the interpreter and decodes the
/// YOLO output. Runs in the worker isolate (or the main isolate as fallback).
Map<Object?, Object?> runDetectionJob(
  Interpreter interpreter,
  ModelInputSpec spec,
  List<int> outputShape,
  int numClasses,
  Map<Object?, Object?> job,
) {
  final stopwatch = Stopwatch()..start();
  final kind = job['kind'] as String;
  final Float32List input;
  final int width;
  final int height;
  final Letterbox letterbox;

  if (kind == 'encoded') {
    final decoded = img.decodeImage(job['bytes'] as Uint8List);
    if (decoded == null) {
      throw const FormatException(
          'The image could not be decoded (unsupported or corrupt file).');
    }
    final upright = img.bakeOrientation(decoded);
    width = upright.width;
    height = upright.height;
    var working = upright;
    const maxSide = 1280;
    final longest = width > height ? width : height;
    if (longest > maxSide) {
      final factor = maxSide / longest;
      working = img.copyResize(
        upright,
        width: (width * factor).round(),
        height: (height * factor).round(),
        interpolation: img.Interpolation.linear,
      );
    }
    letterbox =
        Letterbox.compute(working.width, working.height, spec.width, spec.height);
    input = letterboxRgba(
      rgba: working.getBytes(),
      width: working.width,
      height: working.height,
      spec: spec,
      letterbox: letterbox,
    );
  } else if (kind == 'yuv420' || kind == 'bgra8888') {
    final sensorWidth = job['width'] as int;
    final sensorHeight = job['height'] as int;
    final rotation = job['rotation'] as int;
    final planes = (job['planes'] as List).cast<Uint8List>();
    final rowStrides = (job['rowStrides'] as List).cast<int>();
    final pixelStrides = (job['pixelStrides'] as List).cast<int>();
    final upright = uprightSize(sensorWidth, sensorHeight, rotation);
    width = upright.width;
    height = upright.height;
    letterbox = Letterbox.compute(width, height, spec.width, spec.height);
    if (kind == 'yuv420') {
      input = letterboxYuv420(
        yPlane: planes[0],
        uPlane: planes[1],
        vPlane: planes[2],
        yRowStride: rowStrides[0],
        uvRowStride: rowStrides[1],
        uvPixelStride: pixelStrides[1],
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight,
        rotation: rotation,
        spec: spec,
        letterbox: letterbox,
      );
    } else {
      input = letterboxBgra(
        bgra: planes[0],
        rowStride: rowStrides[0],
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight,
        rotation: rotation,
        spec: spec,
        letterbox: letterbox,
      );
    }
  } else {
    throw UnsupportedError('Unsupported detection input "$kind".');
  }
  final preprocessMs = stopwatch.elapsedMicroseconds / 1000;

  stopwatch.reset();
  final outputElements = outputShape.fold<int>(1, (a, b) => a * b);
  final outputBytes = Uint8List(outputElements * 4);
  interpreter.run(
    input.buffer.asUint8List(input.offsetInBytes, input.lengthInBytes),
    outputBytes,
  );
  final inferenceMs = stopwatch.elapsedMicroseconds / 1000;

  stopwatch.reset();
  final detections = decodeYoloOutput(
    output: outputBytes.buffer.asFloat32List(0, outputElements),
    shape: outputShape,
    numClasses: numClasses,
    letterbox: letterbox,
    confidenceThreshold: (job['conf'] as num).toDouble(),
    iouThreshold: (job['iou'] as num).toDouble(),
    maxDetections: (job['maxDet'] as num).toInt(),
  );
  final packed = Float64List(detections.length * 6);
  for (var i = 0; i < detections.length; i++) {
    final d = detections[i];
    packed[i * 6] = d.classIndex.toDouble();
    packed[i * 6 + 1] = d.score;
    packed[i * 6 + 2] = d.left;
    packed[i * 6 + 3] = d.top;
    packed[i * 6 + 4] = d.right;
    packed[i * 6 + 5] = d.bottom;
  }
  final postprocessMs = stopwatch.elapsedMicroseconds / 1000;
  return <Object?, Object?>{
    'ok': true,
    'width': width,
    'height': height,
    'dets': packed,
    'pre': preprocessMs,
    'inf': inferenceMs,
    'post': postprocessMs,
  };
}
