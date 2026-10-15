import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_colors.dart';
import '../../models/camera_frame.dart';
import '../../services/alert_sound_service.dart';
import '../../services/camera_service.dart';
import '../../services/database_service.dart';
import '../../services/on_device_ai_service.dart';
import '../../services/speech_service.dart';
import '../../widgets/detection_overlay.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

/// Drowsiness Monitor: front-camera stream → ML Kit eye-open probability →
/// alert when the eyes stay closed longer than the configured duration.
class DrowsinessMonitorScreen extends StatefulWidget {
  const DrowsinessMonitorScreen({super.key});

  @override
  State<DrowsinessMonitorScreen> createState() =>
      _DrowsinessMonitorScreenState();
}

class _DrowsinessMonitorScreenState extends State<DrowsinessMonitorScreen>
    with WidgetsBindingObserver {
  final OnDeviceAiService _aiService = OnDeviceAiService.instance;
  late final CameraService _camera;
  bool _isMonitoring = false;
  bool _frameInFlight = false;
  bool _appInBackground = false;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _closedEyeThreshold = 0.25;
  double _closedSeconds = 1.0;
  String? _error;
  Map<String, dynamic>? _liveResult;
  double _analysedFps = 0;
  DateTime? _lastResultAt;

  bool _isAnalyzingVideo = false;
  bool _videoCancelRequested = false;
  double _videoProgress = 0;
  Map<String, dynamic>? _videoResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _camera = context.read<CameraService>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _camera.acquire(this, preferredLens: CameraLensDirection.front);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final camera = _camera;
    final wasMonitoring = _isMonitoring;
    _isMonitoring = false;
    final owner = this;
    Future.microtask(() async {
      if (wasMonitoring) await camera.stopImageStream();
      await camera.release(owner);
    });
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background = state != AppLifecycleState.resumed;
    if (background != _appInBackground && mounted) {
      setState(() => _appInBackground = background);
    }
  }

  Future<void> _toggleMonitoring() async {
    if (_isMonitoring) {
      setState(() => _isMonitoring = false);
      await _camera.stopImageStream();
      await AlertSoundService.instance.stop();
      return;
    }
    await _camera.acquire(this, preferredLens: CameraLensDirection.front);
    if (!mounted) return;
    if (!_camera.isInitialized) {
      setState(() => _error = _camera.initializationError ??
          'Camera is not ready. Grant camera access and retry.');
      return;
    }
    _aiService.resetDrowsinessSession();
    setState(() {
      _error = null;
      _liveResult = null;
      _analysedFps = 0;
      _isMonitoring = true;
    });
    await _camera.startImageStream(_onFrame);
  }

  void _onFrame(CameraImage image) {
    if (!_isMonitoring || _frameInFlight) return;
    final now = DateTime.now();
    // ~6 analyses per second is enough for eye closure and saves battery.
    if (now.difference(_lastFrameAt) < const Duration(milliseconds: 160)) {
      return;
    }
    _lastFrameAt = now;
    _frameInFlight = true;
    CameraFrameData? frame;
    try {
      frame = CameraFrameData.fromCameraImage(
        image,
        rotation: _camera.frameRotation,
        mirrored: _camera.isFrontCamera,
      );
    } catch (error) {
      _frameInFlight = false;
      _reportError(error);
    }
    if (frame != null) _analyse(frame);
  }

  Future<void> _analyse(CameraFrameData frame) async {
    final speech = context.read<SpeechService>();
    try {
      final result = await _aiService.analyzeDrowsinessFrame(
        frame,
        closedEyeProbabilityThreshold: _closedEyeThreshold,
        closedSecondsThreshold: _closedSeconds,
      );
      if (!mounted || !_isMonitoring) return;
      final wasDrowsy = _liveResult?['drowsy'] == true;
      final now = DateTime.now();
      final last = _lastResultAt;
      if (last != null) {
        final seconds = now.difference(last).inMicroseconds / 1e6;
        if (seconds > 0) {
          final instant = 1 / seconds;
          _analysedFps =
              _analysedFps == 0 ? instant : _analysedFps * 0.8 + instant * 0.2;
        }
      }
      _lastResultAt = now;
      setState(() {
        _liveResult = result;
        _error = null;
      });
      if (result['drowsy'] == true && !wasDrowsy) {
        unawaited(AlertSoundService.instance.playSiren(force: false));
        unawaited(speech.speak('Drowsiness alert. Please take a break.'));
      }
    } catch (error) {
      _reportError(error);
    } finally {
      _frameInFlight = false;
    }
  }

  void _reportError(Object error) {
    if (!mounted) return;
    setState(() => _error = 'Live drowsiness analysis failed: $error');
  }

  Future<void> _analyzeVideo(ImageSource source) async {
    if (_isAnalyzingVideo) return;
    final database = context.read<DatabaseService>();
    try {
      final video = await ImagePicker().pickVideo(source: source);
      if (video == null || !mounted) return;
      if (_isMonitoring) await _toggleMonitoring();
      if (!mounted) return;
      setState(() {
        _isAnalyzingVideo = true;
        _videoCancelRequested = false;
        _videoProgress = 0;
        _videoResult = null;
        _error = null;
      });
      final result = await _aiService.analyzeDrowsinessVideo(
        path: video.path,
        closedEyeProbabilityThreshold: _closedEyeThreshold,
        closedSecondsThreshold: _closedSeconds,
        onProgress: (value) {
          if (mounted) {
            setState(() => _videoProgress = value.clamp(0.0, 1.0).toDouble());
          }
        },
        isCancelled: () => _videoCancelRequested || !mounted,
      );
      try {
        await database.insertAnalysisHistory(
          analysisType: 'Drowsiness Video',
          summary: '${result['total_incidents'] ?? 0} drowsiness alert(s) in '
              '${result['frames_analyzed']} frames',
          details: {'video': video.name, ...result},
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() => _videoResult = result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Video drowsiness analysis failed: $error');
    } finally {
      if (mounted) setState(() => _isAnalyzingVideo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final camera = context.watch<CameraService>();
    final live = _liveResult;
    final drowsy = live?['drowsy'] == true;
    final faceDetected = live?['face_detected'] == true;
    final eyeOpen = (live?['eye_open_probability'] as num?)?.toDouble();
    final closedFor = ((live?['closed_seconds'] as num?) ?? 0).toDouble();

    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: const SvAppBar(title: 'Drowsiness Monitor'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          SvCard(
            borderColor: drowsy ? AppColors.error : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SvSectionTitle(
                  'Live monitoring',
                  icon: Icons.remove_red_eye_outlined,
                  subtitle: 'Front camera · on-device ML Kit eye analysis',
                  trailing: _isMonitoring
                      ? (_appInBackground
                          ? const SvPill(
                              label: 'Paused', color: AppColors.warning)
                          : drowsy
                              ? const SvPill(
                                  label: 'DROWSY', color: AppColors.error)
                              : const SvPill(
                                  label: 'Monitoring',
                                  color: AppColors.success))
                      : const SvPill(
                          label: 'Not running', color: AppColors.mutedText),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    color: Colors.black,
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                      minHeight: 180,
                    ),
                    child: _buildPreview(camera),
                  ),
                ),
                if (drowsy) ...[
                  const SizedBox(height: 10),
                  const SvNotice(
                    tone: SvTone.error,
                    icon: Icons.warning_rounded,
                    message: 'Drowsiness detected — eyes have been closed '
                        'longer than the alert threshold. Take a break.',
                  ),
                ],
                const SizedBox(height: 12),
                LayoutBuilder(builder: (context, constraints) {
                  const spacing = 8.0;
                  final width = (constraints.maxWidth - spacing) / 2;
                  final tiles = [
                    SvMetric(
                      label: 'Face',
                      value: live == null
                          ? '—'
                          : faceDetected
                              ? 'Detected'
                              : 'Not found',
                      valueColor: live == null
                          ? null
                          : faceDetected
                              ? AppColors.success
                              : AppColors.warning,
                    ),
                    SvMetric(
                      label: 'Eye-open probability',
                      value: eyeOpen == null ? '—' : formatPercent(eyeOpen),
                    ),
                    SvMetric(
                      label: 'Eyes closed for',
                      value: live == null
                          ? '—'
                          : '${closedFor.toStringAsFixed(1)} s',
                      valueColor: drowsy ? AppColors.error : null,
                    ),
                    SvMetric(
                      label: 'Alerts this session',
                      value: '${live?['incidents'] ?? 0}',
                    ),
                    SvMetric(
                      label: 'Frames analysed / s',
                      value: _isMonitoring && _analysedFps > 0
                          ? _analysedFps.toStringAsFixed(1)
                          : '—',
                    ),
                    SvMetric(
                      label: 'Camera',
                      value: camera.isInitialized
                          ? (camera.isFrontCamera ? 'Front' : 'Back')
                          : 'Not ready',
                    ),
                  ];
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final t in tiles) SizedBox(width: width, child: t),
                    ],
                  );
                }),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _isMonitoring
                          ? AppColors.error
                          : AppColors.accentBlue,
                    ),
                    onPressed: _isAnalyzingVideo ? null : _toggleMonitoring,
                    icon: Icon(_isMonitoring
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline_rounded),
                    label: Text(
                        _isMonitoring ? 'Stop monitoring' : 'Start monitoring'),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Monitoring only runs while this screen is open and the app '
                  'is in the foreground; Android stops camera access in the '
                  'background.',
                  style: TextStyle(color: AppColors.mutedText, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SvSectionTitle('Alert settings', icon: Icons.tune_rounded),
                const SizedBox(height: 8),
                _slider(
                  label: 'Eyes considered closed below',
                  value: _closedEyeThreshold,
                  display: formatPercent(_closedEyeThreshold),
                  min: 0.1,
                  max: 0.6,
                  divisions: 10,
                  onChanged: (v) => setState(() => _closedEyeThreshold = v),
                ),
                _slider(
                  label: 'Alert after eyes closed for',
                  value: _closedSeconds,
                  display: '${_closedSeconds.toStringAsFixed(1)} s',
                  min: 0.5,
                  max: 4.0,
                  divisions: 7,
                  onChanged: (v) => setState(() => _closedSeconds = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SvSectionTitle(
                  'Analyse a video',
                  icon: Icons.movie_outlined,
                  subtitle: 'Samples two frames per second on the device',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isAnalyzingVideo
                            ? null
                            : () => _analyzeVideo(ImageSource.gallery),
                        icon: const Icon(Icons.video_library_outlined),
                        label: const Text('Choose'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isAnalyzingVideo
                            ? null
                            : () => _analyzeVideo(ImageSource.camera),
                        icon: const Icon(Icons.videocam_outlined),
                        label: const Text('Record'),
                      ),
                    ),
                  ],
                ),
                if (_isAnalyzingVideo) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _videoProgress),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Analysing… ${(_videoProgress * 100).toStringAsFixed(0)}%',
                          style:
                              const TextStyle(color: AppColors.secondaryText),
                        ),
                      ),
                      TextButton(
                        onPressed: _videoCancelRequested
                            ? null
                            : () =>
                                setState(() => _videoCancelRequested = true),
                        child: Text(
                            _videoCancelRequested ? 'Stopping…' : 'Cancel'),
                      ),
                    ],
                  ),
                ],
                if (_videoResult case final result?) ...[
                  const SizedBox(height: 12),
                  _buildVideoResult(result),
                ],
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            SvNotice(tone: SvTone.error, message: _error!),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview(CameraService camera) {
    if (camera.permissionStatus == CameraPermissionStatus.permanentlyDenied) {
      return _message(
        'Camera access is blocked. Enable it in system settings.',
        action: const TextButton(
          onPressed: openAppSettings,
          child: Text('Open settings'),
        ),
      );
    }
    if (camera.permissionStatus == CameraPermissionStatus.denied) {
      return _message(
        'Camera permission is required for live monitoring.',
        action: TextButton(
          onPressed: camera.requestPermission,
          child: const Text('Allow camera'),
        ),
      );
    }
    final controller = camera.controller;
    final upright = camera.uprightPreviewSize;
    if (camera.initializationError != null && !camera.isInitialized) {
      return _message(camera.initializationError!,
          action: TextButton(
            onPressed: camera.initialize,
            child: const Text('Retry'),
          ));
    }
    if (!camera.isInitialized || controller == null || upright == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return DetectionFrame(
      aspectRatio: upright.width / upright.height,
      detections: const [],
      child: CameraPreview(controller),
    );
  }

  Widget _message(String text, {Widget? action}) {
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      color: AppColors.primaryBackground,
      child: SvEmptyState(
        icon: Icons.no_photography_outlined,
        title: 'Camera unavailable',
        message: text,
        action: action,
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required String display,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: AppColors.secondaryText)),
            ),
            Text(display,
                style: const TextStyle(
                    color: AppColors.accentCyan, fontWeight: FontWeight.w700)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildVideoResult(Map<String, dynamic> result) {
    final incidents = (result['incidents'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SvPill(
              label: '${result['total_incidents']} alert(s)',
              color: incidents.isEmpty ? AppColors.success : AppColors.error,
            ),
            SvPill(
              label: '${result['frames_analyzed']} frames analysed',
              color: AppColors.accentBlue,
            ),
            SvPill(
              label: '${result['frames_with_face']} with a face',
              color: AppColors.accentPurple,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (incidents.isEmpty)
          const Text(
            'No drowsiness episodes were detected in the sampled frames.',
            style: TextStyle(color: AppColors.secondaryText),
          )
        else
          for (final incident in incidents)
            if (incident is Map)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber_rounded,
                    color: AppColors.error),
                title: Text(
                  'Eyes closed at ${incident['timestamp']}',
                  style: const TextStyle(color: AppColors.primaryText),
                ),
                subtitle: Text(
                  incident['eye_open_probability'] == null
                      ? ''
                      : 'Eye-open probability '
                          '${formatPercent((incident['eye_open_probability'] as num).toDouble())}',
                  style: const TextStyle(color: AppColors.mutedText),
                ),
              ),
      ],
    );
  }
}
