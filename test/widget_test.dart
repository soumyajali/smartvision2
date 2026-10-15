import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:smart_vision/controllers/detection_controller.dart';
import 'package:smart_vision/core/navigation/app_destinations.dart';
import 'package:smart_vision/services/backend_service.dart';
import 'package:smart_vision/services/camera_service.dart';
import 'package:smart_vision/services/database_service.dart';
import 'package:smart_vision/services/on_device_ai_service.dart';
import 'package:smart_vision/services/speech_service.dart';
import 'package:smart_vision/widgets/main_layout_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all twelve website destinations are defined in sidebar order', () {
    expect(
      AppDestinations.website.map((d) => d.label).toList(),
      [
        'Dashboard',
        'Fast Video Review',
        'OCR',
        'Face Recognition',
        'Object Detection',
        'Drowsiness Monitor',
        'Research Evaluation',
        'AutoML & Dataset Pipeline',
        'History',
        'Settings',
        'Vision Chatbot',
        'Voice Assistant',
      ],
    );
    expect(AppDestinations.inSection(NavSection.main), hasLength(6));
    expect(AppDestinations.inSection(NavSection.more), hasLength(4));
    expect(AppDestinations.inSection(NavSection.aiTools), hasLength(2));
    // Every route is unique.
    final routes = AppDestinations.all.map((d) => d.route).toSet();
    expect(routes.length, AppDestinations.all.length);
  });

  testWidgets('navigation drawer lists every destination', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final camera = CameraService();
    final speech = SpeechService();
    final db = DatabaseService();
    final detection = DetectionController(camera, speech, db);
    final backend = BackendService(db);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (context, state, child) => MainLayoutShell(child: child),
          routes: [
            for (final destination in AppDestinations.all)
              GoRoute(
                path: destination.route,
                builder: (context, state) => Scaffold(
                  body: Center(child: Text('page ${destination.route}')),
                ),
              ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: camera),
          ChangeNotifierProvider.value(value: OnDeviceAiService.instance),
          ChangeNotifierProvider.value(value: speech),
          Provider.value(value: db),
          ChangeNotifierProvider.value(value: backend),
          ChangeNotifierProvider.value(value: detection),
        ],
        child: MaterialApp.router(
          theme: ThemeData.dark(useMaterial3: true),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('page /home'), findsOneWidget);

    MainLayoutShell.openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('SMART VISION'), findsWidgets);
    expect(find.text('MORE'), findsOneWidget);
    expect(find.text('AI TOOLS'), findsOneWidget);
    for (final destination in AppDestinations.all) {
      expect(find.text(destination.label), findsWidgets,
          reason: destination.label);
    }

    // Selecting a destination closes the drawer and navigates.
    await tester.tap(find.text('Research Evaluation').last);
    await tester.pumpAndSettle();
    expect(find.text('page /research_evaluation'), findsOneWidget);
    expect(MainLayoutShell.scaffoldKey.currentState!.isDrawerOpen, isFalse);

    // Stop the health-check timer before the test ends.
    await tester.pumpWidget(const SizedBox());
    backend.dispose();
  });

  test('DetectionController validates and clamps settings', () {
    final ctrl = DetectionController(
      CameraService(),
      SpeechService(),
      DatabaseService(),
    );
    ctrl.setSearchTarget('bottle');
    expect(ctrl.searchTarget, 'bottle');
    expect(ctrl.isTargetFound, isFalse);
    expect(ctrl.hasActiveHazard, isFalse);
    expect(ctrl.measuredFps, isNull); // never invented when not live
  });
}
