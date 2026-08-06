import 'package:capture_translate_tool/app.dart';
import 'package:capture_translate_tool/models/analysis_result.dart';
import 'package:capture_translate_tool/services/app_window_service.dart';
import 'package:capture_translate_tool/services/capture_service.dart';
import 'package:capture_translate_tool/services/shortcut_preferences.dart';
import 'package:capture_translate_tool/services/translation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

void main() {
  testWidgets('shows the translation workspace requirements', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _FakeAppWindowService(),
        captureService: _FakeCaptureService(),
        translationService: _FakeTranslationService(),
        registerSystemHotkey: false,
      ),
    );

    expect(find.text('New'), findsOneWidget);
    expect(find.text('Chụp vùng'), findsOneWidget);
    expect(find.text('Văn bản nguồn'), findsOneWidget);
    expect(find.text('Bản dịch'), findsOneWidget);
    expect(find.text('English'), findsWidgets);
    expect(find.text('Tiếng Việt'), findsWidgets);
  });

  testWidgets('captures, displays result, and starts a new session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final translationService = _FakeTranslationService();
    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _FakeAppWindowService(),
        captureService: _FakeCaptureService(),
        translationService: translationService,
        registerSystemHotkey: false,
      ),
    );

    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();

    expect(find.text('Press E to continue'), findsOneWidget);
    expect(find.text('Nhấn E để tiếp tục'), findsOneWidget);
    expect(find.text('OCR 96%'), findsOneWidget);
    expect(translationService.lastImagePath, 'C:\\temp\\capture.png');

    await tester.enterText(
      find.byKey(const Key('recognized-text')),
      'Press F to continue',
    );
    await tester.tap(find.byKey(const Key('translate-button')));
    await tester.pumpAndSettle();

    expect(translationService.lastSourceText, 'Press F to continue');
    expect(find.text('Bản dịch nhập tay'), findsOneWidget);

    await tester.tap(find.byKey(const Key('new-session-button')));
    await tester.pumpAndSettle();

    expect(find.text('Press E to continue'), findsNothing);
    final sourceField = tester.widget<TextField>(
      find.byKey(const Key('recognized-text')),
    );
    expect(sourceField.controller?.text, isEmpty);
  });

  testWidgets('translates text without capturing', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final translationService = _FakeTranslationService();
    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _FakeAppWindowService(),
        captureService: _FakeCaptureService(),
        translationService: translationService,
        registerSystemHotkey: false,
      ),
    );

    await tester.enterText(
      find.byKey(const Key('recognized-text')),
      'Hello from keyboard',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('translate-button')));
    await tester.pumpAndSettle();

    expect(translationService.lastImagePath, isNull);
    expect(translationService.lastSourceText, 'Hello from keyboard');
    expect(find.text('Bản dịch nhập tay'), findsOneWidget);
  });

  testWidgets('records and saves a custom capture shortcut', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = MemoryShortcutPreferences();
    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _FakeAppWindowService(),
        captureService: _FakeCaptureService(),
        translationService: _FakeTranslationService(),
        shortcutPreferences: preferences,
        registerSystemHotkey: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-shortcut-button')));
    await tester.pump();

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.controlLeft,
      physicalKey: PhysicalKeyboardKey.controlLeft,
    );
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.altLeft,
      physicalKey: PhysicalKeyboardKey.altLeft,
    );
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyG,
      physicalKey: PhysicalKeyboardKey.keyG,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyG,
      physicalKey: PhysicalKeyboardKey.keyG,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.altLeft,
      physicalKey: PhysicalKeyboardKey.altLeft,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.controlLeft,
      physicalKey: PhysicalKeyboardKey.controlLeft,
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('save-shortcut-button')));
    await tester.pumpAndSettle();

    final saved = await preferences.loadCaptureShortcut();
    expect(saved, isNotNull);
    expect(saved!.physicalKey, PhysicalKeyboardKey.keyG);
    expect(
      saved.modifiers,
      containsAll([HotKeyModifier.control, HotKeyModifier.alt]),
    );
    expect(find.text('G'), findsOneWidget);
  });

  testWidgets('resizes without RenderFlex overflow', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const sizes = [
      Size(1280, 800),
      Size(820, 600),
      Size(600, 480),
      Size(420, 360),
      Size(320, 240),
      Size(280, 200),
    ];

    for (final size in sizes) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        CaptureTranslateApp(
          appWindowService: _FakeAppWindowService(),
          captureService: _FakeCaptureService(),
          translationService: _FakeTranslationService(),
          registerSystemHotkey: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'Giao diện bị lỗi khi đổi kích thước thành $size',
      );
      expect(find.byKey(const Key('new-session-button')), findsOneWidget);
      expect(find.byKey(const Key('capture-button')), findsOneWidget);
    }
  });

  testWidgets('translated content stays responsive in a very narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _FakeAppWindowService(),
        captureService: _FakeCaptureService(),
        translationService: _FakeTranslationService(),
        registerSystemHotkey: false,
      ),
    );
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'Kết quả dịch bị overflow trong cửa sổ hẹp',
    );
    expect(find.text('Press E to continue'), findsOneWidget);
    expect(find.text('Nhấn E để tiếp tục'), findsOneWidget);
  });

  testWidgets('hides the app only while selecting the capture region', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = <String>[];
    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _RecordingAppWindowService(events),
        captureService: _RecordingCaptureService(events),
        translationService: _RecordingTranslationService(events),
        registerSystemHotkey: false,
      ),
    );
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();

    expect(events, ['hide', 'capture', 'restore', 'analyze']);
  });
}

class _FakeAppWindowService implements AppWindowService {
  @override
  Future<void> hideForCapture() async {}

  @override
  Future<void> restoreAfterCapture() async {}
}

class _FakeCaptureService implements ScreenCaptureService {
  @override
  Future<String?> captureRegion() async => 'C:\\temp\\capture.png';
}

class _FakeTranslationService implements TranslationService {
  String? lastImagePath;
  String? lastSourceText;

  @override
  Future<AnalysisResult> analyze({
    required String imagePath,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    lastImagePath = imagePath;
    return const AnalysisResult(
      items: [
        AnalysisItem(
          original: 'Press E to continue',
          translated: 'Nhấn E để tiếp tục',
          confidence: 0.96,
          box: [120, 300, 420, 340],
        ),
      ],
    );
  }

  @override
  Future<String> translateText({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    lastSourceText = text;
    return 'Bản dịch nhập tay';
  }

  @override
  void close() {}
}

class _RecordingAppWindowService implements AppWindowService {
  _RecordingAppWindowService(this.events);

  final List<String> events;

  @override
  Future<void> hideForCapture() async => events.add('hide');

  @override
  Future<void> restoreAfterCapture() async => events.add('restore');
}

class _RecordingCaptureService implements ScreenCaptureService {
  _RecordingCaptureService(this.events);

  final List<String> events;

  @override
  Future<String?> captureRegion() async {
    events.add('capture');
    return 'C:\\temp\\capture.png';
  }
}

class _RecordingTranslationService extends _FakeTranslationService {
  _RecordingTranslationService(this.events);

  final List<String> events;

  @override
  Future<AnalysisResult> analyze({
    required String imagePath,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    events.add('analyze');
    return super.analyze(
      imagePath: imagePath,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
    );
  }
}
