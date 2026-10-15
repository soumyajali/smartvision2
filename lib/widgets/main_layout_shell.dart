import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../controllers/detection_controller.dart';
import '../core/constants/app_colors.dart';
import '../core/navigation/app_destinations.dart';
import '../services/backend_service.dart';
import '../services/on_device_ai_service.dart';
import 'sv_app_bar.dart';
import 'sv_ui.dart';

/// Shell around every screen: navigation drawer with all twelve website
/// destinations (main features, MORE, AI TOOLS), a bottom navigation bar for
/// the primary destinations, and Android back-button handling.
class MainLayoutShell extends StatelessWidget {
  const MainLayoutShell({super.key, required this.child});

  final Widget child;

  static final GlobalKey<ScaffoldState> scaffoldKey =
      GlobalKey<ScaffoldState>(debugLabel: 'shell');

  static void openDrawer() => scaffoldKey.currentState?.openDrawer();

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final bottomIndex = AppDestinations.bottomBar
        .indexWhere((destination) => destination.route == location);
    final isHome = location == AppDestinations.dashboard.route;

    return PopScope(
      canPop: isHome,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final scaffold = scaffoldKey.currentState;
        if (scaffold != null && scaffold.isDrawerOpen) {
          scaffold.closeDrawer();
          return;
        }
        // Back from any feature returns to the dashboard; back from the
        // dashboard exits the app.
        context.go(AppDestinations.dashboard.route);
      },
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: AppColors.primaryBackground,
        drawer: _NavigationDrawer(location: location),
        drawerEdgeDragWidth: 24,
        body: child,
        bottomNavigationBar: DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.secondaryBackground,
            border: Border(top: BorderSide(color: AppColors.border, width: 0.8)),
          ),
          child: NavigationBarTheme(
            data: bottomIndex >= 0
                ? NavigationBarTheme.of(context)
                : NavigationBarTheme.of(context).copyWith(
                    labelTextStyle: const WidgetStatePropertyAll(
                      TextStyle(color: AppColors.mutedText, fontSize: 11),
                    ),
                  ),
            child: NavigationBar(
            // -1 is not allowed; when another page is open no tab is
            // highlighted by using a transparent indicator below.
            selectedIndex: bottomIndex >= 0 ? bottomIndex : 0,
            indicatorColor: bottomIndex >= 0
                ? const Color(0x2E38BDF8)
                : Colors.transparent,
            backgroundColor: AppColors.secondaryBackground,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            height: 64,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (index) {
              final route = AppDestinations.bottomBar[index].route;
              if (route != location) context.go(route);
            },
            destinations: [
              for (var i = 0; i < AppDestinations.bottomBar.length; i++)
                NavigationDestination(
                  icon: Icon(
                    AppDestinations.bottomBar[i].icon,
                    color: bottomIndex == i ? null : AppColors.mutedText,
                  ),
                  selectedIcon: Icon(
                    bottomIndex == i
                        ? AppDestinations.bottomBar[i].selectedIcon
                        : AppDestinations.bottomBar[i].icon,
                    color: bottomIndex == i
                        ? AppColors.accentCyan
                        : AppColors.mutedText,
                  ),
                  label: _shortLabel(AppDestinations.bottomBar[i]),
                ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  static String _shortLabel(AppDestination destination) {
    if (destination == AppDestinations.objectDetection) return 'Detect';
    return destination.label;
  }
}

class _NavigationDrawer extends StatelessWidget {
  const _NavigationDrawer({required this.location});

  final String location;

  void _open(BuildContext context, String route) {
    MainLayoutShell.scaffoldKey.currentState?.closeDrawer();
    if (route != location) context.go(route);
  }

  @override
  Widget build(BuildContext context) {
    final isLive = context.select<DetectionController, bool>((c) => c.isLive);
    final modelReady =
        context.select<OnDeviceAiService, bool>((ai) => ai.isModelLoaded);
    final backendLabel =
        context.select<BackendService, String>((b) => b.statusLabel);

    return Drawer(
      width: 300,
      backgroundColor: AppColors.sidebar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  SvLogo(size: 52, radius: 14),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SMART VISION',
                          style: TextStyle(
                            color: AppColors.primaryText,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Real-Time Object Detection',
                          style: TextStyle(
                            color: AppColors.secondaryText,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  SvPill(
                    label: modelReady ? 'AI ready' : 'AI loading',
                    color: modelReady ? AppColors.success : AppColors.warning,
                  ),
                  SvPill(
                    label: backendLabel,
                    color: AppColors.accentBlue,
                  ),
                  if (isLive)
                    const SvPill(
                      label: 'Live detection on',
                      color: AppColors.accentCyan,
                    ),
                ],
              ),
            ),
            const Divider(height: 12, indent: 16, endIndent: 16),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                children: [
                  for (final d in AppDestinations.inSection(NavSection.main))
                    _DrawerItem(
                      destination: d,
                      selected: d.route == location,
                      onTap: () => _open(context, d.route),
                    ),
                  const _SectionHeader('MORE'),
                  for (final d in AppDestinations.inSection(NavSection.more))
                    _DrawerItem(
                      destination: d,
                      selected: d.route == location,
                      onTap: () => _open(context, d.route),
                    ),
                  const _SectionHeader('AI TOOLS'),
                  for (final d in AppDestinations.inSection(NavSection.aiTools))
                    _DrawerItem(
                      destination: d,
                      selected: d.route == location,
                      onTap: () => _open(context, d.route),
                    ),
                  const _SectionHeader('MOBILE TOOLS'),
                  for (final d in AppDestinations.extras)
                    _DrawerItem(
                      destination: d,
                      selected: d.route == location,
                      dense: true,
                      onTap: () => _open(context, d.route),
                    ),
                ],
              ),
            ),
            InkWell(
              onTap: () => showSystemStatusSheet(context),
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.monitor_heart_outlined,
                        size: 16, color: AppColors.mutedText),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'System status',
                        style: TextStyle(
                          color: AppColors.secondaryText,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    ConnectionIndicator(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 6),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.mutedText,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Divider(height: 1)),
        ],
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  final AppDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? AppColors.accentBlue.withValues(alpha: 0.16)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? AppColors.borderStrong : Colors.transparent,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: dense ? 44 : 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    size: 21,
                    color: selected
                        ? AppColors.accentCyan
                        : AppColors.secondaryText,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      destination.label,
                      style: TextStyle(
                        color: selected
                            ? AppColors.primaryText
                            : AppColors.secondaryText,
                        fontSize: dense ? 13.5 : 14.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected)
                    Container(
                      width: 4,
                      height: 18,
                      decoration: BoxDecoration(
                        color: AppColors.accentCyan,
                        borderRadius: BorderRadius.circular(2),
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
