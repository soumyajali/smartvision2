import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../controllers/detection_controller.dart';
import '../../core/constants/app_colors.dart';
import '../../core/navigation/app_destinations.dart';
import '../../services/assistant_brain.dart';
import '../../services/backend_service.dart';
import '../../services/speech_service.dart';
import '../../services/voice_input_service.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

class _Turn {
  const _Turn({required this.question, required this.answer, this.source});

  final String question;
  final String answer;
  final String? source;
}

/// Voice Assistant: spoken (or typed) questions and commands → answers that
/// are spoken back with text-to-speech. Mirrors the website's assistant.
class VoiceAssistantScreen extends StatefulWidget {
  const VoiceAssistantScreen({super.key});

  @override
  State<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen> {
  final TextEditingController _input = TextEditingController();
  final List<_Turn> _turns = [];
  bool? _speechAvailable;
  bool _listening = false;
  bool _thinking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    VoiceInputService.isAvailable().then((value) {
      if (mounted) setState(() => _speechAvailable = value);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    if (_listening || _thinking) return;
    setState(() {
      _listening = true;
      _error = null;
    });
    try {
      final text = await VoiceInputService.listen(
        prompt: 'Ask SmartVision a question or say a command',
      );
      if (!mounted) return;
      setState(() => _listening = false);
      if (text == null) {
        setState(() => _error = 'Nothing was recognised. Tap the microphone '
            'and speak clearly, or type your question.');
        return;
      }
      await _handle(text);
    } on VoiceInputException catch (error) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = error.message;
      });
    }
  }

  Future<void> _handle(String message) async {
    final text = message.trim();
    if (text.isEmpty) return;
    final speech = context.read<SpeechService>();
    final detection = context.read<DetectionController>();
    final backend = context.read<BackendService>();
    setState(() {
      _thinking = true;
      _error = null;
    });

    var answer = '';
    String source = 'on-device';
    String? navigateTo;
    final command = AssistantBrain.parse(text);
    switch (command.action) {
      case AssistantAction.navigate:
        final destination = AppDestinations.forRoute(command.value);
        answer = 'Opening ${destination?.label ?? 'page'}.';
        navigateTo = command.value;
        break;
      case AssistantAction.announcements:
        final on = command.value == 'on';
        speech.toggleVoice(on);
        answer = 'Voice announcements turned ${command.value}.';
        break;
      case AssistantAction.tracking:
        answer = 'Object tracking across frames is only available on the '
            'website. The mobile app reports detections per frame.';
        break;
      case AssistantAction.resetAnnouncements:
        await speech.stop();
        answer = 'Voice announcements reset.';
        break;
      case AssistantAction.unknown:
        answer = "I couldn't find that page. Try \"open object detection\" or "
            '"go to history".';
        break;
      case AssistantAction.question:
        final normalized = text.toLowerCase();
        final feature = AssistantBrain.answerApplicationQuestion(text);
        if (feature != null) {
          answer = feature;
        } else if (AssistantBrain.isSceneQuestion(normalized)) {
          answer = AssistantBrain.describeDetections(
            detection.currentResults,
            hasResult: detection.lastOutcome != null,
          );
        } else if (backend.isOnline) {
          try {
            answer = await backend.chatbotQuery(
              query: text,
              detections: [
                for (final r in detection.currentResults)
                  {'label': r.label, 'confidence': r.confidence},
              ],
              counts: Map<String, int>.from(detection.objectCounts),
            );
            source = 'SmartVision server';
          } catch (error) {
            answer = 'The SmartVision server could not answer ($error).';
          }
        } else {
          answer = "I can answer questions about SmartVision's features and "
              'the latest detection results. For open-ended questions, '
              'connect the SmartVision server in Settings.';
        }
        break;
    }

    if (!mounted) return;
    setState(() {
      _thinking = false;
      _turns.insert(
          0, _Turn(question: text, answer: answer, source: source));
    });
    _input.clear();
    await speech.speakAnswer(answer);
    if (navigateTo != null && mounted) {
      context.go(navigateTo);
    }
  }

  @override
  Widget build(BuildContext context) {
    final speech = context.watch<SpeechService>();
    final available = _speechAvailable;
    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: const SvAppBar(title: 'Voice Assistant'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          SvCard(
            highlight: true,
            child: Column(
              children: [
                const Text(
                  'SmartVision Voice Assistant',
                  style: TextStyle(
                    color: AppColors.accentCyan,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Ask a question or give a command',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.primaryText,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 18),
                Semantics(
                  button: true,
                  label: 'Speak a question',
                  child: GestureDetector(
                    onTap: available == false ? null : _listen,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: available == false
                            ? null
                            : AppColors.primaryGradient,
                        color: available == false
                            ? AppColors.elevatedSurface
                            : null,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accentCyan.withValues(
                                alpha: _listening ? 0.55 : 0.25),
                            blurRadius: _listening ? 30 : 16,
                            spreadRadius: _listening ? 4 : 0,
                          ),
                        ],
                      ),
                      child: Icon(
                        _listening ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                        color: Colors.white,
                        size: 42,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  available == null
                      ? 'Checking speech recognition…'
                      : available
                          ? (_listening
                              ? 'Listening…'
                              : _thinking
                                  ? 'Thinking…'
                                  : 'Tap the microphone to speak')
                          : 'Speech recognition is not available on this '
                              'device. Type your question below.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.secondaryText),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        enabled: !_thinking,
                        style: const TextStyle(color: AppColors.primaryText),
                        textInputAction: TextInputAction.send,
                        onSubmitted: _handle,
                        decoration: const InputDecoration(
                          hintText: 'Or type, e.g. "what do you see?"',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Send',
                      onPressed:
                          _thinking ? null : () => _handle(_input.text),
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: speech.settings.enabled,
                  onChanged: speech.toggleVoice,
                  title: const Text(
                    'Automatic detection announcements',
                    style: TextStyle(color: AppColors.primaryText, fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Answers here are always spoken aloud.',
                    style: TextStyle(color: AppColors.mutedText, fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            SvNotice(tone: SvTone.warning, message: _error!),
          ],
          const SizedBox(height: 14),
          SvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SvSectionTitle('Try saying', icon: Icons.lightbulb_outline),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final example in const [
                      'What do you see?',
                      'What features does this app have?',
                      'Tell me about OCR',
                      'Open object detection',
                      'Go to history',
                      'Turn off voice announcements',
                    ])
                      ActionChip(
                        label: Text(example),
                        labelStyle: const TextStyle(
                            color: AppColors.secondaryText, fontSize: 12),
                        backgroundColor: AppColors.elevatedSurface,
                        side: const BorderSide(color: AppColors.border),
                        onPressed: _thinking ? null : () => _handle(example),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_turns.isEmpty)
            const SvCard(
              child: SvEmptyState(
                icon: Icons.record_voice_over_outlined,
                title: 'No questions yet',
                message: 'Your questions and the assistant\'s answers appear '
                    'here.',
              ),
            )
          else
            for (final turn in _turns)
              SvCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '“${turn.question}”',
                      style: const TextStyle(
                        color: AppColors.accentCyan,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      turn.answer,
                      style: const TextStyle(
                        color: AppColors.primaryText,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Answered by: ${turn.source ?? 'on-device'}',
                            style: const TextStyle(
                                color: AppColors.mutedText, fontSize: 11),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Speak again',
                          onPressed: () => speech.speakAnswer(turn.answer),
                          icon: const Icon(Icons.volume_up_outlined,
                              size: 18, color: AppColors.mutedText),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
