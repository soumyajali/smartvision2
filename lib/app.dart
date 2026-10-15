import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'screens/about/about_screen.dart';
import 'screens/analytics/analytics_screen.dart';
import 'screens/automl/automl_screen.dart';
import 'screens/camera_detection/camera_detection_screen.dart';
import 'screens/chatbot/vision_chatbot_screen.dart';
import 'screens/danger_alert/danger_alert_screen.dart';
import 'screens/document_screening/document_screening_screen.dart';
import 'screens/drowsiness/drowsiness_monitor_screen.dart';
import 'screens/face_recognition/face_recognition_screen.dart';
import 'screens/find_object/find_object_screen.dart';
import 'screens/history/history_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/research/research_evaluation_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/splash/splash_screen.dart';
import 'screens/video_review/video_fast_review_screen.dart';
import 'screens/voice_assistant/voice_assistant_screen.dart';
import 'widgets/main_layout_shell.dart';

class SmartVisionApp extends StatelessWidget {
  const SmartVisionApp({super.key});

  /// Created once so navigation state survives rebuilds.
  static final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: const SplashScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ),
      ShellRoute(
        builder: (context, state, child) => MainLayoutShell(child: child),
        routes: [
          _route('/home', const HomeScreen()),
          _route('/video_review', const VideoFastReviewScreen()),
          _route('/document_screening', const DocumentScreeningScreen()),
          _route('/face_id', const FaceRecognitionScreen()),
          _route('/camera_detection', const CameraDetectionScreen()),
          _route('/drowsiness', const DrowsinessMonitorScreen()),
          _route('/research_evaluation', const ResearchEvaluationScreen()),
          _route('/automl', const AutoMlScreen()),
          _route('/history', const HistoryScreen()),
          _route('/settings', const SettingsScreen()),
          _route('/chatbot', const VisionChatbotScreen()),
          _route('/voice_assistant', const VoiceAssistantScreen()),
          // Additional mobile tools that already existed in the app.
          _route('/find_object', const FindObjectScreen()),
          _route('/alerts', const DangerAlertScreen()),
          _route('/statistics', const AnalyticsScreen()),
          _route('/about', const AboutScreen()),
        ],
      ),
    ],
  );

  static GoRoute _route(String path, Widget screen) {
    return GoRoute(
      path: path,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: screen,
        transitionDuration: const Duration(milliseconds: 180),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Smart Vision',
      themeMode: ThemeMode.dark,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
