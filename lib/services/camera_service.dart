import 'dart:developer';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

enum CameraPermissionStatus { granted, denied, permanentlyDenied, undetermined }

/// Owns the single device camera. Screens "acquire" it while visible and
/// "release" it when they go away, so the camera is only open while needed,
/// and it is closed/reopened automatically when the app is backgrounded.
class CameraService extends ChangeNotifier with WidgetsBindingObserver {
  CameraService() {
    WidgetsBinding.instance.addObserver(this);
  }

  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;

  bool _isInitialized = false;
  bool _isInitializing = false;
  CameraPermissionStatus _permissionStatus =
      CameraPermissionStatus.undetermined;
  double _currentZoomLevel = 1.0;
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  bool _isFlashOn = false;
  Future<void>? _initialization;
  String? _initializationError;
  final Set<Object> _owners = {};
  void Function(CameraImage image)? _streamListener;
  bool _isStreaming = false;
  bool _pausedByLifecycle = false;
  bool _disposed = false;

  CameraController? get controller => _controller;
  bool get isInitialized =>
      _isInitialized && (_controller?.value.isInitialized ?? false);
  bool get isInitializing => _isInitializing;
  CameraPermissionStatus get permissionStatus => _permissionStatus;
  double get minZoomLevel => _minZoomLevel;
  double get maxZoomLevel => _maxZoomLevel;
  double get currentZoomLevel => _currentZoomLevel;
  bool get isFlashOn => _isFlashOn;
  String? get initializationError => _initializationError;
  bool get isStreaming => _isStreaming;
  List<CameraDescription> get cameras => List.unmodifiable(_cameras);
  int get selectedCameraIndex => _selectedCameraIndex;
  CameraDescription? get description =>
      _cameras.isEmpty ? null : _cameras[_selectedCameraIndex];

  /// Clockwise rotation that makes stream frames upright (UI is portrait).
  int get frameRotation => description?.sensorOrientation ?? 90;
  bool get isFrontCamera =>
      description?.lensDirection == CameraLensDirection.front;

  /// Preview size as the user sees it in portrait (width < height).
  Size? get uprightPreviewSize {
    final size = _controller?.value.previewSize;
    if (size == null) return null;
    final rotated = frameRotation == 90 || frameRotation == 270;
    return rotated ? Size(size.height, size.width) : size;
  }

  static String describeCamera(CameraDescription camera, int index) {
    switch (camera.lensDirection) {
      case CameraLensDirection.back:
        return 'Back camera${index > 0 ? ' ${index + 1}' : ''}';
      case CameraLensDirection.front:
        return 'Front camera';
      case CameraLensDirection.external:
        return 'External camera';
    }
  }

  /// Registers [owner] as a user of the camera and opens it if necessary.
  Future<void> acquire(
    Object owner, {
    CameraLensDirection? preferredLens,
  }) async {
    _owners.add(owner);
    // Each screen opens with its natural lens: back camera for detection,
    // front camera for the drowsiness monitor.
    _preferredLens = preferredLens ?? CameraLensDirection.back;
    await initialize();
  }

  CameraLensDirection? _preferredLens;

