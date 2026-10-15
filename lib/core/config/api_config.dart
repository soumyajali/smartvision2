import 'package:flutter/foundation.dart';

/// Central configuration for the optional SmartVision FastAPI backend
/// (`uvicorn ai_server:app --host 0.0.0.0 --port 8000`).
///
/// Object detection, OCR, translation and drowsiness run on the phone and do
/// NOT need the server. The server is only used for features that need models
/// which are not bundled in the APK (face identity recognition, the
/// LLM-backed Vision Chatbot, dataset/storage information).
///
/// How the URL is chosen (first match wins):
///   1. The URL saved in the app (Settings → Backend server).
///   2. A build-time value:
///        flutter build apk --dart-define=SMARTVISION_API_URL=http://192.168.1.20:8000
///   3. Debug builds only: [developmentDefault] (Android emulator → host Mac).
///   4. Otherwise: not configured (the app stays fully on-device).
///
/// Never put API keys in the app. The backend reads them from its own
/// environment (`OPENAI_API_KEY`, `GEMINI_API_KEY`).
class ApiConfig {
  const ApiConfig._();

  /// Build-time URL for release/production builds.
  static const String buildTimeUrl =
      String.fromEnvironment('SMARTVISION_API_URL', defaultValue: '');

  /// `10.0.2.2` is how the Android emulator reaches the host computer.
  /// On a physical phone use the computer's LAN IP (e.g. 192.168.1.20).
  static const String developmentDefault = 'http://10.0.2.2:8000';

  static const Duration healthTimeout = Duration(seconds: 4);
  static const Duration requestTimeout = Duration(seconds: 30);
  static const Duration uploadTimeout = Duration(minutes: 3);
  static const Duration healthPollInterval = Duration(seconds: 20);

  /// Default URL when the user has not saved one.
  static String? get defaultUrl {
    if (buildTimeUrl.isNotEmpty) return buildTimeUrl;
    if (kDebugMode) return developmentDefault;
    return null;
  }

  /// Normalises user input ("192.168.1.5:8000" → "http://192.168.1.5:8000").
  /// Returns null for an empty or invalid value.
  static String? normalize(String? input) {
    var value = (input ?? '').trim();
    if (value.isEmpty) return null;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    return value;
  }

  /// Hosts that can never be the developer's computer when running on a
  /// physical phone.
  static bool isLoopback(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0';
  }
}
