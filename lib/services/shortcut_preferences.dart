import 'dart:convert';
import 'dart:io';

import 'package:hotkey_manager/hotkey_manager.dart';

abstract interface class ShortcutPreferences {
  Future<HotKey?> loadCaptureShortcut();

  Future<void> saveCaptureShortcut(HotKey hotKey);
}

class FileShortcutPreferences implements ShortcutPreferences {
  FileShortcutPreferences({File? settingsFile})
    : _settingsFile = settingsFile ?? _defaultSettingsFile();

  final File _settingsFile;

  static File _defaultSettingsFile() {
    final appData = Platform.environment['APPDATA'];
    final root = appData == null || appData.trim().isEmpty
        ? Directory.systemTemp.path
        : appData;
    return File(
      '$root${Platform.pathSeparator}LingoSnap'
      '${Platform.pathSeparator}settings.json',
    );
  }

  @override
  Future<HotKey?> loadCaptureShortcut() async {
    try {
      if (!await _settingsFile.exists()) return null;
      final decoded = jsonDecode(await _settingsFile.readAsString());
      if (decoded is! Map || decoded['captureShortcut'] is! Map) return null;
      final shortcut = (decoded['captureShortcut'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      return HotKey.fromJson(shortcut);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveCaptureShortcut(HotKey hotKey) async {
    await _settingsFile.parent.create(recursive: true);
    final temporary = File('${_settingsFile.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'captureShortcut': hotKey.toJson()}),
      flush: true,
    );
    if (await _settingsFile.exists()) {
      await _settingsFile.delete();
    }
    await temporary.rename(_settingsFile.path);
  }
}

class MemoryShortcutPreferences implements ShortcutPreferences {
  HotKey? _captureShortcut;

  @override
  Future<HotKey?> loadCaptureShortcut() async => _captureShortcut;

  @override
  Future<void> saveCaptureShortcut(HotKey hotKey) async {
    _captureShortcut = hotKey;
  }
}
