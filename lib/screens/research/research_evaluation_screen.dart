import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../controllers/detection_controller.dart';
import '../../core/constants/app_colors.dart';
import '../../models/detection_result.dart';
import '../../services/database_service.dart';
import '../../services/on_device_ai_service.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

/// Research Evaluation.
///
/// 1. A real, reproducible on-device benchmark: the bundled YOLOv8n model is
///    run on the project's sample images and the actual timings/detections
///    measured on this phone are shown.
/// 2. The comparison figures that the website's Research Evaluation page
///    displays. They are static values in app.py (not computed by the app),
///    so they are shown here clearly labelled as reported figures.
class ResearchEvaluationScreen extends StatefulWidget {
  const ResearchEvaluationScreen({super.key});

  @override
  State<ResearchEvaluationScreen> createState() =>
      _ResearchEvaluationScreenState();
}

class _BenchmarkRow {
  _BenchmarkRow({
    required this.asset,
    required this.width,
    required this.height,
    required this.runs,
    required this.results,
  });

  final String asset;
  final int width;
  final int height;
  final List<DetectionOutcome> runs;
  final List<DetectionResult> results;

  double _avg(double Function(DetectionOutcome) pick) =>
      runs.map(pick).reduce((a, b) => a + b) / runs.length;

  double get preprocessMs => _avg((o) => o.preprocessMs);
  double get inferenceMs => _avg((o) => o.inferenceMs);
  double get postprocessMs => _avg((o) => o.postprocessMs);
  double get totalMs => _avg((o) => o.totalMs);
}

class _ResearchEvaluationScreenState extends State<ResearchEvaluationScreen> {
  static const _samples = [
    'assets/samples/classroom.jpg',
    'assets/samples/office.jpg',
    'assets/samples/danger.png',
    'assets/samples/document.png',
  ];
  static const int _repeats = 3;

  final OnDeviceAiService _ai = OnDeviceAiService.instance;
  bool _running = false;
  String? _status;
  String? _error;
  List<_BenchmarkRow>? _rows;

