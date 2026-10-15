import 'dart:io';

import 'package:flutter/services.dart';

class VoiceInputException implements Exception {
  VoiceInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Speech-to-text through the Android system speech recognizer
/// (MainActivity.kt, channel "com.smartvision/speech"). The system dialog
/// records the audio itself, so no microphone permission is requested by the
/// app. Recognition may use Google's online service, like the website.
class VoiceInputService {
  const VoiceInputService._();

  static const MethodChannel _channel = MethodChannel('com.smartvision/speech');

  static Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Returns the recognised text, or null if the user cancelled / nothing was
  /// recognised.
  static Future<String?> listen({
    String prompt = 'Ask SmartVision',
    String? languageTag,
  }) async {
    if (!Platform.isAndroid) {
      throw VoiceInputException(
          'Voice input is implemented for Android in this build.');
    }
    try {
      final text = await _channel.invokeMethod<String>('listen', {
        'prompt': prompt,
        if (languageTag != null) 'language': languageTag,
      });
      final clean = text?.trim();
      return clean == null || clean.isEmpty ? null : clean;
    } on PlatformException catch (error) {
      throw VoiceInputException(error.message ?? error.code);
    } on MissingPluginException {
      throw VoiceInputException('Speech recognition is not available.');
    }
  }
}
