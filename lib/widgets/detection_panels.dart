import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../controllers/detection_controller.dart';
import '../core/constants/app_colors.dart';
import '../models/detection_result.dart';
import '../models/detection_settings.dart';
import '../services/camera_service.dart';
import '../services/on_device_ai_service.dart';
import 'detection_overlay.dart';
import 'sv_ui.dart';

/// Live detection panel shared by the Dashboard and the Object Detection
/// screen: camera preview with correctly aligned boxes, camera selector,
/// start/stop, image upload and capture, and real status/FPS/resolution.
class LiveDetectionPanel extends StatefulWidget {
  const LiveDetectionPanel({
    super.key,
    this.autoOpenCamera = false,
    this.maxPreviewHeightFraction = 0.55,
    this.title = 'Live Detection',
  });

  /// Open the camera preview as soon as the panel is shown.
  final bool autoOpenCamera;
  final double maxPreviewHeightFraction;
  final String title;

  @override
  State<LiveDetectionPanel> createState() => _LiveDetectionPanelState();
}

class _LiveDetectionPanelState extends State<LiveDetectionPanel>
    with AutomaticKeepAliveClientMixin {
  late final CameraService _camera;
  late final DetectionController _detection;
  bool _cameraRequested = false;
  bool _busyAction = false;

  @override
  void initState() {
    super.initState();
    _camera = context.read<CameraService>();
    _detection = context.read<DetectionController>();
    if (widget.autoOpenCamera) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCamera();
      });
    }
  }

  @override
  void dispose() {
    final detection = _detection;
    final camera = _camera;
    final owner = this;
    final release = _cameraRequested;
    // Notifying listeners while the tree is being torn down is not allowed,
    // so stop the stream and release the camera right after this frame.
    Future.microtask(() async {
      if (detection.isLive) await detection.stopLive();
      if (release) await camera.release(owner);
    });
    super.dispose();
  }

  Future<void> _openCamera() async {
    if (_detection.source == DetectionSource.image) {
      _detection.clearStillImage();
    }
    if (!_cameraRequested) {
      setState(() => _cameraRequested = true);
      await _camera.acquire(this);
    } else {
      await _camera.initialize();
    }
  }

  Future<void> _toggleLive() async {
    if (_detection.isLive) {
      await _detection.stopLive();
      return;
    }
    await _openCamera();
    if (!mounted) return;
    if (!_camera.isInitialized) {
      _snack(_camera.initializationError ??
          'The camera is not available. Check the camera permission.');
      return;
    }
    await _detection.startLive();
  }

  Future<void> _pickFromGallery() async {
    await _runStill(() async {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 92,
      );
      return picked?.readAsBytes();
    });
  }

  Future<void> _capture() async {
    await _runStill(() async {
      if (_camera.isInitialized) {
        return _camera.captureStill();
      }
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 92,
      );
      return picked?.readAsBytes();
    });
  }

  Future<void> _runStill(Future<Uint8List?> Function() load) async {
    if (_busyAction) return;
    setState(() => _busyAction = true);
    try {
      if (_detection.isLive) await _detection.stopLive();
      final bytes = await load();
      if (bytes == null) return; // user cancelled
      await _detection.analyzeImageBytes(bytes);
    } catch (error) {
      _snack('Detection failed: ${_friendly(error)}');
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  String _friendly(Object error) {
    if (error is FormatException) return error.message;
    return error.toString().replaceFirst('Bad state: ', '');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Keep the camera/live detection running while the panel is scrolled
  /// out of view inside a ListView.
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final camera = context.watch<CameraService>();
    final detection = context.watch<DetectionController>();
    final ai = context.watch<OnDeviceAiService>();
    final maxHeight =
        MediaQuery.sizeOf(context).height * widget.maxPreviewHeightFraction;

    return SvCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SvSectionTitle(
            widget.title,
            icon: Icons.videocam_outlined,
            subtitle: ai.isModelLoaded
                ? '${ai.modelName} · ${ai.modelInputDescription}'
                : (ai.modelError != null
                    ? 'Model failed to load'
                    : 'Loading on-device model…'),
            trailing: _StatusPill(detection: detection, ai: ai),
          ),
          if (ai.modelError != null) ...[
            const SizedBox(height: 10),
            SvNotice(
              tone: SvTone.error,
              message: ai.modelError!,
              action: TextButton(
                onPressed: ai.initialize,
                child: const Text('Retry'),
              ),
            ),
          ],
          if (camera.cameras.length > 1 && _cameraRequested) ...[
            const SizedBox(height: 10),
            _CameraSelector(camera: camera),
          ],
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: Colors.black,
              constraints: BoxConstraints(maxHeight: maxHeight, minHeight: 200),
              child: _buildViewport(camera, detection),
            ),
          ),
          if (detection.lastAnalysisError != null &&
              detection.source != DetectionSource.none) ...[
            const SizedBox(height: 10),
            SvNotice(
              tone: SvTone.error,
              message: detection.lastAnalysisError!,
            ),
          ],
          const SizedBox(height: 12),
          _MetricsRow(detection: detection, camera: camera),
          const SizedBox(height: 12),
          _GradientButton(
            label: detection.isLive ? 'Stop Detection' : 'Start Detection',
            icon: detection.isLive
                ? Icons.stop_circle_outlined
                : Icons.play_circle_outline_rounded,
            danger: detection.isLive,
            onPressed:
                ai.modelError != null && !detection.isLive ? null : _toggleLive,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: _busyAction ? null : _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined, size: 19),
                    label: const Text('Upload'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: _busyAction ? null : _capture,
                    icon: const Icon(Icons.camera_alt_outlined, size: 19),
                    label: const Text('Capture'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildViewport(CameraService camera, DetectionController detection) {
    final still = detection.stillImage;
    if (detection.source == DetectionSource.image && still != null) {
      final outcome = detection.lastOutcome;
      final aspect = outcome != null && outcome.imageHeight > 0
          ? outcome.imageWidth / outcome.imageHeight
          : 3 / 4;
      return Stack(
        children: [
          DetectionFrame(
            aspectRatio: aspect,
            detections: detection.currentResults,
            child: Image.memory(
              still,
              fit: outcome == null ? BoxFit.contain : BoxFit.fill,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Text(
                  'This image cannot be displayed.',
                  style: TextStyle(color: AppColors.secondaryText),
                ),
              ),
            ),
          ),
          if (detection.isProcessingFrame)
            const Positioned.fill(child: _BusyOverlay(label: 'Analyzing image…')),
          const Positioned(
            top: 8,
            left: 8,
            child: SvPill(
              label: 'Image result',
              color: AppColors.accentPurple,
              icon: Icons.image_outlined,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton.filledTonal(
              tooltip: 'Back to camera',
              onPressed: _openCamera,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ),
        ],
      );
    }

    if (!_cameraRequested) {
      return _ViewportMessage(
        icon: Icons.videocam_off_outlined,
        title: 'Camera is off',
        message:
            'Start detection to open the camera, or upload / capture an image.',
        action: OutlinedButton.icon(
          onPressed: _openCamera,
          icon: const Icon(Icons.videocam_outlined),
          label: const Text('Open camera'),
        ),
      );
    }
    switch (camera.permissionStatus) {
      case CameraPermissionStatus.denied:
        return _ViewportMessage(
          icon: Icons.no_photography_outlined,
          title: 'Camera permission needed',
          message: 'Allow camera access to run live detection.',
          action: FilledButton(
            onPressed: camera.requestPermission,
            child: const Text('Allow camera'),
          ),
        );
      case CameraPermissionStatus.permanentlyDenied:
        return const _ViewportMessage(
          icon: Icons.no_photography_outlined,
          title: 'Camera access is blocked',
          message:
              'Enable the camera permission for Smart Vision in system settings. '
              'You can still upload images.',
          action: FilledButton(
            onPressed: openAppSettings,
            child: Text('Open settings'),
          ),
        );
      case CameraPermissionStatus.granted:
      case CameraPermissionStatus.undetermined:
        break;
    }
    final error = camera.initializationError;
    if (error != null && !camera.isInitialized) {
      return _ViewportMessage(
        icon: Icons.error_outline_rounded,
        title: 'Camera unavailable',
        message: error,
        action: OutlinedButton(
          onPressed: camera.initialize,
          child: const Text('Retry'),
        ),
      );
    }
    final controller = camera.controller;
    final upright = camera.uprightPreviewSize;
    if (!camera.isInitialized || controller == null || upright == null) {
      return const _BusyOverlay(label: 'Starting camera…');
    }
    final live = detection.source == DetectionSource.live;
    return DetectionFrame(
      aspectRatio: upright.width / upright.height,
      detections: live ? detection.currentResults : const [],
      mirrored: detection.lastFrameMirrored,
      overlays: [
        Positioned(
          top: 8,
          left: 8,
          child: detection.isLive
              ? const SvPill(label: 'LIVE', color: AppColors.error)
              : const SvPill(label: 'Preview', color: AppColors.mutedText),
        ),
        if (detection.hasActiveHazard && detection.isLive)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: SvNotice(
              tone: SvTone.error,
              icon: Icons.warning_rounded,
              message:
                  'Hazard detected: ${detection.activeHazardLabel ?? 'unknown'}',
            ),
          ),
      ],
      child: CameraPreview(controller),
    );
  }
}

/// Primary action styled like the website's cyan -> purple gradient button.
class _GradientButton extends StatelessWidget {
  const _GradientButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final gradient = danger
        ? const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFB91C1C)])
        : const LinearGradient(
            colors: [
              AppColors.accentCyan,
              AppColors.accentBlue,
              AppColors.accentPurple,
            ],
          );
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: (danger ? AppColors.error : AppColors.accentBlue)
                  .withValues(alpha: 0.35),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPressed,
            child: SizedBox(
              height: 50,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.detection, required this.ai});

  final DetectionController detection;
  final OnDeviceAiService ai;

  @override
  Widget build(BuildContext context) {
    if (ai.modelError != null) {
      return const SvPill(label: 'Error', color: AppColors.error);
    }
    if (detection.isLive) {
      return const SvPill(label: 'Active', color: AppColors.success);
    }
    if (detection.isProcessingFrame) {
      return const SvPill(label: 'Analyzing', color: AppColors.warning);
    }
    return const SvPill(label: 'Idle', color: AppColors.mutedText);
  }
}

