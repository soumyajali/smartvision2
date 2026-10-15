import '../core/navigation/app_destinations.dart';
import '../models/detection_result.dart';

/// Mobile port of the website's assistant logic (voice_interaction.py):
/// command parsing, feature questions and latest-result questions.
/// Anything it cannot answer from real app data returns null so the caller
/// can ask the server's chatbot (or say it does not know).

enum AssistantAction { navigate, announcements, tracking, resetAnnouncements, question, unknown }

class AssistantCommand {
  const AssistantCommand(this.action, [this.value = '']);

  final AssistantAction action;
  final String value;
}

class AssistantBrain {
  const AssistantBrain._();

  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .join(' ');

  /// Same commands and phrasing as parse_voice_command() on the website.
  static AssistantCommand parse(String transcript) {
    final normalized = _normalize(transcript);
    const commands = <String, AssistantCommand>{
      'enable voice announcements':
          AssistantCommand(AssistantAction.announcements, 'on'),
      'turn on voice announcements':
          AssistantCommand(AssistantAction.announcements, 'on'),
      'disable voice announcements':
          AssistantCommand(AssistantAction.announcements, 'off'),
      'turn off voice announcements':
          AssistantCommand(AssistantAction.announcements, 'off'),
      'enable object tracking': AssistantCommand(AssistantAction.tracking, 'on'),
      'start object tracking': AssistantCommand(AssistantAction.tracking, 'on'),
      'disable object tracking':
          AssistantCommand(AssistantAction.tracking, 'off'),
      'stop object tracking': AssistantCommand(AssistantAction.tracking, 'off'),
      'reset voice announcements':
          AssistantCommand(AssistantAction.resetAnnouncements),
      'clear voice announcements':
          AssistantCommand(AssistantAction.resetAnnouncements),
    };
    final command = commands[normalized];
    if (command != null) return command;

    String? target;
    for (final prefix in const ['open ', 'go to ', 'navigate to ', 'take me to ']) {
      if (normalized.startsWith(prefix)) {
        target = normalized.substring(prefix.length);
        break;
      }
    }
    if (target == null) {
      return AssistantCommand(AssistantAction.question, transcript.trim());
    }
    final destination = _matchDestination(target);
    if (destination != null) {
      return AssistantCommand(AssistantAction.navigate, destination.route);
    }
    return const AssistantCommand(AssistantAction.unknown);
  }

  static AppDestination? _matchDestination(String target) {
    const aliases = <String, String>{
      'home': '/home',
      'dashboard': '/home',
      'video review': '/video_review',
      'fast video review': '/video_review',
      'video fast review': '/video_review',
      'ocr': '/document_screening',
      'text recognition': '/document_screening',
      'face recognition': '/face_id',
      'face registration': '/face_id',
      'object detection': '/camera_detection',
      'detection': '/camera_detection',
      'camera': '/camera_detection',
      'drowsiness monitor': '/drowsiness',
      'drowsiness': '/drowsiness',
      'research evaluation': '/research_evaluation',
      'automl': '/automl',
      'auto ml': '/automl',
      'automl dataset pipeline': '/automl',
      'automl and dataset pipeline': '/automl',
      'dataset pipeline': '/automl',
      'history': '/history',
      'settings': '/settings',
      'vision chatbot': '/chatbot',
      'chatbot': '/chatbot',
      'voice assistant': '/voice_assistant',
      'analytics': '/statistics',
      'hazard alerts': '/alerts',
      'find my item': '/find_object',
      'about': '/about',
    };
    final route = aliases[target];
    if (route != null) return AppDestinations.forRoute(route);
    for (final destination in AppDestinations.all) {
      if (_normalize(destination.label) == target) return destination;
    }
    return null;
  }

