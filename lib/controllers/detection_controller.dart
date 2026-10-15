import 'dart:convert';
import 'dart:developer';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../models/camera_frame.dart';
import '../models/detection_history.dart';
import '../models/detection_result.dart';
import '../models/detection_settings.dart';
import '../services/alert_sound_service.dart';
import '../services/camera_service.dart';
import '../services/database_service.dart';
import '../services/on_device_ai_service.dart';
import '../services/speech_service.dart';

/// Where the currently displayed detections came from.
enum DetectionSource { none, live, image }

class DetectionController extends ChangeNotifier {
  DetectionController(
    this._cameraService,
    this._speechService,
    this._databaseService,
  ) {
    _loadPersistedSettings();
  }

  static const String _settingsKey = 'detection_settings';
  static const int _maxConsecutiveErrors = 5;

  final CameraService _cameraService;
  final SpeechService _speechService;
  final DatabaseService _databaseService;
  final OnDeviceAiService _aiService = OnDeviceAiService.instance;
  final AlertSoundService _alertSound = AlertSoundService.instance;

  bool _isLive = false;
  bool _isProcessingFrame = false;
  String? _lastAnalysisError;
  int _consecutiveErrors = 0;

  DetectionSource _source = DetectionSource.none;
  DetectionOutcome? _lastOutcome;
  Uint8List? _stillImage;
  bool _lastFrameMirrored = false;
  DateTime? _lastResultAt;

  // Real throughput: completed inferences per second (exponential average).
  double _fps = 0;
  DateTime? _lastFrameDoneAt;

  // Search mode & Target tracking
  String? _searchTarget;
  bool _isTargetFound = false;

  // Hazard / Threat Sentinel
  bool _hasActiveHazard = false;
  String? _activeHazardLabel;
  bool _sirenEnabled = true;

  List<DetectionResult> _currentResults = [];
  final Map<String, int> _objectCounts = {};
  int _totalDetectionsCount = 0;

  /// True while live camera detection is running.
  bool get isDetecting => _isLive;
  bool get isLive => _isLive;
  bool get isProcessingFrame => _isProcessingFrame;
  String? get lastAnalysisError => _lastAnalysisError;
  DetectionSource get source => _source;
  DetectionOutcome? get lastOutcome => _lastOutcome;
  Uint8List? get stillImage => _stillImage;
  bool get lastFrameMirrored => _lastFrameMirrored;
  DateTime? get lastResultAt => _lastResultAt;
  List<DetectionResult> get currentResults => _currentResults;
  Map<String, int> get objectCounts => Map.unmodifiable(_objectCounts);
  int get totalDetectionsCount => _totalDetectionsCount;
  String? get searchTarget => _searchTarget;
  bool get isTargetFound => _isTargetFound;
  bool get hasActiveHazard => _hasActiveHazard;
  String? get activeHazardLabel => _activeHazardLabel;
  bool get sirenEnabled => _sirenEnabled;

  /// Measured live inference rate, or null when not measurable.
  double? get measuredFps => _isLive && _fps > 0 ? _fps : null;

  /// Size of the upright image the current boxes refer to.
  int? get frameWidth => _lastOutcome?.imageWidth;
  int? get frameHeight => _lastOutcome?.imageHeight;

  // Voice Announcement Cooldown
  final Map<String, DateTime> _lastAnnouncedObjects = {};
  final Duration announcementCooldown = const Duration(seconds: 4);

  // Database Save Cooldown
  final Map<String, DateTime> _lastSavedObjects = {};
  final Duration databaseSaveCooldown = const Duration(seconds: 8);

  DetectionSettings _settings = const DetectionSettings();
  DetectionSettings get settings => _settings;

