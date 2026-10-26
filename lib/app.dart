import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'screens/translation_workspace.dart';
import 'services/app_window_service.dart';
import 'services/backend_process_manager.dart';
import 'services/capture_service.dart';
import 'services/grammar_service.dart';
import 'services/live_settings_store.dart';
import 'services/live_subtitle_service.dart';
import 'services/shortcut_preferences.dart';
import 'services/translation_service.dart';

class CaptureTranslateApp extends StatelessWidget {
  const CaptureTranslateApp._({
    super.key,
    required this.appWindowService,
    required this.captureService,
    required this.translationService,
    required this.grammarService,
    required this.liveSubtitleService,
    required this.liveSettingsStore,
    required this.shortcutPreferences,
    required this.registerSystemHotkey,
  });

  factory CaptureTranslateApp({
    Key? key,
    AppWindowService? appWindowService,
    ScreenCaptureService? captureService,
    TranslationService? translationService,
    GrammarService? grammarService,
    LiveSubtitleService? liveSubtitleService,
    LiveSettingsStore? liveSettingsStore,
    ShortcutPreferences? shortcutPreferences,
    bool registerSystemHotkey = true,
  }) {
    // One backend process serves translation, grammar and live subtitles.
    final backend = BackendProcessManager();
    return CaptureTranslateApp._(
      key: key,
      appWindowService: appWindowService ?? DesktopAppWindowService(),
      captureService: captureService ?? WindowsScreenCaptureService(),
      translationService:
          translationService ??
          LocalTranslationService(backendManager: backend),
      grammarService:
          grammarService ?? LocalGrammarService(backendManager: backend),
      liveSubtitleService:
          liveSubtitleService ??
          LocalLiveSubtitleService(backendManager: backend),
      liveSettingsStore:
          liveSettingsStore ??
          (registerSystemHotkey
              ? FileLiveSettingsStore()
              : MemoryLiveSettingsStore()),
      shortcutPreferences:
          shortcutPreferences ??
          (registerSystemHotkey
              ? FileShortcutPreferences()
              : MemoryShortcutPreferences()),
      registerSystemHotkey: registerSystemHotkey,
    );
  }

  final AppWindowService appWindowService;
  final ScreenCaptureService captureService;
  final TranslationService translationService;
  final GrammarService grammarService;
  final LiveSubtitleService liveSubtitleService;
  final LiveSettingsStore liveSettingsStore;
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
        grammarService: grammarService,
        liveSubtitleService: liveSubtitleService,
        liveSettingsStore: liveSettingsStore,
        shortcutPreferences: shortcutPreferences,
        registerSystemHotkey: registerSystemHotkey,
      ),
    );
  }
}
