import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/grammar_result.dart';
import 'backend_process_manager.dart';

abstract interface class GrammarService {
  Future<void> warmUp();

  Future<GrammarResult> checkGrammar({
    required String text,
    required String language,
  });

  void close();
}

class LocalGrammarService implements GrammarService {
  LocalGrammarService({
    Uri? endpoint,
    Uri? warmUpEndpoint,
    HttpClient? httpClient,
    BackendProcessManager? backendManager,
    this.requestTimeout = const Duration(seconds: 180),
  }) : endpoint = endpoint ?? Uri.parse('http://127.0.0.1:8765/grammar'),
       warmUpEndpoint =
           warmUpEndpoint ?? Uri.parse('http://127.0.0.1:8765/grammar/warmup'),
       _httpClient = httpClient ?? HttpClient(),
       _backendManager = backendManager ?? BackendProcessManager();

  final Uri endpoint;
  final Uri warmUpEndpoint;
  final Duration requestTimeout;
  final HttpClient _httpClient;
  final BackendProcessManager _backendManager;

  @override
  Future<void> warmUp() async {
    try {
      final decoded = await _postJson(warmUpEndpoint, const {});
      if (decoded['ready'] != true) {
        throw const GrammarServiceException(
          'LanguageTool local chưa sẵn sàng.',
        );
      }
    } on GrammarServiceException {
      rethrow;
    } on BackendStartException catch (error) {
      throw GrammarServiceException(error.message);
    } on TimeoutException {
      throw const GrammarServiceException(
        'LanguageTool khởi động quá lâu. Hãy thử lại.',
      );
    } on SocketException {
      throw const GrammarServiceException(
        'Không kết nối được backend offline tại 127.0.0.1:8765.',
      );
    } catch (error) {
      throw GrammarServiceException(
        'Không thể khởi động LanguageTool local: $error',
      );
    }
  }

  @override
  Future<GrammarResult> checkGrammar({
    required String text,
    required String language,
  }) async {
    final sourceText = text.trim();
    if (sourceText.isEmpty) {
      throw const GrammarServiceException(
        'Hãy nhập hoặc dán văn bản tiếng Anh cần kiểm tra.',
      );
    }

    try {
      final decoded = await _postJson(endpoint, {
        'text': sourceText,
        'language': language,
      });
      return GrammarResult.fromJson(decoded);
    } on GrammarServiceException {
      rethrow;
    } on BackendStartException catch (error) {
      throw GrammarServiceException(error.message);
    } on TimeoutException {
      throw const GrammarServiceException(
        'Kiểm tra ngữ pháp mất quá nhiều thời gian. Hãy thử lại với đoạn ngắn hơn.',
      );
    } on SocketException {
      throw const GrammarServiceException(
        'Không kết nối được backend offline tại 127.0.0.1:8765.',
      );
    } on FormatException catch (error) {
      throw GrammarServiceException('Dữ liệu trả về không hợp lệ: $error');
    } catch (error) {
      throw GrammarServiceException('Không thể kiểm tra ngữ pháp: $error');
    }
  }

  Future<Map<String, dynamic>> _postJson(
    Uri requestEndpoint,
    Map<String, String> payload,
  ) async {
    await _backendManager.ensureRunning();
    final request = await _httpClient
        .postUrl(requestEndpoint)
        .timeout(requestTimeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(payload));

    final response = await request.close().timeout(requestTimeout);
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GrammarServiceException(
        _readBackendError(response.statusCode, body),
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const GrammarServiceException(
        'Phản hồi từ backend không đúng định dạng JSON.',
      );
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  String _readBackendError(int statusCode, String body) {
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['detail'] is String) {
          return decoded['detail'] as String;
        }
      } catch (_) {
        // Fall back to the raw response below.
      }
    }
    return 'Backend trả về lỗi $statusCode${body.isEmpty ? '' : ': $body'}';
  }

  @override
  void close() {
    _httpClient.close(force: true);
    _backendManager.close();
  }
}

class GrammarServiceException implements Exception {
  const GrammarServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
