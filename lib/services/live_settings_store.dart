import 'dart:convert';
import 'dart:io';

import '../models/live_settings.dart';

abstract interface class LiveSettingsStore {
  Future<LiveSettings> load();

  Future<void> save(LiveSettings settings);
}

class FileLiveSettingsStore implements LiveSettingsStore {
  FileLiveSettingsStore({File? file}) : _file = file ?? _defaultFile();

  final File _file;

  static File _defaultFile() {
    final appData = Platform.environment['APPDATA'];
    final root = appData == null || appData.trim().isEmpty
        ? Directory.systemTemp.path
        : appData;
    return File(
      '$root${Platform.pathSeparator}LingoSnap'
      '${Platform.pathSeparator}live_settings.json',
    );
  }

  @override
  Future<LiveSettings> load() async {
    try {
      if (!await _file.exists()) return const LiveSettings();
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return const LiveSettings();
      return LiveSettings.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return const LiveSettings();
    }
  }

  @override
  Future<void> save(LiveSettings settings) async {
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    if (await _file.exists()) await _file.delete();
    await temporary.rename(_file.path);
  }
}

class MemoryLiveSettingsStore implements LiveSettingsStore {
  LiveSettings _settings = const LiveSettings();

  @override
  Future<LiveSettings> load() async => _settings;

  @override
  Future<void> save(LiveSettings settings) async => _settings = settings;
}
