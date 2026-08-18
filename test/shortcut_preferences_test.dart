import 'dart:io';

import 'package:capture_translate_tool/services/shortcut_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

void main() {
  test('saves and reloads all shortcuts', () async {
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
    final newTranslation = HotKey(
      key: PhysicalKeyboardKey.keyN,
      modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.inapp,
    );
    final translate = HotKey(
      key: PhysicalKeyboardKey.enter,
      modifiers: const [],
      scope: HotKeyScope.inapp,
    );
    final switchMode = HotKey(
      key: PhysicalKeyboardKey.tab,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    );

    await preferences.saveCaptureShortcut(shortcut);
    await preferences.saveShortcuts(
      capture: shortcut,
      newTranslation: newTranslation,
      translate: translate,
      switchMode: switchMode,
    );
    final loaded = await preferences.loadCaptureShortcut();
    final loadedNew = await preferences.loadNewTranslationShortcut();
    final loadedTranslate = await preferences.loadTranslateShortcut();
    final loadedSwitchMode = await preferences.loadSwitchModeShortcut();

    expect(loaded, isNotNull);
    expect(loaded!.physicalKey, PhysicalKeyboardKey.keyG);
    expect(
      loaded.modifiers,
      containsAll([HotKeyModifier.control, HotKeyModifier.alt]),
    );
    expect(loadedNew?.physicalKey, PhysicalKeyboardKey.keyN);
    expect(loadedNew?.modifiers, contains(HotKeyModifier.shift));
    expect(loadedTranslate?.physicalKey, PhysicalKeyboardKey.enter);
    expect(loadedTranslate?.modifiers, isEmpty);
    expect(loadedSwitchMode?.physicalKey, PhysicalKeyboardKey.tab);
    expect(loadedSwitchMode?.modifiers, contains(HotKeyModifier.control));
  });
}