  Future<void> _loadPersistedSettings() async {
    try {
      final raw = await _databaseService.getAppSetting(_settingsKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _settings = DetectionSettings(
        minimumConfidence:
            ((map['confidence'] as num?)?.toDouble() ?? 0.25).clamp(0.05, 0.95).toDouble(),
        iouThreshold:
            ((map['iou'] as num?)?.toDouble() ?? 0.45).clamp(0.1, 0.9).toDouble(),
        maximumDetections:
            ((map['maxDet'] as num?)?.toInt() ?? 100).clamp(1, 300).toInt(),
      );
      _sirenEnabled = map['siren'] as bool? ?? true;
      _alertSound.enabled = _sirenEnabled;
      notifyListeners();
    } catch (error) {
      log('Could not load detection settings: $error');
    }
  }

  Future<void> _persistSettings() async {
    try {
      await _databaseService.setAppSetting(
        _settingsKey,
        jsonEncode({
          'confidence': _settings.minimumConfidence,
          'iou': _settings.iouThreshold,
          'maxDet': _settings.maximumDetections,
          'siren': _sirenEnabled,
        }),
      );
    } catch (error) {
      log('Could not save detection settings: $error');
    }
  }

  /// Validates and applies new thresholds. They are used by every subsequent
  /// inference (live, image and video) and saved on the device.
  void updateSettings(DetectionSettings newSettings) {
    _settings = DetectionSettings(
      minimumConfidence:
          newSettings.minimumConfidence.clamp(0.05, 0.95).toDouble(),
      iouThreshold: newSettings.iouThreshold.clamp(0.1, 0.9).toDouble(),
      maximumDetections: newSettings.maximumDetections.clamp(1, 300).toInt(),
    );
    notifyListeners();
    _persistSettings();
  }

  void setSirenEnabled(bool enabled) {
    _sirenEnabled = enabled;
    _alertSound.enabled = enabled;
    if (!enabled) _alertSound.stop();
    notifyListeners();
    _persistSettings();
  }

  void setSearchTarget(String? target) {
    final clean = target?.trim().toLowerCase();
    if (clean == null || clean.isEmpty) {
      _searchTarget = null;
      _isTargetFound = false;
    } else {
      _searchTarget = clean;
      _isTargetFound = false;
      _speechService.speak('Searching for $_searchTarget');
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- live ---

  /// Starts or stops live detection (kept for older call sites).
  Future<void> toggleDetection() => _isLive ? stopLive() : startLive();

  Future<void> startLive() async {
    if (_isLive) return;
    _isLive = true;
    _consecutiveErrors = 0;
    _lastAnalysisError = null;
    _fps = 0;
    _lastFrameDoneAt = null;
    _stillImage = null;
    _source = DetectionSource.live;
    _currentResults = [];
    _lastOutcome = null;
    notifyListeners();
    await _aiService.initialize();
    if (!_aiService.isModelLoaded) {
      _isLive = false;
      _lastAnalysisError = _aiService.modelError ?? 'Model failed to load.';
      notifyListeners();
      return;
    }
    await _cameraService.startImageStream(_onCameraFrame);
  }

  Future<void> stopLive() async {
    if (!_isLive) return;
    _isLive = false;
    _fps = 0;
    _hasActiveHazard = false;
    _activeHazardLabel = null;
    _isTargetFound = false;
    notifyListeners();
    _speechService.stop();
    await _cameraService.stopImageStream();
  }

  void _onCameraFrame(CameraImage image) {
    if (!_isLive || _isProcessingFrame) return; // drop frames while busy
    _isProcessingFrame = true;
    CameraFrameData? frame;
    try {
      frame = CameraFrameData.fromCameraImage(
        image,
        rotation: _cameraService.frameRotation,
        mirrored: _cameraService.isFrontCamera,
      );
    } catch (error) {
      _isProcessingFrame = false;
      _handleLiveError(error);
    }
    if (frame != null) _processFrame(frame);
  }

  Future<void> _processFrame(CameraFrameData frame) async {
    try {
      final outcome =
          await _aiService.detectCameraFrame(frame, settings: _settings);
      if (!_isLive) return;
      _consecutiveErrors = 0;
      _lastFrameMirrored = frame.mirrored;
      _updateFps();
      _applyOutcome(outcome, DetectionSource.live);
    } catch (error) {
      _handleLiveError(error);
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _handleLiveError(Object error) {
    log('Live detection error: $error');
    _consecutiveErrors++;
    _lastAnalysisError = error.toString();
    if (_consecutiveErrors >= _maxConsecutiveErrors) {
      _lastAnalysisError =
          'Live detection stopped after repeated errors: $error';
      stopLive();
    } else {
      notifyListeners();
    }
  }

  void _updateFps() {
    final now = DateTime.now();
    final last = _lastFrameDoneAt;
    _lastFrameDoneAt = now;
    if (last == null) return;
    final seconds = now.difference(last).inMicroseconds / 1e6;
    if (seconds <= 0) return;
    final instant = 1 / seconds;
    _fps = _fps == 0 ? instant : _fps * 0.8 + instant * 0.2;
  }

  // ------------------------------------------------------------ still ---

  /// Analyses a still image (gallery pick or capture). The image itself is
  /// kept so the boxes are drawn over the frame they belong to.
  Future<DetectionOutcome> analyzeImageBytes(Uint8List bytes) async {
    if (_isLive) await stopLive();
    _isProcessingFrame = true;
    _lastAnalysisError = null;
    _stillImage = bytes;
    _source = DetectionSource.image;
    _currentResults = [];
    _lastOutcome = null;
    notifyListeners();

    try {
      final outcome =
          await _aiService.detectImage(bytes, settings: _settings);
      _lastFrameMirrored = false;
      _applyOutcome(outcome, DetectionSource.image);
      return outcome;
    } catch (error) {
      _lastAnalysisError = error.toString();
      _currentResults = [];
      _objectCounts.clear();
      _totalDetectionsCount = 0;
      _hasActiveHazard = false;
      _activeHazardLabel = null;
      rethrow;
    } finally {
      _isProcessingFrame = false;
      notifyListeners();
    }
  }

  /// Backwards-compatible: returns only the result list.
  Future<List<DetectionResult>> analyzeImageBase64(String base64Image) async {
    final outcome = await analyzeImageBytes(base64Decode(base64Image));
    return outcome.results;
  }

  /// Re-runs the current still image with the latest thresholds.
  Future<void> rerunStillImage() async {
    final bytes = _stillImage;
    if (bytes == null || _isLive) return;
    try {
      await analyzeImageBytes(bytes);
    } catch (_) {
      // Error is exposed through lastAnalysisError.
    }
  }

  void clearStillImage() {
    _stillImage = null;
    if (_source == DetectionSource.image) {
      _source = DetectionSource.none;
      _currentResults = [];
      _lastOutcome = null;
      _objectCounts.clear();
      _totalDetectionsCount = 0;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------- results ---

  void _applyOutcome(DetectionOutcome outcome, DetectionSource source) {
    _lastOutcome = outcome;
    _source = source;
    _lastResultAt = DateTime.now();
    _lastAnalysisError = null;
    _currentResults = outcome.results;
    _updateCounts(outcome.results);
    _checkTargetAndHazards(outcome.results);
    _announceResults(outcome.results);
    _saveResultsToDatabase(outcome.results);
    notifyListeners();
  }

  void _updateCounts(List<DetectionResult> results) {
    _objectCounts.clear();
    for (final r in results) {
      final label = r.label.toLowerCase();
      _objectCounts[label] = (_objectCounts[label] ?? 0) + 1;
    }
    _totalDetectionsCount = results.length;
  }

  void _checkTargetAndHazards(List<DetectionResult> results) {
    final target = _searchTarget;
    if (target != null && target.isNotEmpty) {
      final match = results
          .where((r) => r.label.toLowerCase().contains(target))
          .firstOrNull;
      if (match != null) {
        if (!_isTargetFound) {
          _isTargetFound = true;
          _speechService.speak('Target found! $target detected in scene');
        }
      } else {
        _isTargetFound = false;
      }
    }

    final hazard = results.where((r) => r.isHazard).firstOrNull;
    if (hazard != null) {
      _hasActiveHazard = true;
      _activeHazardLabel = hazard.label;
      _alertSound.playSiren();
      final now = DateTime.now();
      final lastAnnounced = _lastAnnouncedObjects['HAZARD_${hazard.label}'];
      if (lastAnnounced == null ||
          now.difference(lastAnnounced) > const Duration(seconds: 3)) {
        _lastAnnouncedObjects['HAZARD_${hazard.label}'] = now;
        _speechService.speak('Caution! Hazard detected: ${hazard.label}');
      }
    } else {
      _hasActiveHazard = false;
      _activeHazardLabel = null;
    }
  }

  void _announceResults(List<DetectionResult> results) {
    if (results.isEmpty) return;

    final now = DateTime.now();
    for (final result in results) {
      final label = result.label;
      final lastTime = _lastAnnouncedObjects[label];

      if (lastTime == null || now.difference(lastTime) > announcementCooldown) {
        _lastAnnouncedObjects[label] = now;
        _speechService.speak(result.label);
        break; // Announce one object at a time to prevent overlapping speech
      }
    }
  }

  Future<void> _saveResultsToDatabase(List<DetectionResult> results) async {
    if (results.isEmpty) return;

    final now = DateTime.now();
    for (final result in results) {
      final label = result.label;
      final lastTime = _lastSavedObjects[label];

      if (lastTime == null || now.difference(lastTime) > databaseSaveCooldown) {
        _lastSavedObjects[label] = now;
        try {
          await _databaseService.insertDetection(
            DetectionHistory(
              objectName: result.label,
              confidence: result.confidence,
              timestamp: now,
              boundingBox: result.boundingBox,
            ),
          );
        } catch (e) {
          log('Error saving detection to SQLite: $e');
        }
      }
    }
  }

  @override
  void dispose() {
    _isLive = false;
    super.dispose();
  }
}
