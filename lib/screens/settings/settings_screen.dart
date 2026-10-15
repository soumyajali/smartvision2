import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../controllers/detection_controller.dart';
import '../../core/config/api_config.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/supported_languages.dart';
import '../../services/backend_service.dart';
import '../../services/camera_service.dart';
import '../../services/database_service.dart';
import '../../services/on_device_ai_service.dart';
import '../../services/speech_service.dart';
import '../../widgets/detection_panels.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedLanguage = 'Hindi';

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    try {
      final saved = await context
          .read<DatabaseService>()
          .getAppSetting('translation_language');
      if (saved != null &&
          supportedTranslationLanguages.contains(saved) &&
          mounted) {
        setState(() => _selectedLanguage = saved);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load language preference: $error')),
        );
      }
    }
  }

  Future<void> _setLanguage(String language) async {
    setState(() => _selectedLanguage = language);
    try {
      await context
          .read<DatabaseService>()
          .setAppSetting('translation_language', language);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save language preference: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: const SvAppBar(title: 'Settings', showSettings: false),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // 1. Voice & Speech Synthesis Section
          _buildSectionHeader(
              'Voice & Audio Telemetry', Icons.record_voice_over_rounded),
          const SizedBox(height: 10),
          _buildVoiceSettingsCard(context),
          const SizedBox(height: 24),

          // 2. Detection & Inference Engine Section
          _buildSectionHeader('Object Detection', Icons.model_training_rounded),
          const SizedBox(height: 10),
          const DetectionSettingsCard(initiallyExpanded: true),
          const SizedBox(height: 10),
          const _SirenSettingsCard(),
          const SizedBox(height: 24),

          // Backend server (optional)
          _buildSectionHeader('Backend Server', Icons.dns_outlined),
          const SizedBox(height: 10),
          const _BackendSettingsCard(),
          const SizedBox(height: 24),

          _buildLanguageSettingsCard(),
          const SizedBox(height: 24),

          // 3. On-device AI section
          _buildSectionHeader('On-device AI', Icons.phone_android_rounded),
          const SizedBox(height: 10),
          _buildOnDeviceModelCard(),
          const SizedBox(height: 24),

          // 4. Database & Storage Management
          _buildSectionHeader('Storage & Audit Records', Icons.storage_rounded),
          const SizedBox(height: 10),
          _buildStorageCard(context),
          const SizedBox(height: 24),

          // 4. Hardware & System Status
          _buildSectionHeader('Device & Camera Permissions',
              Icons.perm_device_information_rounded),
          const SizedBox(height: 10),
          _buildSystemCard(context),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildLanguageSettingsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Preferred Translation Language',
                  style: TextStyle(
                    color: AppColors.primaryText,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Saved locally and used by OCR translation',
                  style: TextStyle(
                    color: AppColors.secondaryText,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          DropdownButton<String>(
            value: _selectedLanguage,
            dropdownColor: AppColors.elevatedSurface,
            items: supportedTranslationLanguages
                .map((language) => DropdownMenuItem(
                      value: language,
                      child: Text(language),
                    ))
                .toList(),
            onChanged: (language) {
              if (language != null) _setLanguage(language);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppColors.neonAccent, size: 18),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryText,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceSettingsCard(BuildContext context) {
    return Consumer<SpeechService>(
      builder: (context, speechService, child) {
        final settings = speechService.settings;

        return Container(
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Voice Announcements',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: AppColors.primaryText)),
                subtitle: const Text(
                    'Announce detected objects and threats via text-to-speech',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.secondaryText)),
                value: settings.enabled,
                activeTrackColor: AppColors.neonAccent,
                onChanged: (val) {
                  speechService.toggleVoice(val);
                },
                secondary: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (settings.enabled
                            ? AppColors.neonAccent
                            : AppColors.mutedText)
                        .withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    settings.enabled
                        ? Icons.volume_up_rounded
                        : Icons.volume_off_rounded,
                    color: settings.enabled
                        ? AppColors.neonAccent
                        : AppColors.mutedText,
                    size: 20,
                  ),
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Speech Rate',
                            style: TextStyle(
                                color: AppColors.primaryText,
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                        Text('${(settings.speechRate * 100).toInt()}%',
                            style: const TextStyle(
                                color: AppColors.brightViolet,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ],
                    ),
                    Slider(
                      value: settings.speechRate,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      onChanged: settings.enabled
                          ? (val) {
                              speechService.updateSettings(
                                  settings.copyWith(speechRate: val));
                            }
                          : null,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Speech Volume',
                            style: TextStyle(
                                color: AppColors.primaryText,
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                        Text('${(settings.volume * 100).toInt()}%',
                            style: const TextStyle(
                                color: AppColors.brightViolet,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ],
                    ),
                    Slider(
                      value: settings.volume,
                      min: 0.0,
                      max: 1.0,
                      divisions: 10,
                      onChanged: settings.enabled
                          ? (val) {
                              speechService.updateSettings(
                                  settings.copyWith(volume: val));
                            }
                          : null,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                      ),
                      onPressed: settings.enabled
                          ? () => speechService.speak(
                              'SmartVision audio notification test successful.')
                          : null,
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      label: const Text('Test Voice Output',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStorageCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SQLite Local Database',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: AppColors.primaryText)),
                  SizedBox(height: 2),
                  Text('On-device persistent event records',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.secondaryText)),
                ],
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.cardBackground,
                      title: const Text('Purge Database',
                          style: TextStyle(color: AppColors.primaryText)),
                      content: const Text(
                          'Clear all detection and media-analysis entries from local SQLite storage?'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel')),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.error),
                          onPressed: () {
                            context.read<DatabaseService>().clearHistory();
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Database history cleared successfully')),
                            );
                          },
                          child: const Text('Confirm Purge'),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                label: const Text('Purge All', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemCard(BuildContext context) {
    return Consumer<CameraService>(
      builder: (context, cameraService, child) {
        final perm = cameraService.permissionStatus;
        final isGranted = perm == CameraPermissionStatus.granted;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Camera Optical Sensor',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: AppColors.primaryText)),
                      const SizedBox(height: 2),
                      Text(
                        isGranted
                            ? 'Permission granted'
                            : 'Permission required for live detection',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isGranted ? AppColors.success : AppColors.warning,
                        ),
                      ),
                    ],
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6)),
                    onPressed: isGranted
                        ? cameraService.checkPermission
                        : openAppSettings,
                    child: Text(isGranted ? 'Re-check' : 'Open Settings',
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOnDeviceModelCard() {
    return Consumer<OnDeviceAiService>(
      builder: (context, ai, _) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ai.modelName,
              style: const TextStyle(
                color: AppColors.primaryText,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              ai.modelError ??
                  (ai.isModelLoaded
                      ? 'Ready. Images are analyzed on this device.'
                      : ai.isLoading
                          ? 'Loading the bundled model…'
                          : 'Model is not ready.'),
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 12,
              ),
            ),
            if (!ai.isModelLoaded && !ai.isLoading)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: ai.initialize,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry loading'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Siren for hazard and drowsiness alerts (assets/sounds/siren.wav).
class _SirenSettingsCard extends StatelessWidget {
  const _SirenSettingsCard();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DetectionController>();
    return SvCard(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: SwitchListTile(
        value: controller.sirenEnabled,
        onChanged: controller.setSirenEnabled,
        title: const Text(
          'Siren on hazard / drowsiness alerts',
          style: TextStyle(color: AppColors.primaryText, fontSize: 14),
        ),
        subtitle: const Text(
          'Plays the same siren as the website when a knife or scissors is '
          'detected, or when drowsiness is detected.',
          style: TextStyle(color: AppColors.mutedText, fontSize: 12),
        ),
        secondary: const Icon(Icons.campaign_outlined,
            color: AppColors.accentCyan),
      ),
    );
  }
}

/// Configures the optional FastAPI backend URL and shows the real health
/// check result.
class _BackendSettingsCard extends StatefulWidget {
  const _BackendSettingsCard();

  @override
  State<_BackendSettingsCard> createState() => _BackendSettingsCardState();
}

class _BackendSettingsCardState extends State<_BackendSettingsCard> {
  final TextEditingController _url = TextEditingController();
  bool _initialised = false;
  bool _saving = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save(BackendService backend, String? value) async {
    final normalized = ApiConfig.normalize(value);
    if ((value ?? '').trim().isNotEmpty && normalized == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid URL, e.g. http://192.168.1.20:8000')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await backend.setBaseUrl(normalized);
      if (!mounted) return;
      _url.text = normalized ?? '';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final backend = context.watch<BackendService>();
    if (!_initialised && backend.isLoaded) {
      _initialised = true;
      _url.text = backend.baseUrl ?? '';
    }
    final color = switch (backend.status) {
      BackendStatus.online => AppColors.success,
      BackendStatus.checking => AppColors.warning,
      BackendStatus.offline => AppColors.error,
      BackendStatus.notConfigured => AppColors.mutedText,
    };
    return SvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SvPill(label: backend.statusLabel, color: color),
              const Spacer(),
              if (backend.isOnline && backend.lastLatencyMs != null)
                Text(
                  '${backend.lastLatencyMs} ms',
                  style: const TextStyle(color: AppColors.mutedText),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: const TextStyle(color: AppColors.primaryText),
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://192.168.1.20:8000',
              prefixIcon: Icon(Icons.link_rounded),
            ),
            onSubmitted: (value) => _save(backend, value),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : () => _save(backend, _url.text),
                  child: Text(_saving ? 'Checking…' : 'Save & test'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _saving || backend.baseUrl == null
                    ? null
                    : () => _save(backend, null),
                child: const Text('Disconnect'),
              ),
            ],
          ),
          if (backend.lastError != null && !backend.isOnline) ...[
            const SizedBox(height: 10),
            SvNotice(tone: SvTone.error, message: backend.lastError!),
          ],
          const SizedBox(height: 10),
          const SvNotice(
            message: 'Optional. Detection, OCR, translation and drowsiness run '
                'on the phone without a server. Start the server on your '
                'computer with "uvicorn ai_server:app --host 0.0.0.0 --port '
                '8000" and enter the computer\'s LAN IP (not localhost). The '
                'Android emulator can use http://10.0.2.2:8000. The server '
                'adds face identity recognition, the AI chatbot provider and '
                'dataset information.',
          ),
        ],
      ),
    );
  }
}

