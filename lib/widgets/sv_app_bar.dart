import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/constants/app_colors.dart';
import '../services/backend_service.dart';
import '../services/on_device_ai_service.dart';
import 'main_layout_shell.dart';
import 'sv_ui.dart';

/// App bar used by every screen: menu button (opens the navigation drawer),
/// Smart Vision branding, the page title, a live connection indicator and a
/// settings shortcut.
class SvAppBar extends StatelessWidget implements PreferredSizeWidget {
  const SvAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.bottom,
    this.showSettings = true,
  });

  final String title;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;
  final bool showSettings;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: AppColors.secondaryBackground,
      surfaceTintColor: Colors.transparent,
      shape: const Border(
        bottom: BorderSide(color: AppColors.border, width: 0.8),
      ),
      leading: const IconButton(
        icon: Icon(Icons.menu_rounded),
        tooltip: 'Open navigation menu',
        onPressed: MainLayoutShell.openDrawer,
      ),
      titleSpacing: 0,
      title: Row(
        children: [
          const SvLogo(size: 30, radius: 8),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'SMART VISION',
                  style: TextStyle(
                    color: AppColors.accentCyan,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  ),
                ),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.primaryText,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        ...actions,
        const ConnectionIndicator(),
        if (showSettings)
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 22),
            tooltip: 'Settings',
            onPressed: () => context.go('/settings'),
          )
        else
          const SizedBox(width: 8),
      ],
      bottom: bottom,
    );
  }
}

/// Two real status lights: the on-device model and the optional backend.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key});

  static Color modelColor(OnDeviceAiService ai) {
    if (ai.isModelLoaded) return AppColors.success;
    if (ai.modelError != null) return AppColors.error;
    return AppColors.warning;
  }

  static Color backendColor(BackendService backend) {
    switch (backend.status) {
      case BackendStatus.online:
        return AppColors.success;
      case BackendStatus.checking:
        return AppColors.warning;
      case BackendStatus.offline:
        return AppColors.error;
      case BackendStatus.notConfigured:
        return AppColors.mutedText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<OnDeviceAiService>();
    final backend = context.watch<BackendService>();
    return Semantics(
      button: true,
      label: 'Connection status: on-device AI '
          '${ai.isModelLoaded ? 'ready' : 'not ready'}, ${backend.statusLabel}',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => showSystemStatusSheet(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvStatusDot(color: modelColor(ai), size: 7),
              const SizedBox(width: 4),
              const Text('AI', style: _labelStyle),
              const SizedBox(width: 8),
              SvStatusDot(color: backendColor(backend), size: 7),
              const SizedBox(width: 4),
              const Text('API', style: _labelStyle),
            ],
          ),
        ),
      ),
    );
  }

  static const TextStyle _labelStyle = TextStyle(
    color: AppColors.secondaryText,
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
  );
}

/// Bottom sheet with the real state of the on-device engine and the server.
Future<void> showSystemStatusSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.secondaryBackground,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => const _SystemStatusSheet(),
  );
}

class _SystemStatusSheet extends StatelessWidget {
  const _SystemStatusSheet();

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<OnDeviceAiService>();
    final backend = context.watch<BackendService>();
    final checked = backend.lastCheckedAt;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'System status',
              style: TextStyle(
                color: AppColors.primaryText,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            _StatusRow(
              color: ConnectionIndicator.modelColor(ai),
              title: 'On-device AI (object detection)',
              lines: [
                ai.isModelLoaded
                    ? '${ai.modelName} loaded · input ${ai.modelInputDescription}'
                    : ai.modelError ?? 'Loading model…',
                if (ai.isModelLoaded)
                  ai.usesBackgroundIsolate
                      ? 'Inference runs in a background isolate.'
                      : 'Inference runs on the main isolate (worker unavailable).',
                'OCR, translation and face/eye detection use Google ML Kit on the phone.',
              ],
              action: ai.modelError != null
                  ? TextButton(
                      onPressed: ai.initialize,
                      child: const Text('Retry loading model'),
                    )
                  : null,
            ),
            const SizedBox(height: 12),
            _StatusRow(
              color: ConnectionIndicator.backendColor(backend),
              title: 'Backend server (optional)',
              lines: [
                backend.baseUrl == null
                    ? 'No server configured — the app works fully on-device. '
                        'A server is only needed for face identity, the '
                        'AI chatbot provider and dataset information.'
                    : '${backend.statusLabel} · ${backend.baseUrl}',
                if (backend.lastLatencyMs != null && backend.isOnline)
                  'Health check answered in ${backend.lastLatencyMs} ms.',
                if (backend.isOnline && backend.serverInfo != null)
                  'Server model: ${backend.serverInfo!['detection_model'] ?? '?'} · '
                      'face recognition '
                      '${backend.serverInfo!['face_recognition_available'] == true ? 'available' : 'unavailable'} · '
                      'OCR ${backend.serverInfo!['ocr_available'] == true ? 'available' : 'unavailable'}',
                if (backend.lastError != null && !backend.isOnline)
                  backend.lastError!,
                if (checked != null)
                  'Last checked ${TimeOfDay.fromDateTime(checked).format(context)}.',
              ],
              action: Wrap(
                spacing: 8,
                children: [
                  if (backend.baseUrl != null)
                    TextButton(
                      onPressed: backend.checkHealth,
                      child: const Text('Check now'),
                    ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      context.go('/settings');
                    },
                    child: const Text('Configure'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.color,
    required this.title,
    required this.lines,
    this.action,
  });

  final Color color;
  final String title;
  final List<String> lines;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SvCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: SvStatusDot(color: color, size: 10),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.primaryText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      line,
                      style: const TextStyle(
                        color: AppColors.secondaryText,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                if (action != null) action!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
