import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/config/api_config.dart';
import 'database_service.dart';

enum BackendStatus { notConfigured, checking, online, offline }

class BackendException implements Exception {
  BackendException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Thin client for the SmartVision FastAPI backend (ai_server.py) with a real
/// health check. Nothing here fabricates data: when the server is not
/// reachable every call throws a [BackendException].
class BackendService extends ChangeNotifier {
  BackendService(this._database) {
    _load();
  }

  static const String _urlKey = 'backend_url';

  final DatabaseService _database;
  String? _baseUrl;
  bool _loaded = false;
  BackendStatus _status = BackendStatus.notConfigured;
  String? _lastError;
  int? _lastLatencyMs;
  DateTime? _lastCheckedAt;
  Map<String, dynamic>? _serverInfo;
  Timer? _pollTimer;
  bool _checking = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  String? get baseUrl => _baseUrl;
  bool get isConfigured => _baseUrl != null;
  bool get isOnline => _status == BackendStatus.online;
  BackendStatus get status => _status;
  String? get lastError => _lastError;
  int? get lastLatencyMs => _lastLatencyMs;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  Map<String, dynamic>? get serverInfo => _serverInfo;
  bool get isLoaded => _loaded;

  String get statusLabel {
    switch (_status) {
      case BackendStatus.notConfigured:
        return 'Server not set';
      case BackendStatus.checking:
        return 'Checking…';
      case BackendStatus.online:
        return 'Server online';
      case BackendStatus.offline:
        return 'Server offline';
    }
  }

  Future<void> _load() async {
    try {
      final saved = await _database.getAppSetting(_urlKey);
      _baseUrl = ApiConfig.normalize(saved) ?? ApiConfig.defaultUrl;
    } catch (_) {
      _baseUrl = ApiConfig.defaultUrl;
    }
    _loaded = true;
    _status =
        _baseUrl == null ? BackendStatus.notConfigured : BackendStatus.checking;
    notifyListeners();
    _startPolling();
    await checkHealth();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (_baseUrl == null || _disposed) return;
    _pollTimer = Timer.periodic(ApiConfig.healthPollInterval, (_) {
      checkHealth();
    });
  }

  /// Saves a new server URL (or clears it with null/empty) and re-checks.
  Future<void> setBaseUrl(String? input) async {
    final normalized = ApiConfig.normalize(input);
    _baseUrl = normalized;
    _serverInfo = null;
    _lastError = null;
    _status = normalized == null
        ? BackendStatus.notConfigured
        : BackendStatus.checking;
    notifyListeners();
    await _database.setAppSetting(_urlKey, normalized ?? '');
    _startPolling();
    if (normalized != null) await checkHealth();
  }

  /// Calls GET /health and updates [status] with the real result.
  Future<bool> checkHealth() async {
    final base = _baseUrl;
    if (base == null) {
      _status = BackendStatus.notConfigured;
      notifyListeners();
      return false;
    }
    if (_checking) return isOnline;
    _checking = true;
    if (_status != BackendStatus.online) {
      _status = BackendStatus.checking;
      notifyListeners();
    }
    final stopwatch = Stopwatch()..start();
    try {
      final body = await _send('GET', '/health', timeout: ApiConfig.healthTimeout);
      _lastLatencyMs = stopwatch.elapsedMilliseconds;
      final healthy = body['status'] == 'healthy' || body['status'] == 'ok';
      _status = healthy ? BackendStatus.online : BackendStatus.offline;
      _lastError = healthy ? null : 'Unexpected /health response: $body';
      if (healthy && _serverInfo == null) {
        // Optional details (older servers do not have this endpoint).
        try {
          _serverInfo = await _send('GET', '/system/info',
              timeout: ApiConfig.healthTimeout);
        } catch (_) {
          _serverInfo = null;
        }
      }
    } catch (error) {
      _status = BackendStatus.offline;
      _lastLatencyMs = null;
      _lastError = _describe(error, base);
    } finally {
      _checking = false;
      _lastCheckedAt = DateTime.now();
      notifyListeners();
    }
    return isOnline;
  }

