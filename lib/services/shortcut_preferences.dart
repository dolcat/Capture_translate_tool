import 'dart:convert';
import 'dart:io';

import 'package:hotkey_manager/hotkey_manager.dart';

abstract interface class ShortcutPreferences {
  Future<HotKey?> loadCaptureShortcut();

  Future<HotKey?> loadNewTranslationShortcut();

  Future<HotKey?> loadTranslateShortcut();

  Future<void> saveCaptureShortcut(HotKey hotKey);

  Future<void> saveShortcuts({
    required HotKey capture,
    required HotKey newTranslation,
    required HotKey translate,
  });
}

class FileShortcutPreferences implements ShortcutPreferences {
  FileShortcutPreferences({File? settingsFile})
    : _settingsFile = settingsFile ?? _defaultSettingsFile();

  final File _settingsFile;

  static const _captureKey = 'captureShortcut';
  static const _newTranslationKey = 'newTranslationShortcut';
  static const _translateKey = 'translateShortcut';

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

  Future<Map<String, dynamic>> _readSettings() async {
    try {
      if (!await _settingsFile.exists()) return {};
      final decoded = jsonDecode(await _settingsFile.readAsString());
      if (decoded is! Map) return {};
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {
      return {};
    }
  }

  Future<HotKey?> _loadShortcut(String settingKey) async {
    try {
      final settings = await _readSettings();
      if (settings[settingKey] is! Map) return null;
      final shortcut = (settings[settingKey] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      return HotKey.fromJson(shortcut);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSettings(Map<String, dynamic> settings) async {
    await _settingsFile.parent.create(recursive: true);
    final temporary = File('${_settingsFile.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings),
      flush: true,
    );
    if (await _settingsFile.exists()) {
      await _settingsFile.delete();
    }
    await temporary.rename(_settingsFile.path);
  }

  @override
  Future<HotKey?> loadCaptureShortcut() => _loadShortcut(_captureKey);

  @override
  Future<HotKey?> loadNewTranslationShortcut() =>
      _loadShortcut(_newTranslationKey);

  @override
  Future<HotKey?> loadTranslateShortcut() => _loadShortcut(_translateKey);

  @override
  Future<void> saveCaptureShortcut(HotKey hotKey) async {
    final settings = await _readSettings();
    settings[_captureKey] = hotKey.toJson();
    await _writeSettings(settings);
  }

  @override
  Future<void> saveShortcuts({
    required HotKey capture,
    required HotKey newTranslation,
    required HotKey translate,
  }) async {
    final settings = await _readSettings();
    settings
      ..[_captureKey] = capture.toJson()
      ..[_newTranslationKey] = newTranslation.toJson()
      ..[_translateKey] = translate.toJson();
    await _writeSettings(settings);
  }
}

class MemoryShortcutPreferences implements ShortcutPreferences {
  HotKey? _captureShortcut;
  HotKey? _newTranslationShortcut;
  HotKey? _translateShortcut;

  @override
  Future<HotKey?> loadCaptureShortcut() async => _captureShortcut;

  @override
  Future<HotKey?> loadNewTranslationShortcut() async => _newTranslationShortcut;

  @override
  Future<HotKey?> loadTranslateShortcut() async => _translateShortcut;

  @override
  Future<void> saveCaptureShortcut(HotKey hotKey) async {
    _captureShortcut = hotKey;
  }

  @override
  Future<void> saveShortcuts({
    required HotKey capture,
    required HotKey newTranslation,
    required HotKey translate,
  }) async {
    _captureShortcut = capture;
    _newTranslationShortcut = newTranslation;
    _translateShortcut = translate;
  }
}
