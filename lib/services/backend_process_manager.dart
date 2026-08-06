import 'dart:async';
import 'dart:convert';
import 'dart:io';

class BackendProcessManager {
  BackendProcessManager({
    Uri? healthEndpoint,
    this.startupTimeout = const Duration(seconds: 12),
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
    final serverScript = _findServerScript();
    if (serverScript == null) {
      throw const BackendStartException(
        'Không tìm thấy backend/server.py trong bộ cài.',
      );
    }

    final python = _findPythonExecutable(serverScript.parent);
    if (python == null) {
      throw const BackendStartException(
        'Không tìm thấy python.exe. Hãy cài Python 3.11 rồi chạy '
        'backend\\setup_backend.ps1.',
      );
    }
    _recentOutput.clear();
    try {
      _process = await Process.start(
        python,
        [serverScript.path, '--host', '127.0.0.1', '--port', '8765'],
        workingDirectory: serverScript.parent.path,
        runInShell: false,
        environment: const {
          'PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK': 'True',
          'PYTHONUTF8': '1',
        },
      );
    } on ProcessException catch (error) {
      throw BackendStartException(
        'Không thể mở Python để chạy backend: ${error.message}',
      );
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
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    final details = _recentOutput.isEmpty
        ? ''
        : ' Chi tiết: ${_recentOutput.join(' | ')}';
    throw BackendStartException(
      'Backend không khởi động được trong ${startupTimeout.inSeconds} giây.$details',
    );
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

  File? _findServerScript() {
    final candidates = <String>[];
    void addFrom(Directory directory) {
      candidates
        ..add(
          '${directory.path}${Platform.pathSeparator}backend'
          '${Platform.pathSeparator}server.py',
        )
        ..add(
          '${directory.path}${Platform.pathSeparator}data'
          '${Platform.pathSeparator}backend${Platform.pathSeparator}server.py',
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
      if (file.existsSync()) return file;
    }
    return null;
  }

  String? _findPythonExecutable(Directory backendDirectory) {
    final bundledPython = File(
      '${backendDirectory.path}${Platform.pathSeparator}python'
      '${Platform.pathSeparator}python.exe',
    );
    if (bundledPython.existsSync()) return bundledPython.absolute.path;

    var directory = backendDirectory;
    for (var depth = 0; depth < 8; depth++) {
      final candidate = File(
        '${directory.path}${Platform.pathSeparator}.venv'
        '${Platform.pathSeparator}Scripts${Platform.pathSeparator}python.exe',
      );
      if (candidate.existsSync()) return candidate.path;
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }

    final systemPath =
        Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
    for (final entry in systemPath.split(';')) {
      final path = entry.trim().replaceAll('"', '');
      if (path.isEmpty) continue;
      final candidate = File('$path${Platform.pathSeparator}python.exe');
      if (candidate.existsSync()) return candidate.absolute.path;
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