class _CameraSelector extends StatelessWidget {
  const _CameraSelector({required this.camera});

  final CameraService camera;

  @override
  Widget build(BuildContext context) {
    final cameras = camera.cameras;
    return DropdownButtonFormField<int>(
      key: ValueKey('camera-${camera.selectedCameraIndex}-${cameras.length}'),
      initialValue: camera.selectedCameraIndex,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Camera',
        prefixIcon: Icon(Icons.cameraswitch_outlined),
        isDense: true,
      ),
      dropdownColor: AppColors.elevatedSurface,
      items: [
        for (var i = 0; i < cameras.length; i++)
          DropdownMenuItem(
            value: i,
            child: Text(CameraService.describeCamera(cameras[i], i)),
          ),
      ],
      onChanged: (index) {
        if (index != null) camera.selectCamera(index);
      },
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.detection, required this.camera});

  final DetectionController detection;
  final CameraService camera;

  @override
  Widget build(BuildContext context) {
    final outcome = detection.lastOutcome;
    final fps = detection.measuredFps;
    String resolution = '—';
    if (outcome != null) {
      resolution = '${outcome.imageWidth}×${outcome.imageHeight}';
    } else if (camera.uprightPreviewSize case final size?) {
      resolution = '${size.width.round()}×${size.height.round()}';
    }
    final status = detection.isLive
        ? 'Detecting'
        : detection.isProcessingFrame
            ? 'Analyzing'
            : camera.isInitialized
                ? 'Camera ready'
                : 'Idle';
    final tiles = [
      SvMetric(
        label: 'Status',
        value: status,
        valueColor: detection.isLive ? AppColors.success : null,
        icon: Icons.sensors_rounded,
      ),
      SvMetric(
        label: 'FPS (measured)',
        value: fps == null ? '—' : fps.toStringAsFixed(1),
        icon: Icons.speed_rounded,
      ),
      SvMetric(
        label: 'Resolution',
        value: resolution,
        icon: Icons.aspect_ratio_rounded,
      ),
      SvMetric(
        label: 'Inference',
        value: outcome == null
            ? '—'
            : '${outcome.inferenceMs.toStringAsFixed(0)} ms',
        icon: Icons.memory_rounded,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 4 : 2;
        const spacing = 8.0;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

class _ViewportMessage extends StatelessWidget {
  const _ViewportMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primaryBackground,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: SvEmptyState(
          icon: icon,
          title: title,
          message: message,
          action: action,
        ),
      ),
    );
  }
}

