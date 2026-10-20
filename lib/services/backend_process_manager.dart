import 'dart:async';
import 'dart:convert';
import 'dart:io';

class BackendProcessManager {
  BackendProcessManager({
    Uri? healthEndpoint,
    this.startupTimeout = const Duration(seconds: 8),
  }) : healthEndpoint =
           healthEndpoint ?? Uri.parse('http://127.0.0.1:8765/health');

  final Uri healthEndpoint;
  final Duration startupTimeout;

  Process? _process;
  Future<void>? _starting;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final List<String> _recentOutput = [];

  Future<void> ensureRunning() async {
    if (await _isHealthy()) return;
    final activeStart = _starting;
    if (activeStart != null) return activeStart;

    final start = _startAndWait();
    _starting = start;
    try {
      await start;
    } finally {
      if (identical(_starting, start)) _starting = null;
    }
  }

  Future<void> _startAndWait() async {
    final executable = _findBackendExecutable();
    if (executable == null) {
      throw const BackendStartException(
        'Không tìm thấy lingosnap_backend.exe. Hãy chạy '
        'tool\\build_native.ps1 hoặc dùng bộ cài portable.',
      );
    }

    _recentOutput.clear();
    try {
      _process = await Process.start(
        executable.path,
        ['--host', '127.0.0.1', '--port', '8765'],
        workingDirectory: executable.parent.path,
        runInShell: false,
        environment: _processEnvironment(executable.parent),
      );
    } on ProcessException catch (error) {
      throw BackendStartException('Không thể mở backend: ${error.message}');
    }

    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_rememberOutput);
    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_rememberOutput);

    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _isHealthy()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    final details = _recentOutput.isEmpty
        ? ''
        : ' Chi tiết: ${_recentOutput.join(' | ')}';
    throw BackendStartException(
      'Backend không khởi động được trong ${startupTimeout.inSeconds} giây.$details',
    );
  }

  Map<String, String> _processEnvironment(Directory backendDirectory) {
    final environment = <String, String>{};
    final modelsDirectory = _findModelsDirectory(backendDirectory);
    if (modelsDirectory != null) {
      environment['LINGOSNAP_MODELS'] = modelsDirectory.path;
    }
    return environment;
  }

  Future<bool> _isHealthy() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .getUrl(healthEndpoint)
          .timeout(const Duration(seconds: 1));
      final response = await request.close().timeout(
        const Duration(seconds: 1),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) return false;
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['ok'] == true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Looks for the native backend next to the app (portable package), then in
  /// the repository build output used during development.
  File? _findBackendExecutable() {
    final sep = Platform.pathSeparator;
    final candidates = <String>[];
    void addFrom(Directory directory) {
      candidates
        ..add('${directory.path}${sep}backend${sep}lingosnap_backend.exe')
        ..add(
          '${directory.path}${sep}data${sep}backend${sep}lingosnap_backend.exe',
        )
        ..add(
          '${directory.path}${sep}build${sep}native${sep}stage'
          '${sep}lingosnap_backend.exe',
        );
    }

    var current = Directory.current.absolute;
    var executableDirectory = File(Platform.resolvedExecutable).parent.absolute;
    for (var depth = 0; depth < 8; depth++) {
      addFrom(current);
      addFrom(executableDirectory);
      final currentParent = current.parent;
      final executableParent = executableDirectory.parent;
      if (currentParent.path != current.path) current = currentParent;
      if (executableParent.path != executableDirectory.path) {
        executableDirectory = executableParent;
      }
    }

    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file.absolute;
    }
    return null;
  }

  /// `models` beside the executable (portable), otherwise `backend/models` in
  /// the repository that holds the development build.
  Directory? _findModelsDirectory(Directory backendDirectory) {
    final sep = Platform.pathSeparator;
    final beside = Directory('${backendDirectory.path}${sep}models');
    if (beside.existsSync()) return beside;
    var directory = backendDirectory;
    for (var depth = 0; depth < 8; depth++) {
      final candidate = Directory('${directory.path}${sep}backend${sep}models');
      if (candidate.existsSync()) return candidate;
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
    return null;
  }

  void _rememberOutput(String line) {
    if (line.trim().isEmpty) return;
    _recentOutput.add(line.trim());
    if (_recentOutput.length > 8) _recentOutput.removeAt(0);
  }

  void close() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _process?.kill();
    _process = null;
  }
}

class BackendStartException implements Exception {
  const BackendStartException(this.message);

  final String message;

  @override
  String toString() => message;
}
