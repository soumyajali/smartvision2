import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'controllers/detection_controller.dart';
import 'controllers/statistics_controller.dart';
import 'services/backend_service.dart';
import 'services/camera_service.dart';
import 'services/database_service.dart';
import 'services/on_device_ai_service.dart';
import 'services/speech_service.dart';
import 'services/statistics_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The detection overlay maps boxes for a portrait UI; camera frames are
  // rotated with the sensor orientation accordingly.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CameraService()),
        ChangeNotifierProvider.value(
          value: OnDeviceAiService.instance..initialize(),
        ),
        ChangeNotifierProvider(create: (_) => SpeechService()..initialize()),
        Provider<DatabaseService>(create: (_) => DatabaseService()),
        ChangeNotifierProxyProvider<DatabaseService, BackendService>(
          create: (context) => BackendService(context.read<DatabaseService>()),
          update: (context, db, previous) => previous ?? BackendService(db),
        ),
        ProxyProvider<DatabaseService, StatisticsService>(
          create: (context) =>
              StatisticsService(context.read<DatabaseService>()),
          update: (context, db, previous) => previous ?? StatisticsService(db),
        ),
        ChangeNotifierProxyProvider<StatisticsService, StatisticsController>(
          create: (context) =>
              StatisticsController(context.read<StatisticsService>()),
          update: (context, statsService, previous) =>
              previous ?? StatisticsController(statsService),
        ),
        ChangeNotifierProxyProvider3<CameraService, SpeechService,
            DatabaseService, DetectionController>(
          create: (context) => DetectionController(
            context.read<CameraService>(),
            context.read<SpeechService>(),
            context.read<DatabaseService>(),
          ),
          update: (context, camera, speech, db, previous) =>
              previous ?? DetectionController(camera, speech, db),
        ),
      ],
      child: const SmartVisionApp(),
    ),
  );
}