class _BusyOverlay extends StatelessWidget {
  const _BusyOverlay({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(color: AppColors.secondaryText)),
        ],
      ),
    );
  }
}

/// Real results of the latest inference: count, classes, confidences and
/// measured processing time. Shows an empty state instead of placeholder data.
class DetectionSummaryCard extends StatelessWidget {
  const DetectionSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final detection = context.watch<DetectionController>();
    final outcome = detection.lastOutcome;
    final results = [...detection.currentResults]
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final counts = <String, int>{};
    for (final r in results) {
      counts.update(r.label, (v) => v + 1, ifAbsent: () => 1);
    }
    final sourceLabel = switch (detection.source) {
      DetectionSource.live => 'Live camera',
      DetectionSource.image => 'Still image',
      DetectionSource.none => 'No input yet',
    };

    return SvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SvSectionTitle(
            'Detection Summary',
            icon: Icons.analytics_outlined,
            subtitle: sourceLabel,
            trailing: Text(
              '${results.length}',
              style: const TextStyle(
                color: AppColors.accentCyan,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (outcome == null)
            SvEmptyState(
              icon: Icons.center_focus_weak_outlined,
              title: detection.isProcessingFrame
                  ? 'Analyzing…'
                  : 'No detections yet',
              message: 'Start detection or upload an image to see real '
                  'model predictions here.',
            )
          else if (results.isEmpty)
            SvEmptyState(
              icon: Icons.search_off_rounded,
              title: 'No objects detected',
              message: 'Nothing scored above the '
                  '${formatPercent(detection.settings.minimumConfidence)} '
                  'confidence threshold. Try better lighting, move closer, or '
                  'lower the threshold.',
            )
          else ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in counts.entries)
                  SvPill(
                    label: '${entry.key} × ${entry.value}',
                    color: AppColors.accentBlue,
                    icon: Icons.label_outline_rounded,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            for (final result in results.take(12)) _ResultRow(result: result),
            if (results.length > 12)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '+ ${results.length - 12} more',
                  style: const TextStyle(color: AppColors.mutedText),
                ),
              ),
          ],
          if (outcome != null) ...[
            const Divider(height: 22),
            Text(
              'Processing: ${outcome.preprocessMs.toStringAsFixed(0)} ms prep · '
              '${outcome.inferenceMs.toStringAsFixed(0)} ms inference · '
              '${outcome.postprocessMs.toStringAsFixed(0)} ms NMS '
              '(total ${outcome.totalMs.toStringAsFixed(0)} ms)',
              style: const TextStyle(color: AppColors.mutedText, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final DetectionResult result;

  @override
  Widget build(BuildContext context) {
    final color = result.isHazard ? AppColors.error : AppColors.accentCyan;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            result.isHazard ? Icons.warning_rounded : Icons.circle,
            size: result.isHazard ? 16 : 8,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 4,
            child: Text(
              result.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.primaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: result.confidence.clamp(0.0, 1.0).toDouble(),
                minHeight: 6,
                color: color,
                backgroundColor: AppColors.elevatedSurface,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 44,
            child: Text(
              formatPercent(result.confidence),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Confidence / IoU / max-detections controls wired to the real inference
/// pipeline (live, image and video detection all read these settings).
class DetectionSettingsCard extends StatefulWidget {
  const DetectionSettingsCard({super.key, this.initiallyExpanded = false});

  final bool initiallyExpanded;

  @override
  State<DetectionSettingsCard> createState() => _DetectionSettingsCardState();
}

class _DetectionSettingsCardState extends State<DetectionSettingsCard> {
  DetectionSettings? _draft;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DetectionController>();
    final settings = _draft ?? controller.settings;

    void commit(DetectionSettings value) {
      setState(() => _draft = null);
      controller.updateSettings(value);
      controller.rerunStillImage();
    }

    return SvCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: widget.initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          iconColor: AppColors.accentCyan,
          collapsedIconColor: AppColors.secondaryText,
          title: const SvSectionTitle(
            'Detection Settings',
            icon: Icons.tune_rounded,
            subtitle: 'Applied to live, image and video detection',
          ),
          children: [
            _SliderRow(
              label: 'Confidence Threshold',
              value: settings.minimumConfidence,
              display: formatPercent(settings.minimumConfidence),
              min: 0.05,
              max: 0.95,
              divisions: 18,
              onChanged: (v) => setState(
                  () => _draft = settings.copyWith(minimumConfidence: v)),
              onChangeEnd: (v) =>
                  commit(settings.copyWith(minimumConfidence: v)),
            ),
            _SliderRow(
              label: 'IoU Threshold (NMS)',
              value: settings.iouThreshold,
              display: settings.iouThreshold.toStringAsFixed(2),
              min: 0.1,
              max: 0.9,
              divisions: 16,
              onChanged: (v) =>
                  setState(() => _draft = settings.copyWith(iouThreshold: v)),
              onChangeEnd: (v) => commit(settings.copyWith(iouThreshold: v)),
            ),
            _SliderRow(
              label: 'Maximum Detections',
              value: settings.maximumDetections.toDouble(),
              display: '${settings.maximumDetections}',
              min: 1,
              max: 300,
              divisions: 299,
              onChanged: (v) => setState(() =>
                  _draft = settings.copyWith(maximumDetections: v.round())),
              onChangeEnd: (v) =>
                  commit(settings.copyWith(maximumDetections: v.round())),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => commit(const DetectionSettings()),
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Reset to defaults (25% · 0.45 · 100)'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.display,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final String display;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 13,
                ),
              ),
            ),
            Text(
              display,
              style: const TextStyle(
                color: AppColors.accentCyan,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}
