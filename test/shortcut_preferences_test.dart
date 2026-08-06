import 'dart:io';

import 'package:capture_translate_tool/services/shortcut_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

void main() {
  test('saves and reloads the capture shortcut', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lingosnap-shortcut-test-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final preferences = FileShortcutPreferences(
      settingsFile: File(
        '${directory.path}${Platform.pathSeparator}settings.json',
      ),
    );
    final shortcut = HotKey(
      key: PhysicalKeyboardKey.keyG,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );

    await preferences.saveCaptureShortcut(shortcut);
    final loaded = await preferences.loadCaptureShortcut();

    expect(loaded, isNotNull);
    expect(loaded!.physicalKey, PhysicalKeyboardKey.keyG);
    expect(
      loaded.modifiers,
      containsAll([HotKeyModifier.control, HotKeyModifier.alt]),
    );
  });
}