  static const List<(List<String>, String)> _features = [
    (
      ['dashboard', 'home page', 'live detection', 'real time detection'],
      'The Dashboard shows live detection status, the camera preview with '
          'bounding boxes, a detection summary, detection settings and recent '
          'activity. You can start camera detection or upload and capture images.',
    ),
    (
      ['object detection', 'detect objects', 'object recognition', 'yolo'],
      'Object Detection runs the bundled YOLOv8n model on the phone for live '
          'camera frames, photos and videos, and shows labels, confidence scores '
          'and boxes.',
    ),
    (
      ['vision chatbot', 'chatbot', 'typed questions'],
      'Vision Chatbot answers typed questions about the latest detections. '
          'When the SmartVision server is connected it uses the same assistant '
          'as the website.',
    ),
    (
      ['voice assistant', 'voice control', 'voice commands', 'voice question'],
      'Voice Assistant accepts spoken questions and commands. It can explain '
          'features, describe the latest results, open pages and switch voice '
          'announcements on or off. Speech recognition uses the phone\'s '
          'speech service, which may send audio to Google.',
    ),
    (
      ['ocr', 'read text', 'text recognition', 'translate', 'translation'],
      'OCR extracts text from photos and videos on the phone, and can '
          'translate or summarize the extracted text with separate buttons.',
    ),
    (
      ['face registration', 'face recognition', 'register face', 'facial recognition'],
      'Face Recognition detects faces on the phone. Recognizing or registering '
          'people uses the SmartVision server\'s face models.',
    ),
    (
      ['history', 'detection history', 'saved detections'],
      'History shows detections and analyses saved on this phone.',
    ),
    (
      ['video fast review', 'search video', 'find in video', 'video search'],
      'Fast Video Review scans a video for a selected object category and '
          'reports the timestamps where it appears.',
    ),
    (
      ['drowsiness', 'fatigue', 'driver monitoring'],
      'Drowsiness Monitor watches your eyes with the front camera and raises '
          'an alert when they stay closed too long. It can also analyse a video.',
    ),
    (
      ['research evaluation', 'benchmark'],
      'Research Evaluation runs a real benchmark of the on-device model and '
          'shows the comparison figures reported on the website.',
    ),
    (
      ['automl', 'dataset', 'dataset pipeline'],
      'AutoML and Dataset Pipeline shows the server\'s dataset splits, sources, '
          'classes and storage.',
    ),
    (
      ['settings', 'preferences', 'confidence threshold'],
      'Settings control voice announcements, detection thresholds, the siren, '
          'translation language and the optional server connection.',
    ),
  ];

  /// Answers feature questions; null when the question is about results or
  /// unknown.
  static String? answerApplicationQuestion(String question) {
    final normalized = _normalize(question);
    if (normalized.isEmpty) return null;
    if (isSceneQuestion(normalized) || isOcrQuestion(normalized)) return null;
    for (final (terms, description) in _features) {
      if (terms.any(normalized.contains)) return description;
    }
    const appPhrases = [
      'this application',
      'this app',
      'the app',
      'what can you do',
      'what features',
      'available features',
      'app features',
      'what are the features',
      'list the features',
    ];
    if (appPhrases.any(normalized.contains)) {
      return 'SmartVision can detect objects live or in photos and videos, read '
          'and translate text, detect faces, review videos for an object, '
          'monitor drowsiness, and keep a history of results. It also has a '
          'chatbot and this voice assistant. Ask me about any feature.';
    }
    return null;
  }

  static bool isSceneQuestion(String normalized) => const [
        'what do you see',
        'what can you see',
        'what is in',
        'describe the scene',
        'what did it detect',
        'what has been detected',
        'detection result',
        'explain the results',
        'explain the output',
        'how many',
        'what objects',
        'any hazard',
        'is there',
        'are there',
      ].any(normalized.contains);

  static bool isOcrQuestion(String normalized) => const [
        'what did ocr read',
        'ocr result',
        'extracted text',
        'recognized text',
        'read the text',
      ].any(normalized.contains);

  /// Describes the latest real detection result (same wording style as
  /// answer_scene_question on the website).
  static String describeDetections(
    List<DetectionResult> results, {
    required bool hasResult,
  }) {
    if (!hasResult) {
      return "I don't have a recent detection result yet. Open Object "
          'Detection, analyse an image or start live detection, then ask me '
          'again.';
    }
    if (results.isEmpty) {
      return 'The latest object-detection output contains no objects above '
          'the confidence threshold.';
    }
    final grouped = <String, List<double>>{};
    for (final r in results) {
      grouped.putIfAbsent(r.label, () => []).add(r.confidence);
    }
    final parts = grouped.entries.map((entry) {
      final count = entry.value.length;
      final avg = entry.value.reduce((a, b) => a + b) / count;
      return '$count ${entry.key}${count == 1 ? '' : 's'} '
          '(average confidence ${(avg * 100).toStringAsFixed(0)}%)';
    }).join(', ');
    final hazards =
        results.where((r) => r.isHazard).map((r) => r.label).toSet();
    return 'The latest object-detection output recognized $parts.'
        '${hazards.isEmpty ? '' : ' Hazards: ${hazards.join(', ')}.'}'
        ' This is based on detected labels, not full scene understanding.';
  }
}
