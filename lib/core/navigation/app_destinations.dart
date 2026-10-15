import 'package:flutter/material.dart';

enum NavSection { main, more, aiTools, extra }

class AppDestination {
  const AppDestination({
    required this.label,
    required this.route,
    required this.icon,
    required this.selectedIcon,
    required this.section,
    this.subtitle,
  });

  final String label;
  final String route;
  final IconData icon;
  final IconData selectedIcon;
  final NavSection section;
  final String? subtitle;
}

/// Every destination in the website sidebar, in the same order and sections
/// (main features, MORE, AI TOOLS), plus the extra mobile-only tools that
/// already existed in the app.
class AppDestinations {
  const AppDestinations._();

  static const dashboard = AppDestination(
    label: 'Dashboard',
    route: '/home',
    icon: Icons.space_dashboard_outlined,
    selectedIcon: Icons.space_dashboard_rounded,
    section: NavSection.main,
  );
  static const videoReview = AppDestination(
    label: 'Fast Video Review',
    route: '/video_review',
    icon: Icons.fast_forward_outlined,
    selectedIcon: Icons.fast_forward_rounded,
    section: NavSection.main,
  );
  static const ocr = AppDestination(
    label: 'OCR',
    route: '/document_screening',
    icon: Icons.document_scanner_outlined,
    selectedIcon: Icons.document_scanner_rounded,
    section: NavSection.main,
  );
  static const faceRecognition = AppDestination(
    label: 'Face Recognition',
    route: '/face_id',
    icon: Icons.face_outlined,
    selectedIcon: Icons.face_rounded,
    section: NavSection.main,
  );
  static const objectDetection = AppDestination(
    label: 'Object Detection',
    route: '/camera_detection',
    icon: Icons.center_focus_weak_outlined,
    selectedIcon: Icons.center_focus_strong_rounded,
    section: NavSection.main,
  );
  static const drowsiness = AppDestination(
    label: 'Drowsiness Monitor',
    route: '/drowsiness',
    icon: Icons.bedtime_outlined,
    selectedIcon: Icons.bedtime_rounded,
    section: NavSection.main,
  );
  static const research = AppDestination(
    label: 'Research Evaluation',
    route: '/research_evaluation',
    icon: Icons.science_outlined,
    selectedIcon: Icons.science_rounded,
    section: NavSection.more,
  );
  static const automl = AppDestination(
    label: 'AutoML & Dataset Pipeline',
    route: '/automl',
    icon: Icons.dataset_outlined,
    selectedIcon: Icons.dataset_rounded,
    section: NavSection.more,
  );
  static const history = AppDestination(
    label: 'History',
    route: '/history',
    icon: Icons.history_outlined,
    selectedIcon: Icons.history_rounded,
    section: NavSection.more,
  );
  static const settings = AppDestination(
    label: 'Settings',
    route: '/settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
    section: NavSection.more,
  );
  static const chatbot = AppDestination(
    label: 'Vision Chatbot',
    route: '/chatbot',
    icon: Icons.chat_bubble_outline_rounded,
    selectedIcon: Icons.chat_bubble_rounded,
    section: NavSection.aiTools,
  );
  static const voiceAssistant = AppDestination(
    label: 'Voice Assistant',
    route: '/voice_assistant',
    icon: Icons.mic_none_rounded,
    selectedIcon: Icons.mic_rounded,
    section: NavSection.aiTools,
  );

  // Extra tools that already existed in the mobile app.
  static const findObject = AppDestination(
    label: 'Find My Item',
    route: '/find_object',
    icon: Icons.manage_search_outlined,
    selectedIcon: Icons.manage_search_rounded,
    section: NavSection.extra,
  );
  static const hazardAlerts = AppDestination(
    label: 'Hazard Alerts',
    route: '/alerts',
    icon: Icons.warning_amber_outlined,
    selectedIcon: Icons.warning_rounded,
    section: NavSection.extra,
  );
  static const analytics = AppDestination(
    label: 'Analytics',
    route: '/statistics',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights_rounded,
    section: NavSection.extra,
  );
  static const about = AppDestination(
    label: 'About',
    route: '/about',
    icon: Icons.info_outline_rounded,
    selectedIcon: Icons.info_rounded,
    section: NavSection.extra,
  );

  /// The twelve website destinations, in sidebar order.
  static const List<AppDestination> website = [
    dashboard,
    videoReview,
    ocr,
    faceRecognition,
    objectDetection,
    drowsiness,
    research,
    automl,
    history,
    settings,
    chatbot,
    voiceAssistant,
  ];

  static const List<AppDestination> extras = [
    findObject,
    hazardAlerts,
    analytics,
    about,
  ];

  static const List<AppDestination> all = [...website, ...extras];

  /// Bottom navigation (primary destinations).
  static const List<AppDestination> bottomBar = [
    dashboard,
    objectDetection,
    ocr,
    history,
  ];

  static List<AppDestination> inSection(NavSection section) =>
      website.where((d) => d.section == section).toList(growable: false);

  static AppDestination? forRoute(String route) {
    for (final destination in all) {
      if (destination.route == route) return destination;
    }
    return null;
  }
}
