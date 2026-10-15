import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_vision/models/detection_result.dart';
import 'package:smart_vision/services/assistant_brain.dart';

void main() {
  test('parses website voice commands', () {
    expect(AssistantBrain.parse('Turn off voice announcements.').action,
        AssistantAction.announcements);
    final nav = AssistantBrain.parse('Open Object Detection');
    expect(nav.action, AssistantAction.navigate);
    expect(nav.value, '/camera_detection');
    expect(AssistantBrain.parse('go to AutoML & Dataset Pipeline').value,
        '/automl');
    expect(AssistantBrain.parse('open the moon').action,
        AssistantAction.unknown);
    expect(AssistantBrain.parse('What is OCR?').action,
        AssistantAction.question);
  });

  test('answers feature questions but not result questions', () {
    expect(AssistantBrain.answerApplicationQuestion('Tell me about OCR'),
        contains('OCR'));
    expect(AssistantBrain.answerApplicationQuestion('What do you see?'),
        isNull);
  });

  test('describes only real detection results', () {
    expect(
      AssistantBrain.describeDetections(const [], hasResult: false),
      contains("don't have a recent detection"),
    );
    final text = AssistantBrain.describeDetections([
      DetectionResult(
        label: 'person',
        confidence: 0.9,
        boundingBox: const Rect.fromLTRB(0, 0, 1, 1),
      ),
      DetectionResult(
        label: 'person',
        confidence: 0.7,
        boundingBox: const Rect.fromLTRB(0, 0, 1, 1),
      ),
    ], hasResult: true);
    expect(text, contains('2 persons'));
    expect(text, contains('80%'));
  });
}
