import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/analysis_result.dart';
import 'backend_process_manager.dart';

abstract interface class TranslationService {
  Future<AnalysisResult> analyze({
    required String imagePath,
    required String sourceLanguage,
    required String targetLanguage,
  });

  Future<String> translateText({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  });

  void close();
}

class LocalTranslationService implements TranslationService {
  LocalTranslationService({
    Uri? endpoint,
    Uri? translateEndpoint,
    HttpClient? httpClient,
    BackendProcessManager? backendManager,
    this.requestTimeout = const Duration(seconds: 180),
  }) : endpoint = endpoint ?? Uri.parse('http://127.0.0.1:8765/analyze'),
       translateEndpoint =
           translateEndpoint ?? Uri.parse('http://127.0.0.1:8765/translate'),
       _httpClient = httpClient ?? HttpClient(),
       _backendManager = backendManager ?? BackendProcessManager();

  final Uri endpoint;
  final Uri translateEndpoint;
  final Duration requestTimeout;
  final HttpClient _httpClient;
  final BackendProcessManager _backendManager;

  @override
  Future<AnalysisResult> analyze({
    required String imagePath,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    try {
      final decoded = await _postJson(endpoint, {
        'imagePath': imagePath,
        'sourceLanguage': sourceLanguage,
        'targetLanguage': targetLanguage,
      });

      final result = AnalysisResult.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (result.originalText.isEmpty) {
        throw const TranslationServiceException(
          'Không nhận diện được văn bản trong vùng đã chọn.',
        );
      }
      return result;
    } on TranslationServiceException {
      rethrow;
    } on BackendStartException catch (error) {
      throw TranslationServiceException(error.message);
    } on TimeoutException {
      throw const TranslationServiceException(
        'OCR và dịch mất quá nhiều thời gian. Hãy thử chọn vùng nhỏ hơn.',
      );
    } on SocketException {
      throw const TranslationServiceException(
        'Không kết nối được backend offline tại 127.0.0.1:8765.',
      );
    } on FormatException catch (error) {
      throw TranslationServiceException('Dữ liệu trả về không hợp lệ: $error');
    } catch (error) {
      throw TranslationServiceException('Không thể xử lý ảnh: $error');
    }
  }

  @override
  Future<String> translateText({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (text.trim().isEmpty) {
      throw const TranslationServiceException(
        'Hãy nhập văn bản tiếng Anh cần dịch.',
      );
    }
    try {
      final decoded = await _postJson(translateEndpoint, {
        'text': text,
        'sourceLanguage': sourceLanguage,
        'targetLanguage': targetLanguage,
      });
      final translated = decoded['translated'];
      if (translated is! String || translated.trim().isEmpty) {
        throw const TranslationServiceException(
          'Backend không trả về bản dịch hợp lệ.',
        );
      }
      return translated.trim();
    } on TranslationServiceException {
      rethrow;
    } on BackendStartException catch (error) {
      throw TranslationServiceException(error.message);
    } on TimeoutException {
      throw const TranslationServiceException(
        'Dịch mất quá nhiều thời gian. Hãy thử lại với đoạn ngắn hơn.',
      );
    } on SocketException {
      throw const TranslationServiceException(
        'Không kết nối được backend offline tại 127.0.0.1:8765.',
      );
    } on FormatException catch (error) {
      throw TranslationServiceException('Dữ liệu trả về không hợp lệ: $error');
    } catch (error) {
      throw TranslationServiceException('Không thể dịch văn bản: $error');
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
      throw TranslationServiceException(
        _readBackendError(response.statusCode, body),
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const TranslationServiceException(
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

class TranslationServiceException implements Exception {
  const TranslationServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
