import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_colors.dart';
import '../../services/backend_service.dart';
import '../../services/on_device_ai_service.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

/// AutoML & Dataset Pipeline — the website page is a read-only dashboard of
/// server storage, dataset splits, dataset sources and target classes. The
/// same information is read from the server (GET /dataset/summary). Training
/// is not started from the website or this app, so no training is simulated.
class AutoMlScreen extends StatefulWidget {
  const AutoMlScreen({super.key});

  @override
  State<AutoMlScreen> createState() => _AutoMlScreenState();
}

class _AutoMlScreenState extends State<AutoMlScreen> {
  Map<String, dynamic>? _summary;
  String? _error;
  bool _loading = false;
  bool _requested = false;

  Future<void> _load(BackendService backend) async {
    setState(() {
      _loading = true;
      _error = null;
      _requested = true;
    });
    try {
      final summary = await backend.datasetSummary();
      if (!mounted) return;
      setState(() => _summary = summary);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final backend = context.watch<BackendService>();
    final ai = context.watch<OnDeviceAiService>();
    if (backend.isOnline && !_requested && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_requested) _load(backend);
      });
    }
    final summary = _summary;

    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: SvAppBar(
        title: 'AutoML & Dataset Pipeline',
        actions: [
          if (backend.isOnline)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : () => _load(backend),
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          SvCard(
            highlight: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Storage & Dataset Repository',
                  style: TextStyle(
                    color: AppColors.primaryText,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Read-only view of server disk allocation, dataset splits '
                  'and catalogued training assets.',
                  style: TextStyle(color: AppColors.secondaryText),
                ),
                const SizedBox(height: 12),
                SvMetric(
                  label: 'Model bundled in this app',
                  value: ai.isModelLoaded
                      ? '${ai.modelName} · ${ai.modelInputDescription}'
                      : (ai.modelError ?? 'Loading…'),
                  icon: Icons.memory_rounded,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (!backend.isOnline)
            SvCard(
              child: SvEmptyState(
                icon: Icons.cloud_off_outlined,
                title: backend.isConfigured
                    ? 'Server offline'
                    : 'Server not configured',
                message: 'Dataset and storage information lives on the '
                    'SmartVision server (the datasets are not shipped in the '
                    'APK). Connect to the server to view it.',
                action: FilledButton(
                  onPressed: () => context.go('/settings'),
                  child: const Text('Configure server'),
                ),
              ),
            )
          else if (_loading && summary == null)
            const SvCard(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_error != null)
            SvNotice(
              tone: SvTone.error,
              message: _error!.contains('404')
                  ? 'This server does not provide /dataset/summary. Update '
                      'ai_server.py to the version shipped with this app.'
                  : _error!,
              action: TextButton(
                onPressed: () => _load(backend),
                child: const Text('Retry'),
              ),
            )
          else if (summary != null)
            ..._buildSummary(summary),
        ],
      ),
    );
  }

  List<Widget> _buildSummary(Map<String, dynamic> summary) {
    final storage = summary['storage'] as Map<String, dynamic>?;
    final splits = (summary['splits'] as Map?)?.cast<String, dynamic>() ?? {};
    final names = (summary['class_names'] as List?)?.cast<Object?>() ?? [];
    final sources = (summary['sources'] as List?) ?? const [];
    final weights = (summary['weights'] as List?) ?? const [];

    String count(Object? value) => value == null ? 'not on server' : '$value';

    return [
      if (storage != null)
        SvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SvSectionTitle('Server storage', icon: Icons.storage_rounded),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: (((storage['used_percent'] as num?) ?? 0) / 100)
                    .clamp(0.0, 1.0)
                    .toDouble(),
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Text(
                'Used ${storage['used_gb']} GB of ${storage['total_gb']} GB '
                '(${storage['used_percent']}%) · Free ${storage['free_gb']} GB',
                style: const TextStyle(color: AppColors.secondaryText),
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
              'Dataset splits',
              icon: Icons.folder_copy_outlined,
              subtitle: '${summary['dataset_root']} · '
                  '${summary['num_classes'] ?? '?'} classes',
            ),
            const SizedBox(height: 8),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.2),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(1),
              },
              children: [
                const TableRow(children: [
                  _Cell('Split', header: true),
                  _Cell('Images', header: true),
                  _Cell('Label files', header: true),
                ]),
                for (final split in const ['train', 'val', 'test'])
                  TableRow(children: [
                    _Cell(split),
                    _Cell(count((splits[split] as Map?)?['images'])),
                    _Cell(count((splits[split] as Map?)?['label_files'])),
                  ]),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '"not on server" means the folder is missing (image folders are '
              'excluded from the repository by .gitignore).',
              style: TextStyle(color: AppColors.mutedText, fontSize: 11.5),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      if (sources.isNotEmpty)
        SvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SvSectionTitle('Dataset sources',
                  icon: Icons.source_outlined),
              const SizedBox(height: 6),
              for (final source in sources)
                if (source is Map)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '${source['name'] ?? source['id']}',
                      style: const TextStyle(color: AppColors.primaryText),
                    ),
                    subtitle: Text(
                      [
                        source['type'],
                        source['format'],
                        source['license'],
                        if (source['classes'] != null)
                          '${source['classes']} classes',
                      ].whereType<Object>().join(' · '),
                      style: const TextStyle(color: AppColors.mutedText),
                    ),
                    trailing: source['status'] == null
                        ? null
                        : SvPill(
                            label: '${source['status']}'.toUpperCase(),
                            color: AppColors.accentBlue,
                          ),
                  ),
            ],
          ),
        ),
      if (weights.isNotEmpty) ...[
        const SizedBox(height: 14),
        SvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SvSectionTitle(
                'Model weights on server',
                icon: Icons.memory_outlined,
                subtitle:
                    'Active detection model: ${summary['active_detection_model']}',
              ),
              const SizedBox(height: 6),
              for (final w in weights)
                if (w is Map)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('${w['file']}',
                              style: const TextStyle(
                                  color: AppColors.secondaryText)),
                        ),
                        Text('${w['size_mb']} MB',
                            style: const TextStyle(
                                color: AppColors.mutedText)),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ],
      if (names.isNotEmpty) ...[
        const SizedBox(height: 14),
        SvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SvSectionTitle(
                'Target object categories',
                icon: Icons.label_outline_rounded,
                subtitle: '${names.length} classes',
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final name in names)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.elevatedSurface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Text(
                        '$name',
                        style: const TextStyle(
                            color: AppColors.secondaryText, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 14),
      const SvNotice(
        message: 'Training is run from the project\'s training scripts '
            '(ai/train.py, SmartVision_Train.ipynb) on a computer, not from '
            'the website or the phone, so no training job is started here.',
      ),
    ];
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.text, {this.header = false});

  final String text;
  final bool header;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Text(
        text,
        style: TextStyle(
          color: header ? AppColors.mutedText : AppColors.primaryText,
          fontSize: header ? 11.5 : 13.5,
          fontWeight: header ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
