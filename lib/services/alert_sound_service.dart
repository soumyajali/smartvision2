import 'dart:developer';

import 'package:video_player/video_player.dart';

/// Plays the project's siren (assets/sounds/siren.wav, the same file the
/// website uses) for hazard and drowsiness alerts. video_player is already a
/// dependency and can play audio-only assets.
class AlertSoundService {
  AlertSoundService._();

  static final AlertSoundService instance = AlertSoundService._();
  static const String sirenAsset = 'assets/sounds/siren.wav';

  VideoPlayerController? _controller;
  Future<void>? _loading;
  DateTime? _lastPlayed;
  String? lastError;

  bool enabled = true;

  Future<void> _ensureLoaded() {
    if (_controller != null) return Future<void>.value();
    return _loading ??= () async {
      final controller = VideoPlayerController.asset(sirenAsset);
      try {
        await controller.initialize();
        _controller = controller;
      } catch (error) {
        lastError = 'Siren sound unavailable: $error';
        log(lastError!);
        await controller.dispose();
      }
    }()
        .whenComplete(() => _loading = null);
  }

  /// Plays the siren unless it played less than [cooldown] ago.
  Future<void> playSiren({
    Duration cooldown = const Duration(milliseconds: 2500),
    bool force = false,
  }) async {
    if (!enabled && !force) return;
    final now = DateTime.now();
    final last = _lastPlayed;
    if (!force && last != null && now.difference(last) < cooldown) return;
    _lastPlayed = now;
    await _ensureLoaded();
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.seekTo(Duration.zero);
      await controller.setVolume(1.0);
      await controller.play();
    } catch (error) {
      lastError = 'Could not play siren: $error';
      log(lastError!);
    }
  }

  Future<void> stop() async {
    try {
      await _controller?.pause();
    } catch (_) {}
  }
}
