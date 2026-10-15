import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../controllers/detection_controller.dart';
import '../../core/constants/app_colors.dart';
import '../../services/database_service.dart';
import '../../services/on_device_ai_service.dart';
import '../../widgets/detection_panels.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

/// Object Detection: live camera + image detection, and video detection.
class CameraDetectionScreen extends StatefulWidget {
  const CameraDetectionScreen({super.key});

  @override
  State<CameraDetectionScreen> createState() => _CameraDetectionScreenState();
}

class _CameraDetectionScreenState extends State<CameraDetectionScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: SvAppBar(
        title: 'Object Detection',
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.accentCyan,
          labelColor: AppColors.accentCyan,
          unselectedLabelColor: AppColors.secondaryText,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(icon: Icon(Icons.videocam_outlined), text: 'Camera & Image'),
            Tab(icon: Icon(Icons.movie_outlined), text: 'Video'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        // The camera tab owns the camera; swiping must not keep it alive.
        physics: const NeverScrollableScrollPhysics(),
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: const [
              LiveDetectionPanel(
                autoOpenCamera: true,
                maxPreviewHeightFraction: 0.6,
                title: 'Camera & Image Detection',
              ),
              SizedBox(height: 14),
              DetectionSummaryCard(),
              SizedBox(height: 14),
              DetectionSettingsCard(initiallyExpanded: true),
            ],
          ),
          const _VideoDetectionTab(),
        ],
      ),
    );
  }
}

class _VideoDetectionTab extends StatefulWidget {
  const _VideoDetectionTab();

  @override
  State<_VideoDetectionTab> createState() => _VideoDetectionTabState();
}

class _VideoDetectionTabState extends State<_VideoDetectionTab>
    with AutomaticKeepAliveClientMixin {
  final OnDeviceAiService _ai = OnDeviceAiService.instance;
  XFile? _video;
  int? _videoBytes;
  int _samplesPerSecond = 1;
  bool _running = false;
  bool _cancelRequested = false;
  double _progress = 0;
  Map<String, dynamic>? _result;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  Future<void> _pick(ImageSource source) async {
    if (_running) return;
    try {
      final video = await ImagePicker().pickVideo(source: source);
      if (video == null || !mounted) return;
      final length = await File(video.path).length();
      if (!mounted) return;
      if (length == 0) {
        setState(() => _error = 'The selected video file is empty.');
        return;
      }
      setState(() {
        _video = video;
        _videoBytes = length;
        _result = null;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not open the video: $error');
    }
  }

  Future<void> _run() async {
    final video = _video;
    if (video == null || _running) return;
    final database = context.read<DatabaseService>();
    final settings = context.read<DetectionController>().settings;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = 0;
      _result = null;
      _error = null;
    });
    try {
      final result = await _ai.reviewVideo(
        path: video.path,
        targetObject: '',
        settings: settings,
        samplesPerSecond: _samplesPerSecond,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value.clamp(0.0, 1.0).toDouble());
        },
        isCancelled: () => _cancelRequested || !mounted,
      );
      if (!mounted) return;
      setState(() => _result = result);
      try {
        await database.insertAnalysisHistory(
          analysisType: 'Video Object Detection',
          summary: '${result['total_detections']} detection(s) in '
              '${result['total_frames_processed']} sampled frames',
          details: {'video': video.name, ...result},
        );
      } catch (_) {
        // History is best-effort; the result is still shown.
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Video detection failed: $error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final result = _result;
    final timeline = (result?['timeline'] as List?) ?? const [];
    final classCounts =
        (result?['class_counts'] as Map?)?.cast<String, int>() ?? const {};
    final sortedCounts = classCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        SvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SvSectionTitle(
                'Video Detection',
                icon: Icons.movie_filter_outlined,
                subtitle: 'Samples frames on the phone and runs the same '
                    'YOLOv8 model with your detection settings',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _running ? null : () => _pick(ImageSource.gallery),
                      icon: const Icon(Icons.video_library_outlined),
                      label: const Text('Choose video'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _running ? null : () => _pick(ImageSource.camera),
                      icon: const Icon(Icons.videocam_outlined),
                      label: const Text('Record'),
                    ),
                  ),
                ],
              ),
              if (_video case final video?) ...[
                const SizedBox(height: 10),
                Text(
                  '${video.name} · ${(_videoBytes! / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style: const TextStyle(color: AppColors.secondaryText),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Frames analysed per second',
                      style: TextStyle(color: AppColors.secondaryText),
                    ),
                  ),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('1')),
                      ButtonSegment(value: 2, label: Text('2')),
                      ButtonSegment(value: 5, label: Text('5')),
                    ],
                    selected: {_samplesPerSecond},
                    showSelectedIcon: false,
                    onSelectionChanged: _running
                        ? null
                        : (value) =>
                            setState(() => _samplesPerSecond = value.first),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_running) ...[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 6),
                Text(
                  'Analysing… ${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: AppColors.secondaryText),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _cancelRequested
                      ? null
                      : () => setState(() => _cancelRequested = true),
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(_cancelRequested ? 'Stopping…' : 'Cancel'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _video == null ? null : _run,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Detect objects in video'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                SvNotice(tone: SvTone.error, message: _error!),
              ],
            ],
          ),
        ),
        if (result != null) ...[
          const SizedBox(height: 14),
          SvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SvSectionTitle('Results', icon: Icons.fact_check_outlined),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SvPill(
                      label: '${result['total_frames_processed']} frames analysed',
                      color: AppColors.accentBlue,
                    ),
                    SvPill(
                      label: '${result['total_detections']} detections',
                      color: AppColors.accentCyan,
                    ),
                    SvPill(
                      label:
                          '${(result['average_inference_ms'] as num).toStringAsFixed(0)} ms / frame',
                      color: AppColors.accentPurple,
                    ),
                    if (result['cancelled'] == true)
                      const SvPill(
                          label: 'Stopped early', color: AppColors.warning),
                    if (result['truncated'] == true)
                      const SvPill(
                          label: 'Truncated at 600 frames',
                          color: AppColors.warning),
                  ],
                ),
                const SizedBox(height: 12),
                if (sortedCounts.isEmpty)
                  const SvEmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No objects detected',
                    message: 'No sampled frame contained an object above the '
                        'confidence threshold.',
                  )
                else ...[
                  for (final entry in sortedCounts)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(entry.key,
                                style: const TextStyle(
                                    color: AppColors.primaryText)),
                          ),
                          Text(
                            '${entry.value}',
                            style: const TextStyle(
                              color: AppColors.accentCyan,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(height: 22),
                  const Text(
                    'Timeline',
                    style: TextStyle(
                      color: AppColors.primaryText,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final event in timeline.take(100))
                    if (event is Map)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 56,
                              child: Text(
                                event['timestamp']?.toString() ?? '',
                                style: const TextStyle(
                                  color: AppColors.accentCyan,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                ((event['detections'] as List?) ?? const [])
                                    .whereType<Map>()
                                    .map((d) =>
                                        '${d['label']} ${formatPercent((d['confidence'] as num).toDouble())}')
                                    .join(', '),
                                style: const TextStyle(
                                    color: AppColors.secondaryText),
                              ),
                            ),
                          ],
                        ),
                      ),
                  if (timeline.length > 100)
                    Text(
                      '+ ${timeline.length - 100} more timestamps (saved in History)',
                      style: const TextStyle(color: AppColors.mutedText),
                    ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