  String _describe(Object error, String base) {
    if (error is BackendException) return error.message;
    if (error is TimeoutException) {
      return 'No response from $base within '
          '${ApiConfig.healthTimeout.inSeconds}s.';
    }
    if (error is SocketException) {
      final hint = ApiConfig.isLoopback(base)
          ? ' On a phone, "localhost" is the phone itself — use your '
              "computer's LAN IP (e.g. http://192.168.1.20:8000)."
          : ' Check that the phone and the server are on the same network, '
              'the server runs with --host 0.0.0.0, and port 8000 is allowed '
              'through the firewall.';
      return 'Cannot reach $base (${error.osError?.message ?? error.message}).$hint';
    }
    if (error is HandshakeException) {
      return 'TLS handshake with $base failed: ${error.message}';
    }
    return error.toString();
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = ApiConfig.requestTimeout,
  }) async {
    final base = _baseUrl;
    if (base == null) {
      throw BackendException(
          'No backend server is configured. Set one in Settings.');
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .openUrl(method, Uri.parse('$base$path'))
          .timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = encoded.length;
        request.add(encoded);
      }
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      dynamic decoded;
      try {
        decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded is Map && decoded['detail'] != null
            ? decoded['detail'].toString()
            : text;
        throw BackendException(
          'Server error ${response.statusCode}: $detail',
          statusCode: response.statusCode,
        );
      }
      if (decoded is! Map) {
        throw BackendException('Server returned an unexpected response.');
      }
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = ApiConfig.requestTimeout,
  }) async {
    try {
      return await _send('POST', path, body: body, timeout: timeout);
    } catch (error) {
      if (error is BackendException) rethrow;
      final base = _baseUrl ?? '';
      // A failed request is a real connectivity signal: update the status.
      if (error is SocketException || error is TimeoutException) {
        _status = BackendStatus.offline;
        _lastError = _describe(error, base);
        notifyListeners();
      }
      throw BackendException(_describe(error, base));
    }
  }

  // ------------------------------------------------------------ endpoints ---

  /// POST /chatbot/query — same endpoint/contract the website's assistant
  /// logic exposes for mobile clients.
  Future<String> chatbotQuery({
    required String query,
    required List<Map<String, dynamic>> detections,
    required Map<String, int> counts,
    String ocrText = '',
  }) async {
    final response = await _post('/chatbot/query', {
      'query': query,
      'context': {'detections': detections, 'counts': counts},
      'ocr_text': ocrText,
      'provider': 'auto',
    });
    final reply = response['response']?.toString() ?? '';
    if (reply.trim().isEmpty) {
      throw BackendException('The chatbot returned an empty answer.');
    }
    return reply;
  }

  /// POST /face/register (JSON body {image, name}).
  Future<String> registerFace({
    required String name,
    required Uint8List imageBytes,
  }) async {
    final response = await _post(
      '/face/register',
      {'image': base64Encode(imageBytes), 'name': name},
      timeout: ApiConfig.uploadTimeout,
    );
    return response['message']?.toString() ?? 'Registered $name';
  }

  /// POST /face/recognize → list of {name, confidence, box:[x, y, w, h]}.
  Future<List<Map<String, dynamic>>> recognizeFace(Uint8List imageBytes) async {
    final response = await _post(
      '/face/recognize',
      {'image': base64Encode(imageBytes)},
      timeout: ApiConfig.uploadTimeout,
    );
    final list = response['recognitions'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  /// GET /dataset/summary — dataset splits and server storage (read-only).
  Future<Map<String, dynamic>> datasetSummary() async {
    try {
      return await _send('GET', '/dataset/summary');
    } catch (error) {
      if (error is BackendException) rethrow;
      throw BackendException(_describe(error, _baseUrl ?? ''));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }
}
