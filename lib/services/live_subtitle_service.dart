import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/live_settings.dart';
import 'backend_process_manager.dart';

abstract interface class LiveSubtitleService {
  /// Lets the user drag a rectangle on screen. Null when cancelled.
  Future<LiveRegion?> selectRegion();

  Future<void> start(LiveSettings settings);

  Future<void> configure(LiveSettings settings);

  Future<void> stop();

  Future<LiveStatus> status();

  Future<List<LiveEntry>> history(int sinceSeq);

  void close();
}

class LiveSubtitleException implements Exception {
  const LiveSubtitleException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalLiveSubtitleService implements LiveSubtitleService {
  LocalLiveSubtitleService({
    Uri? baseUri,
    HttpClient? httpClient,
    BackendProcessManager? backendManager,
  }) : _baseUri = baseUri ?? Uri.parse('http://127.0.0.1:8765'),
       _httpClient = httpClient ?? HttpClient(),
       _backendManager = backendManager ?? BackendProcessManager();

  final Uri _baseUri;
  final HttpClient _httpClient;
  final BackendProcessManager _backendManager;

  @override
  Future<LiveRegion?> selectRegion() async {
    final json = await _send(
      'POST',
      '/live/select-region',
      timeout: const Duration(minutes: 3),
    );
    if (json['cancelled'] == true) return null;
    final region = LiveRegion.fromJson(json);
    return region.width > 0 && region.height > 0 ? region : null;
  }

  @override
  Future<void> start(LiveSettings settings) async {
    await _send(
      'POST',
      '/live/start',
      body: settings.toBackendJson(),
      timeout: const Duration(seconds: 60), // first start loads the models
    );
  }

  @override
  Future<void> configure(LiveSettings settings) async {
    await _send('POST', '/live/config', body: settings.toBackendJson());
  }

  @override
  Future<void> stop() async {
    await _send('POST', '/live/stop');
  }

  @override
  Future<LiveStatus> status() async =>
      LiveStatus.fromJson(await _send('GET', '/live/status'));

  @override
  Future<List<LiveEntry>> history(int sinceSeq) async {
    final json = await _send('GET', '/live/history?since=$sinceSeq');
    final items = json['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map(
          (item) => LiveEntry.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList();
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      await _backendManager.ensureRunning();
      final uri = _baseUri.resolve(path);
      final request =
          await (method == 'GET'
                  ? _httpClient.getUrl(uri)
                  : _httpClient.postUrl(uri))
              .timeout(timeout);
      if (method != 'GET') {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body ?? const <String, dynamic>{}));
      }
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw LiveSubtitleException(_errorDetail(response.statusCode, text));
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const LiveSubtitleException('Phản hồi từ backend không hợp lệ.');
      }
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on LiveSubtitleException {
      rethrow;
    } on BackendStartException catch (error) {
      throw LiveSubtitleException(error.message);
    } on TimeoutException {
      throw const LiveSubtitleException('Backend phản hồi quá chậm.');
    } on SocketException {
      throw const LiveSubtitleException(
        'Không kết nối được backend tại 127.0.0.1:8765.',
      );
    } on FormatException catch (error) {
      throw LiveSubtitleException('Dữ liệu trả về không hợp lệ: $error');
    }
  }

  String _errorDetail(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {
      // Fall through to the generic message.
    }
    return 'Backend trả về lỗi $statusCode.';
  }

  @override
  void close() => _httpClient.close(force: true);
}
