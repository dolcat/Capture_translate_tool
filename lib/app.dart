import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'screens/translation_workspace.dart';
import 'services/app_window_service.dart';
import 'services/capture_service.dart';
import 'services/translation_service.dart';
import 'services/shortcut_preferences.dart';

class CaptureTranslateApp extends StatelessWidget {
  CaptureTranslateApp({
    super.key,
    AppWindowService? appWindowService,
    ScreenCaptureService? captureService,
    TranslationService? translationService,
    ShortcutPreferences? shortcutPreferences,
    this.registerSystemHotkey = true,
  }) : appWindowService = appWindowService ?? DesktopAppWindowService(),
       captureService = captureService ?? WindowsScreenCaptureService(),
       translationService = translationService ?? LocalTranslationService(),
       shortcutPreferences =
           shortcutPreferences ??
           (registerSystemHotkey
               ? FileShortcutPreferences()
               : MemoryShortcutPreferences());

  final AppWindowService appWindowService;
  final ScreenCaptureService captureService;
  final TranslationService translationService;
  final ShortcutPreferences shortcutPreferences;
  final bool registerSystemHotkey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LingoSnap',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: TranslationWorkspace(
        appWindowService: appWindowService,
        captureService: captureService,
        translationService: translationService,
        shortcutPreferences: shortcutPreferences,
        registerSystemHotkey: registerSystemHotkey,
      ),
    );
  }
}