  /// Unregisters [owner]; the camera closes once nobody uses it.
  Future<void> release(Object owner) async {
    _owners.remove(owner);
    // Give a newly opened screen a moment to acquire before closing.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (_owners.isEmpty && !_disposed) {
      await _closeController();
    }
  }

  Future<void> initialize() {
    if (isInitialized) {
      return _maybeSwitchToPreferredLens();
    }
    final existingInitialization = _initialization;
    if (existingInitialization != null) return existingInitialization;
    final initialization = _initialize();
    _initialization = initialization;
    return initialization.whenComplete(() => _initialization = null);
  }

  Future<void> _maybeSwitchToPreferredLens() async {
    final preferred = _preferredLens;
    if (preferred == null || _cameras.isEmpty) return;
    if (description?.lensDirection == preferred) return;
    final index = _cameras.indexWhere((c) => c.lensDirection == preferred);
    if (index >= 0) await selectCamera(index);
  }

  Future<void> _initialize() async {
    _isInitializing = true;
    notifyListeners();
    try {
      await checkPermission();
      if (_permissionStatus != CameraPermissionStatus.granted &&
          _permissionStatus != CameraPermissionStatus.permanentlyDenied) {
        // Not yet granted (first launch reports "denied" on Android): ask.
        final status = await Permission.camera.request();
        _updatePermissionStatus(status);
      }
      if (_permissionStatus == CameraPermissionStatus.granted) {
        await _initCamera();
      }
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  Future<void> checkPermission() async {
    final status = await Permission.camera.status;
    _updatePermissionStatus(status);
  }

  Future<void> requestPermission() async {
    final status = await Permission.camera.request();
    _updatePermissionStatus(status);
    if (status.isGranted) {
      await initialize();
    }
  }

  void _updatePermissionStatus(PermissionStatus status) {
    if (status.isGranted || status.isLimited) {
      _permissionStatus = CameraPermissionStatus.granted;
    } else if (status.isPermanentlyDenied || status.isRestricted) {
      _permissionStatus = CameraPermissionStatus.permanentlyDenied;
    } else {
      _permissionStatus = CameraPermissionStatus.denied;
    }
    notifyListeners();
  }

  Future<void> _initCamera() async {
    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        _initializationError = 'No camera was found on this device.';
        notifyListeners();
        return;
      }
      final preferred = _preferredLens;
      if (preferred != null) {
        final index = _cameras.indexWhere((c) => c.lensDirection == preferred);
        if (index >= 0) _selectedCameraIndex = index;
      }
      if (_selectedCameraIndex >= _cameras.length) _selectedCameraIndex = 0;
      await _setupCameraController(_cameras[_selectedCameraIndex]);
    } catch (e) {
      _initializationError = e.toString();
      log('Error initializing camera: $e');
      notifyListeners();
    }
  }

  Future<void> _setupCameraController(
      CameraDescription cameraDescription) async {
    await _closeController(notify: false);

    final controller = CameraController(
      cameraDescription,
      // Medium keeps live inference fast (e.g. 720x480 on most Android
      // phones); the model input is only 320x320.
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    _controller = controller;

    try {
      await controller.initialize();
      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (e) {
        log('Could not lock capture orientation: $e');
      }
      _minZoomLevel = await controller.getMinZoomLevel();
      _maxZoomLevel = await controller.getMaxZoomLevel();
      _currentZoomLevel = _minZoomLevel;
      _isFlashOn = false;
      _isInitialized = true;
      _initializationError = null;
      notifyListeners();
      final listener = _streamListener;
      if (listener != null) {
        await _startStream(listener);
      }
    } on CameraException catch (e) {
      _initializationError = _describeCameraException(e);
      log('Error setting up camera controller: $e');
      _isInitialized = false;
      notifyListeners();
    } catch (e) {
      _initializationError = e.toString();
      log('Error setting up camera controller: $e');
      _isInitialized = false;
      notifyListeners();
    }
  }

  String _describeCameraException(CameraException e) {
    switch (e.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
      case 'CameraAccessRestricted':
        _permissionStatus = CameraPermissionStatus.permanentlyDenied;
        return 'Camera access was denied. Enable it in system settings.';
      default:
        return 'Camera error (${e.code}): ${e.description ?? 'unknown'}';
    }
  }

  Future<void> _closeController({bool notify = true}) async {
    final controller = _controller;
    _controller = null;
    _isInitialized = false;
    _isStreaming = false;
    if (controller != null && !_disposed) {
      // Remove CameraPreview from the tree before the controller is disposed,
      // otherwise a frame rendered in between would use a disposed controller.
      notifyListeners();
      // Frames are not produced while the app is paused, so never wait long.
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (e) {
        log('Error stopping image stream: $e');
      }
      try {
        await controller.dispose();
      } catch (e) {
        log('Error disposing camera: $e');
      }
    }
    if (notify && !_disposed) notifyListeners();
  }

  /// Selects a specific camera (back/front/external) by index.
  Future<void> selectCamera(int index) async {
    if (index < 0 || index >= _cameras.length) return;
    _selectedCameraIndex = index;
    _preferredLens = _cameras[index].lensDirection;
    _isInitialized = false;
    notifyListeners();
    await _setupCameraController(_cameras[index]);
  }

  Future<void> switchCamera() async {
    if (_cameras.length < 2) return;
    await selectCamera((_selectedCameraIndex + 1) % _cameras.length);
  }

  Future<void> toggleFlash() async {
    final controller = _controller;
    if (controller == null || !isInitialized) return;
    try {
      _isFlashOn = !_isFlashOn;
      await controller.setFlashMode(
        _isFlashOn ? FlashMode.torch : FlashMode.off,
      );
      notifyListeners();
    } catch (e) {
      log('Error toggling flash: $e');
      _isFlashOn = !_isFlashOn; // Revert on error
      notifyListeners();
    }
  }

  Future<void> setZoomLevel(double zoom) async {
    final controller = _controller;
    if (controller == null || !isInitialized) return;
    try {
      final clamped = zoom.clamp(_minZoomLevel, _maxZoomLevel).toDouble();
      await controller.setZoomLevel(clamped);
      _currentZoomLevel = clamped;
      notifyListeners();
    } catch (e) {
      log('Error setting zoom level: $e');
    }
  }

  /// Starts delivering preview frames to [onFrame]. The listener survives
  /// camera switches and app pause/resume until [stopImageStream] is called.
  Future<void> startImageStream(void Function(CameraImage image) onFrame) async {
    _streamListener = onFrame;
    if (isInitialized) {
      await _startStream(onFrame);
    }
  }

  Future<void> _startStream(void Function(CameraImage image) onFrame) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) {
      _isStreaming = true;
      return;
    }
    try {
      await controller.startImageStream(onFrame);
      _isStreaming = true;
    } catch (e) {
      _isStreaming = false;
      _initializationError = 'Could not start camera stream: $e';
      log(_initializationError!);
    }
    notifyListeners();
  }

  Future<void> stopImageStream() async {
    _streamListener = null;
    final controller = _controller;
    if (controller != null && controller.value.isStreamingImages) {
      try {
        await controller.stopImageStream();
      } catch (e) {
        log('Error stopping image stream: $e');
      }
    }
    _isStreaming = false;
    if (!_disposed) notifyListeners();
  }

  /// Captures a full-resolution still photo (stops the stream first).
  Future<Uint8List> captureStill() async {
    final controller = _controller;
    if (controller == null || !isInitialized) {
      throw StateError('The camera is not ready.');
    }
    if (controller.value.isStreamingImages) {
      await stopImageStream();
    }
    final file = await controller.takePicture();
    final bytes = await file.readAsBytes();
    try {
      await File(file.path).delete();
    } catch (_) {}
    return bytes;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_controller != null) {
        _pausedByLifecycle = true;
        _closeController();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_pausedByLifecycle && _owners.isNotEmpty) {
        _pausedByLifecycle = false;
        initialize();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }
}
