import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../controllers/detection_controller.dart';
import '../../controllers/statistics_controller.dart';
import '../../core/constants/app_colors.dart';
import '../../core/navigation/app_destinations.dart';
import '../../services/backend_service.dart';
import '../../services/camera_service.dart';
import '../../services/database_service.dart';
import '../../services/on_device_ai_service.dart';
import '../../widgets/detection_panels.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

/// Mobile dashboard: header + real system status, live detection panel,
/// detection summary, detection settings and recent activity.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: const SvAppBar(title: 'Dashboard'),
      body: RefreshIndicator(
        color: AppColors.accentCyan,
        onRefresh: () async {
          await Future.wait([
            context.read<BackendService>().checkHealth(),
            context.read<StatisticsController>().refreshData(),
          ]);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: const [
            _DashboardHeader(),
            SizedBox(height: 14),
            LiveDetectionPanel(),
            SizedBox(height: 14),
            DetectionSummaryCard(),
            SizedBox(height: 14),
            DetectionSettingsCard(),
            SizedBox(height: 14),
            _RecentActivityCard(),
            SizedBox(height: 14),
            _FeatureGrid(),
          ],
        ),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader();

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<OnDeviceAiService>();
    final backend = context.watch<BackendService>();
    final camera = context.watch<CameraService>();
    final stats = context.watch<StatisticsController>();

    return SvCard(
      highlight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Smart Vision Dashboard',
            style: TextStyle(
              color: AppColors.primaryText,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Real-time object detection and tracking',
            style: TextStyle(color: AppColors.secondaryText, fontSize: 13.5),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SvPill(
                label: ai.isModelLoaded
                    ? 'On-device AI ready'
                    : ai.modelError != null
                        ? 'On-device AI error'
                        : 'Loading model…',
                color: ai.isModelLoaded
                    ? AppColors.success
                    : ai.modelError != null
                        ? AppColors.error
                        : AppColors.warning,
              ),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => showSystemStatusSheet(context),
                child: SvPill(
                  label: backend.statusLabel,
                  color: switch (backend.status) {
                    BackendStatus.online => AppColors.success,
                    BackendStatus.checking => AppColors.warning,
                    BackendStatus.offline => AppColors.error,
                    BackendStatus.notConfigured => AppColors.mutedText,
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final width = (constraints.maxWidth - spacing) / 2;
              final tiles = [
                SvMetric(
                  label: 'Model',
                  value: ai.isModelLoaded
                      ? 'YOLOv8n · ${ai.modelInputDescription}'
                      : '—',
                  icon: Icons.memory_rounded,
                ),
                SvMetric(
                  label: 'Cameras found',
                  value: camera.cameras.isEmpty
                      ? (camera.isInitialized ? '0' : 'Not opened')
                      : '${camera.cameras.length}',
                  icon: Icons.photo_camera_outlined,
                ),
                SvMetric(
                  label: 'Saved detections today',
                  value: stats.isLoading ? '…' : '${stats.todayDetections}',
                  icon: Icons.today_outlined,
                ),
                SvMetric(
                  label: 'Saved detections total',
                  value: stats.isLoading ? '…' : '${stats.totalDetections}',
                  icon: Icons.storage_rounded,
                ),
              ];
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final tile in tiles) SizedBox(width: width, child: tile),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RecentActivityCard extends StatefulWidget {
  const _RecentActivityCard();

  @override
  State<_RecentActivityCard> createState() => _RecentActivityCardState();
}

class _ActivityItem {
  const _ActivityItem({
    required this.title,
    required this.subtitle,
    required this.time,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final DateTime time;
  final IconData icon;
}

class _RecentActivityCardState extends State<_RecentActivityCard> {
  List<_ActivityItem>? _items;
  String? _error;
  DateTime? _lastSeenResult;
  DateTime _lastLoad = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _maybeScheduleReload(DateTime? latest) {
    if (latest == null || latest == _lastSeenResult) return;
    _lastSeenResult = latest;
    // Re-query at most every 5 s while live detection is producing results.
    final wait =
        const Duration(seconds: 5) - DateTime.now().difference(_lastLoad);
    _debounce?.cancel();
    _debounce = Timer(wait.isNegative ? Duration.zero : wait, _load);
  }

  Future<void> _load() async {
    _lastLoad = DateTime.now();
    final database = context.read<DatabaseService>();
    try {
      final detections = await database.getRecentDetections(limit: 6);
      final analyses = await database.getAnalysisHistory(limit: 6);
      final items = <_ActivityItem>[
        for (final d in detections)
          _ActivityItem(
            title: 'Detected ${d.objectName}',
            subtitle: 'Confidence ${formatPercent(d.confidence)}',
            time: d.timestamp,
            icon: Icons.center_focus_strong_outlined,
          ),
        for (final a in analyses)
          _ActivityItem(
            title: a['analysis_type']?.toString() ?? 'Analysis',
            subtitle: a['summary']?.toString() ?? '',
            time: DateTime.tryParse(a['timestamp']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
            icon: Icons.insights_outlined,
          ),
      ]..sort((a, b) => b.time.compareTo(a.time));
      if (!mounted) return;
      setState(() {
        _items = items.take(6).toList();
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not read history: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    _maybeScheduleReload(context.select<DetectionController, DateTime?>(
        (controller) => controller.lastResultAt));
    final items = _items;
    final format = DateFormat('MMM d, HH:mm');
    return SvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SvSectionTitle(
            'Recent Activity',
            icon: Icons.history_rounded,
            subtitle: 'Saved on this device',
            trailing: TextButton(
              onPressed: () => context.go(AppDestinations.history.route),
              child: const Text('View all'),
            ),
          ),
          const SizedBox(height: 8),
          if (_error != null)
            SvNotice(tone: SvTone.error, message: _error!)
          else if (items == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (items.isEmpty)
            const SvEmptyState(
              icon: Icons.inbox_outlined,
              title: 'No activity yet',
              message: 'Detections, OCR and video analyses you run will be '
                  'listed here.',
            )
          else
            for (final item in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(item.icon, color: AppColors.accentCyan, size: 20),
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.primaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.mutedText),
                ),
                trailing: Text(
                  format.format(item.time),
                  style: const TextStyle(
                    color: AppColors.mutedText,
                    fontSize: 11,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid();

  @override
  Widget build(BuildContext context) {
    final destinations = AppDestinations.website
        .where((d) => d != AppDestinations.dashboard)
        .toList();
    return SvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SvSectionTitle(
            'All Features',
            icon: Icons.apps_rounded,
            subtitle: 'Everything available in the website sidebar',
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 480 ? 4 : 3;
              const spacing = 8.0;
              final width =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final d in destinations)
                    SizedBox(
                      width: width,
                      child: _FeatureTile(destination: d),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({required this.destination});

  final AppDestination destination;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primaryBackground.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.borderSubtle),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.go(destination.route),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(destination.icon, color: AppColors.accentCyan, size: 24),
              const SizedBox(height: 8),
              Text(
                destination.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