  Future<void> _runBenchmark() async {
    final settings = context.read<DetectionController>().settings;
    final database = context.read<DatabaseService>();
    setState(() {
      _running = true;
      _error = null;
      _rows = null;
    });
    try {
      await _ai.initialize();
      if (!_ai.isModelLoaded) {
        throw StateError(_ai.modelError ?? 'Model not loaded.');
      }
      // Warm-up run so the first timing is not dominated by allocation.
      final warmup = await rootBundle.load(_samples.first);
      await _ai.detectImage(
        warmup.buffer.asUint8List(warmup.offsetInBytes, warmup.lengthInBytes),
        settings: settings,
      );

      final rows = <_BenchmarkRow>[];
      for (final asset in _samples) {
        if (!mounted) return;
        setState(() => _status = 'Running ${asset.split('/').last}…');
        final data = await rootBundle.load(asset);
        final bytes =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        final runs = <DetectionOutcome>[];
        for (var i = 0; i < _repeats; i++) {
          runs.add(await _ai.detectImage(bytes, settings: settings));
        }
        rows.add(_BenchmarkRow(
          asset: asset,
          width: runs.last.imageWidth,
          height: runs.last.imageHeight,
          runs: runs,
          results: runs.last.results,
        ));
      }
      if (!mounted) return;
      setState(() => _rows = rows);
      final avgTotal =
          rows.map((r) => r.totalMs).reduce((a, b) => a + b) / rows.length;
      try {
        await database.insertAnalysisHistory(
          analysisType: 'On-device Benchmark',
          summary: '${rows.length} images · avg ${avgTotal.toStringAsFixed(0)} ms',
          details: {
            for (final r in rows)
              r.asset: {
                'inference_ms': r.inferenceMs,
                'total_ms': r.totalMs,
                'detections': r.results.length,
              },
          },
        );
      } catch (_) {}
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Benchmark failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _status = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final settings = context.watch<DetectionController>().settings;
    double? avg(double Function(_BenchmarkRow) pick) => rows == null ||
            rows.isEmpty
        ? null
        : rows.map(pick).reduce((a, b) => a + b) / rows.length;
    final avgInference = avg((r) => r.inferenceMs);
    final avgTotal = avg((r) => r.totalMs);

    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: const SvAppBar(title: 'Research Evaluation'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          const SvCard(
            highlight: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Research Evaluation',
                  style: TextStyle(
                    color: AppColors.primaryText,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Comparative analysis: Baseline YOLOv8 vs. proposed '
                  'Smart Vision architecture',
                  style: TextStyle(color: AppColors.secondaryText),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SvSectionTitle(
                  'On-device benchmark',
                  icon: Icons.speed_rounded,
                  subtitle: 'Measured on this phone · ${_samples.length} sample '
                      'images × $_repeats runs · conf '
                      '${formatPercent(settings.minimumConfidence)}, IoU '
                      '${settings.iouThreshold.toStringAsFixed(2)}',
                ),
                const SizedBox(height: 12),
                if (avgInference != null && avgTotal != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: SvMetric(
                          label: 'Avg inference',
                          value: '${avgInference.toStringAsFixed(0)} ms',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SvMetric(
                          label: 'Avg end-to-end',
                          value: '${avgTotal.toStringAsFixed(0)} ms',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SvMetric(
                          label: 'Images / s',
                          value: (1000 / avgTotal).toStringAsFixed(1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final row in rows!) _BenchmarkTile(row: row),
                  const SizedBox(height: 4),
                  const Text(
                    'End-to-end includes JPEG/PNG decoding and letterboxing of '
                    'full-size images; live camera frames are smaller and '
                    'faster to prepare.',
                    style:
                        TextStyle(color: AppColors.mutedText, fontSize: 11.5),
                  ),
                  const SizedBox(height: 10),
                ],
                if (_status != null) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Text(_status!,
                      style: const TextStyle(color: AppColors.secondaryText)),
                  const SizedBox(height: 10),
                ],
                FilledButton.icon(
                  onPressed: _running ? null : _runBenchmark,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(rows == null ? 'Run benchmark' : 'Run again'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  SvNotice(tone: SvTone.error, message: _error!),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          const _ReportedFiguresCard(),
        ],
      ),
    );
  }
}

class _BenchmarkTile extends StatelessWidget {
  const _BenchmarkTile({required this.row});

  final _BenchmarkRow row;

  @override
  Widget build(BuildContext context) {
    final labels = <String, int>{};
    for (final r in row.results) {
      labels.update(r.label, (v) => v + 1, ifAbsent: () => 1);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primaryBackground.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.asset.split('/').last,
                  style: const TextStyle(
                    color: AppColors.primaryText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${row.width}×${row.height}',
                style: const TextStyle(color: AppColors.mutedText),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Prep ${row.preprocessMs.toStringAsFixed(0)} ms · '
            'Inference ${row.inferenceMs.toStringAsFixed(0)} ms · '
            'NMS ${row.postprocessMs.toStringAsFixed(1)} ms',
            style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            labels.isEmpty
                ? 'No detections above threshold'
                : labels.entries.map((e) => '${e.key} × ${e.value}').join(', '),
            style: const TextStyle(color: AppColors.accentCyan, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// The values displayed by the website's Research Evaluation page (app.py),
/// reproduced verbatim and labelled as reported, not measured.
class _ReportedFiguresCard extends StatelessWidget {
  const _ReportedFiguresCard();

  @override
  Widget build(BuildContext context) {
    return SvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SvSectionTitle(
            'Reported comparison (website)',
            icon: Icons.menu_book_outlined,
            subtitle: 'Static figures from the website page — not measured '
                'by this app',
          ),
          const SizedBox(height: 10),
          const SvNotice(
            tone: SvTone.warning,
            message: 'These numbers are hard-coded in app.py (the chart data '
                'is marked "Mock Data" in the source). They are shown for '
                'parity with the website; use the on-device benchmark above '
                'for real measurements.',
          ),
          const SizedBox(height: 12),
          const _FigureRow('mAP (accuracy)', 'Baseline 68.5% → Proposed 82.7%',
              '+14.2%'),
          const _FigureRow(
              'Avg latency', 'Baseline 54 ms → Proposed 32 ms', '−22 ms'),
          const _FigureRow(
              'Battery usage', 'Adaptive edge-AI scaling', '−18%'),
          const Divider(height: 24),
          const Text(
            'FPS by scenario (baseline vs proposed)',
            style: TextStyle(
              color: AppColors.primaryText,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in const [
            ('Standard', 30.0, 30.0),
            ('High complexity', 15.0, 24.0),
            ('Low light', 28.0, 29.0),
            ('Multi-object', 12.0, 22.0),
          ])
            _PairBar(
              label: entry.$1,
              baseline: entry.$2,
              proposed: entry.$3,
              max: 30,
              format: (v) => v.toStringAsFixed(0),
            ),
          const SizedBox(height: 12),
          const Text(
            'Precision / recall in low light',
            style: TextStyle(
              color: AppColors.primaryText,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in const [
            ('Precision', 0.62, 0.81),
            ('Recall', 0.58, 0.79),
          ])
            _PairBar(
              label: entry.$1,
              baseline: entry.$2,
              proposed: entry.$3,
              max: 1,
              format: (v) => v.toStringAsFixed(2),
            ),
          const SizedBox(height: 10),
          const Row(
            children: [
              _Legend(color: AppColors.mutedText, label: 'Baseline'),
              SizedBox(width: 16),
              _Legend(color: AppColors.accentCyan, label: 'Proposed'),
            ],
          ),
          const Divider(height: 24),
          const Text(
            'Research conclusions (as stated on the website)',
            style: TextStyle(
              color: AppColors.primaryText,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          for (final line in const [
            'Adaptive Edge-AI Engine stabilises FPS during high scene '
                'complexity by dynamically scaling resolution.',
            'Low-Light Enhancer (CLAHE) improves precision and recall in poor '
                'lighting.',
            'Smart Decision Engine filtering reduces false positives, giving '
                'a cleaner tracking history.',
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('• $line',
                  style: const TextStyle(color: AppColors.secondaryText)),
            ),
        ],
      ),
    );
  }
}

class _FigureRow extends StatelessWidget {
  const _FigureRow(this.title, this.detail, this.delta);

  final String title;
  final String detail;
  final String delta;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppColors.primaryText,
                        fontWeight: FontWeight.w600)),
                Text(detail,
                    style: const TextStyle(
                        color: AppColors.mutedText, fontSize: 12)),
              ],
            ),
          ),
          Text(delta,
              style: const TextStyle(
                  color: AppColors.accentCyan,
                  fontWeight: FontWeight.w800,
                  fontSize: 16)),
        ],
      ),
    );
  }
}

class _PairBar extends StatelessWidget {
  const _PairBar({
    required this.label,
    required this.baseline,
    required this.proposed,
    required this.max,
    required this.format,
  });

  final String label;
  final double baseline;
  final double proposed;
  final double max;
  final String Function(double) format;

  @override
  Widget build(BuildContext context) {
    Widget bar(double value, Color color) => Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: (value / max).clamp(0.0, 1.0).toDouble(),
                  minHeight: 7,
                  color: color,
                  backgroundColor: AppColors.elevatedSurface,
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                format(value),
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: AppColors.secondaryText, fontSize: 11.5),
              ),
            ),
          ],
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.secondaryText, fontSize: 12)),
          const SizedBox(height: 3),
          bar(baseline, AppColors.mutedText),
          const SizedBox(height: 3),
          bar(proposed, AppColors.accentCyan),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(color: AppColors.mutedText, fontSize: 12)),
      ],
    );
  }
}
