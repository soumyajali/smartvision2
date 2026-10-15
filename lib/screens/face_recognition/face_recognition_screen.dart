import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_colors.dart';
import '../../models/detection_result.dart';
import '../../services/backend_service.dart';
import '../../services/database_service.dart';
import '../../services/on_device_ai_service.dart';
import '../../widgets/detection_overlay.dart';
import '../../widgets/sv_app_bar.dart';
import '../../widgets/sv_ui.dart';

/// Face Recognition.
///
/// * Face detection runs on the phone (Google ML Kit).
/// * Identity recognition and registration use the website's own pipeline on
///   the FastAPI backend (POST /face/recognize and /face/register, YuNet +
///   SFace embeddings). The phone never guesses an identity by itself.
class FaceRecognitionScreen extends StatefulWidget {
  const FaceRecognitionScreen({super.key});

  @override
  State<FaceRecognitionScreen> createState() => _FaceRecognitionScreenState();
}

class _FaceRecognitionScreenState extends State<FaceRecognitionScreen> {
  final OnDeviceAiService _aiService = OnDeviceAiService.instance;
  final TextEditingController _nameController = TextEditingController();
  bool _hasConsent = false;
  bool _isScanning = false;
  bool _isRecognizing = false;
  bool _isRegistering = false;
  Uint8List? _imageBytes;
  Size? _imageSize;
  List<DetectionResult> _faces = const [];
  List<Map<String, dynamic>>? _recognitions;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<Size> _decodeSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final size = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      return size;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _selectImage(ImageSource source) async {
    if (!_hasConsent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Consent is required before processing face images.'),
        ),
      );
      return;
    }
    try {
      final image = await ImagePicker().pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );
      if (image == null || !mounted) return;
      setState(() {
        _isScanning = true;
        _error = null;
        _info = null;
        _faces = const [];
        _recognitions = null;
        _imageBytes = null;
      });
      final bytes = await image.readAsBytes();
      final size = await _decodeSize(bytes);
      final faces = await _aiService.detectFacesFromBytes(bytes);
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _imageBytes = bytes;
        _imageSize = size;
        _faces = [
          for (final face in faces)
            DetectionResult(
              label: 'face',
              confidence: -1, // ML Kit gives no detection score
              boundingBox: Rect.fromLTRB(
                face.boundingBox.left / size.width,
                face.boundingBox.top / size.height,
                face.boundingBox.right / size.width,
                face.boundingBox.bottom / size.height,
              ),
            ),
        ];
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _error = 'On-device face detection failed: $error';
      });
    }
  }

  Future<void> _recognize(BackendService backend) async {
    final bytes = _imageBytes;
    final size = _imageSize;
    if (bytes == null || size == null) return;
    setState(() {
      _isRecognizing = true;
      _error = null;
      _info = null;
    });
    try {
      final recognitions = await backend.recognizeFace(bytes);
      if (!mounted) return;
      setState(() => _recognitions = recognitions);
      final names = recognitions.map((r) => r['name']).join(', ');
      try {
        await context.read<DatabaseService>().insertAnalysisHistory(
              analysisType: 'Face Recognition',
              summary: recognitions.isEmpty
                  ? 'No face recognised by the server'
                  : names,
              details: {'recognitions': recognitions},
            );
      } catch (_) {}
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Recognition failed: $error');
    } finally {
      if (mounted) setState(() => _isRecognizing = false);
    }
  }

  Future<void> _register(BackendService backend) async {
    final bytes = _imageBytes;
    final name = _nameController.text.trim();
    if (bytes == null) return;
    if (name.isEmpty) {
      setState(() => _error = 'Enter the person\'s name to register.');
      return;
    }
    if (_faces.length != 1) {
      setState(() => _error = _faces.isEmpty
          ? 'No face was detected in this image, so it cannot be registered.'
          : 'Use an image with exactly one face to register a person.');
      return;
    }
    setState(() {
      _isRegistering = true;
      _error = null;
      _info = null;
    });
    try {
      final message = await backend.registerFace(name: name, imageBytes: bytes);
      if (!mounted) return;
      setState(() => _info = message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Registration failed: $error');
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  List<DetectionResult> get _overlayBoxes {
    final recognitions = _recognitions;
    final size = _imageSize;
    if (recognitions == null || size == null) return _faces;
    final boxes = <DetectionResult>[];
    for (final r in recognitions) {
      final box = r['box'];
      if (box is List && box.length == 4) {
        final values = box.map((v) => (v as num).toDouble()).toList();
        boxes.add(DetectionResult(
          label: r['name']?.toString() ?? 'Not Registered',
          confidence: ((r['confidence'] as num?) ?? 0).toDouble(),
          // ai_server.py returns YuNet boxes as [x, y, width, height].
          boundingBox: Rect.fromLTWH(
            values[0] / size.width,
            values[1] / size.height,
            values[2] / size.width,
            values[3] / size.height,
          ),
        ));
      }
    }
    return boxes.isEmpty ? _faces : boxes;
  }

  @override
  Widget build(BuildContext context) {
    final backend = context.watch<BackendService>();
    final bytes = _imageBytes;
    final size = _imageSize;
    final recognitions = _recognitions;

    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      appBar: const SvAppBar(title: 'Face Recognition'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          SvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SvSectionTitle(
                  'Face detection & recognition',
                  icon: Icons.face_retouching_natural_outlined,
                  subtitle: 'Detection on the phone · identity via the '
                      'SmartVision server',
                ),
                const SizedBox(height: 12),
                const SvNotice(
                  icon: Icons.privacy_tip_outlined,
                  message: 'Confirm you have the subject\'s consent. Face '
                      'detection stays on this device; recognition and '
                      'registration send the image to your configured '
                      'SmartVision server.',
                ),
                CheckboxListTile(
                  value: _hasConsent,
                  onChanged: (value) =>
                      setState(() => _hasConsent = value ?? false),
                  activeColor: AppColors.accentBlue,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'I have consent to process this face image',
                    style:
                        TextStyle(color: AppColors.primaryText, fontSize: 13),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isScanning
                            ? null
                            : () => _selectImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('Capture'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isScanning
                            ? null
                            : () => _selectImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Choose'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_isScanning)
            const SvCard(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          if (bytes != null && size != null) ...[
            SvCard(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                      ),
                      child: DetectionFrame(
                        aspectRatio: size.width / size.height,
                        detections: _overlayBoxes,
                        child: Image.memory(bytes, fit: BoxFit.fill),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SvNotice(
                    tone: _faces.isEmpty ? SvTone.warning : SvTone.success,
                    icon: _faces.isEmpty
                        ? Icons.face_retouching_off
                        : Icons.face_rounded,
                    message: _faces.isEmpty
                        ? 'No face was detected in this image.'
                        : '${_faces.length} face(s) detected on the device.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SvCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SvSectionTitle(
                    'Identity (server)',
                    icon: Icons.badge_outlined,
                    trailing: SvPill(
                      label: backend.statusLabel,
                      color: backend.isOnline
                          ? AppColors.success
                          : AppColors.mutedText,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (!backend.isOnline)
                    SvNotice(
                      tone: SvTone.warning,
                      message: 'Identity recognition needs the SmartVision '
                          'server (YuNet + SFace models are not bundled in the '
                          'app). The phone will not guess identities.',
                      action: TextButton(
                        onPressed: () => context.go('/settings'),
                        child: const Text('Configure server'),
                      ),
                    )
                  else ...[
                    FilledButton.icon(
                      onPressed: _isRecognizing || _faces.isEmpty
                          ? null
                          : () => _recognize(backend),
                      icon: _isRecognizing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.person_search_outlined),
                      label: const Text('Recognize'),
                    ),
                    if (recognitions != null) ...[
                      const SizedBox(height: 10),
                      if (recognitions.isEmpty)
                        const SvNotice(
                          tone: SvTone.warning,
                          message: 'The server did not return a face match.',
                        )
                      else
                        for (final r in recognitions)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              r['name'] == 'Not Registered'
                                  ? Icons.person_off_outlined
                                  : Icons.verified_user_outlined,
                              color: r['name'] == 'Not Registered'
                                  ? AppColors.warning
                                  : AppColors.success,
                            ),
                            title: Text(
                              r['name']?.toString() ?? 'Not Registered',
                              style: const TextStyle(
                                color: AppColors.primaryText,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              r['name'] == 'Not Registered'
                                  ? 'No close, unambiguous match'
                                  : 'Similarity ${formatPercent(((r['confidence'] as num?) ?? 0).toDouble())}',
                              style: const TextStyle(
                                  color: AppColors.secondaryText),
                            ),
                          ),
                    ],
                    const Divider(height: 26),
                    TextField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      style: const TextStyle(color: AppColors.primaryText),
                      decoration: const InputDecoration(
                        labelText: 'Name to register',
                        prefixIcon: Icon(Icons.person_add_alt_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed:
                          _isRegistering ? null : () => _register(backend),
                      icon: _isRegistering
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.how_to_reg_outlined),
                      label: const Text('Register this face'),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (_info != null) ...[
            const SizedBox(height: 12),
            SvNotice(tone: SvTone.success, message: _info!),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            SvNotice(tone: SvTone.error, message: _error!),
          ],
        ],
      ),
    );
  }
}
