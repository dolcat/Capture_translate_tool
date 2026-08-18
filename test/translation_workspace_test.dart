import 'package:capture_translate_tool/app.dart';
import 'package:capture_translate_tool/models/analysis_result.dart';
import 'package:capture_translate_tool/models/grammar_result.dart';
import 'package:capture_translate_tool/services/app_window_service.dart';
import 'package:capture_translate_tool/services/capture_service.dart';
import 'package:capture_translate_tool/services/grammar_service.dart';
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

  testWidgets('checks grammar in a separate paste-only workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final grammarService = _FakeGrammarService();
    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _FakeAppWindowService(),
        captureService: _FakeCaptureService(),
        translationService: _FakeTranslationService(),
        grammarService: grammarService,
        registerSystemHotkey: false,
      ),
    );

    await tester.tap(find.byKey(const Key('grammar-mode-button')));
    await tester.pumpAndSettle();

    expect(grammarService.warmUpCount, 1);
    expect(find.byKey(const Key('capture-button')), findsNothing);
    expect(find.byKey(const Key('settings-button')), findsOneWidget);
    expect(find.text('Văn bản cần kiểm tra'), findsOneWidget);
    expect(find.text('Bản đã sửa'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('grammar-source-text')),
      'This are a test.',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('grammar-check-button')));
    await tester.tap(find.byKey(const Key('grammar-check-button')));
    await tester.pumpAndSettle();

    expect(grammarService.lastText, 'This are a test.');
    expect(grammarService.lastLanguage, 'en-US');
    expect(find.text('This is a test.'), findsOneWidget);
    expect(find.text('Đã sửa 1 lỗi'), findsOneWidget);
  });

  testWidgets('Enter translates typed text and Ctrl+N starts a new one', (
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
    await tester.pumpAndSettle();

    final sourceFinder = find.byKey(const Key('recognized-text'));
    await tester.tap(sourceFinder);
    await tester.enterText(sourceFinder, 'Translate with Enter');
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.enter,
      physicalKey: PhysicalKeyboardKey.enter,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.enter,
      physicalKey: PhysicalKeyboardKey.enter,
    );
    await tester.pumpAndSettle();

    expect(translationService.lastSourceText, 'Translate with Enter');
    expect(find.text('Bản dịch nhập tay'), findsOneWidget);

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.controlLeft,
      physicalKey: PhysicalKeyboardKey.controlLeft,
    );
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyN,
      physicalKey: PhysicalKeyboardKey.keyN,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyN,
      physicalKey: PhysicalKeyboardKey.keyN,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.controlLeft,
      physicalKey: PhysicalKeyboardKey.controlLeft,
    );
    await tester.pumpAndSettle();

    final sourceField = tester.widget<TextField>(sourceFinder);
    expect(sourceField.controller?.text, isEmpty);
    expect(sourceField.focusNode?.hasFocus, isTrue);
    expect(find.text('Bản dịch nhập tay'), findsNothing);

    await tester.enterText(sourceFinder, 'First line');
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.shiftLeft,
      physicalKey: PhysicalKeyboardKey.shiftLeft,
    );
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.enter,
      physicalKey: PhysicalKeyboardKey.enter,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.enter,
      physicalKey: PhysicalKeyboardKey.enter,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.shiftLeft,
      physicalKey: PhysicalKeyboardKey.shiftLeft,
    );
    await tester.pump();

    expect(sourceField.controller?.text, 'First line\n');
    expect(translationService.lastSourceText, 'Translate with Enter');
  });

  testWidgets('Ctrl+Tab switches between translation and grammar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final grammarService = _FakeGrammarService();
    await tester.pumpWidget(
      CaptureTranslateApp(
        appWindowService: _FakeAppWindowService(),
        captureService: _FakeCaptureService(),
        translationService: _FakeTranslationService(),
        grammarService: grammarService,
        registerSystemHotkey: false,
      ),
    );
    await tester.pumpAndSettle();

    await _sendShortcut(
      tester,
      key: LogicalKeyboardKey.tab,
      physicalKey: PhysicalKeyboardKey.tab,
      modifiers: const [
        (LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Văn bản cần kiểm tra'), findsOneWidget);
    expect(grammarService.warmUpCount, 1);

    await _sendShortcut(
      tester,
      key: LogicalKeyboardKey.tab,
      physicalKey: PhysicalKeyboardKey.tab,
      modifiers: const [
        (LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Văn bản nguồn'), findsOneWidget);
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
        grammarService: _FakeGrammarService(),
        shortcutPreferences: preferences,
        registerSystemHotkey: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    expect(find.text('Bản dịch mới'), findsOneWidget);
    expect(find.text('Dịch văn bản nhập tay'), findsOneWidget);
    expect(find.text('Chuyển Dịch / Ngữ pháp'), findsOneWidget);
    expect(find.byKey(const Key('record-new-shortcut-button')), findsOneWidget);
    expect(
      find.byKey(const Key('record-translate-shortcut-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('record-switch-mode-shortcut-button')),
      findsOneWidget,
    );
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

    final recordNewButton = find.byKey(const Key('record-new-shortcut-button'));
    await tester.ensureVisible(recordNewButton);
    await tester.tap(recordNewButton);
    await tester.pump();
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.controlLeft,
      physicalKey: PhysicalKeyboardKey.controlLeft,
    );
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.shiftLeft,
      physicalKey: PhysicalKeyboardKey.shiftLeft,
    );
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyM,
      physicalKey: PhysicalKeyboardKey.keyM,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyM,
      physicalKey: PhysicalKeyboardKey.keyM,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.shiftLeft,
      physicalKey: PhysicalKeyboardKey.shiftLeft,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.controlLeft,
      physicalKey: PhysicalKeyboardKey.controlLeft,
    );
    await tester.pump();

    final recordSwitchButton = find.byKey(
      const Key('record-switch-mode-shortcut-button'),
    );
    await tester.ensureVisible(recordSwitchButton);
    await tester.tap(recordSwitchButton);
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
      LogicalKeyboardKey.keyS,
      physicalKey: PhysicalKeyboardKey.keyS,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyS,
      physicalKey: PhysicalKeyboardKey.keyS,
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

    await tester.ensureVisible(find.byKey(const Key('save-shortcut-button')));
    await tester.tap(find.byKey(const Key('save-shortcut-button')));
    await tester.pumpAndSettle();

    final saved = await preferences.loadCaptureShortcut();
    final savedNew = await preferences.loadNewTranslationShortcut();
    final savedTranslate = await preferences.loadTranslateShortcut();
    final savedSwitchMode = await preferences.loadSwitchModeShortcut();
    expect(saved, isNotNull);
    expect(saved!.physicalKey, PhysicalKeyboardKey.keyG);
    expect(
      saved.modifiers,
      containsAll([HotKeyModifier.control, HotKeyModifier.alt]),
    );
    expect(savedNew?.physicalKey, PhysicalKeyboardKey.keyM);
    expect(
      savedNew?.modifiers,
      containsAll([HotKeyModifier.control, HotKeyModifier.shift]),
    );
    expect(savedTranslate?.physicalKey, PhysicalKeyboardKey.enter);
    expect(savedTranslate?.modifiers, isEmpty);
    expect(savedSwitchMode?.physicalKey, PhysicalKeyboardKey.keyS);
    expect(
      savedSwitchMode?.modifiers,
      containsAll([HotKeyModifier.control, HotKeyModifier.alt]),
    );
    expect(find.text('G'), findsOneWidget);

    await _sendShortcut(
      tester,
      key: LogicalKeyboardKey.keyS,
      physicalKey: PhysicalKeyboardKey.keyS,
      modifiers: const [
        (LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft),
        (LogicalKeyboardKey.altLeft, PhysicalKeyboardKey.altLeft),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Văn bản cần kiểm tra'), findsOneWidget);
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

  testWidgets('grammar workspace stays responsive in a very narrow window', (
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
        grammarService: _FakeGrammarService(),
        registerSystemHotkey: false,
      ),
    );
    await tester.tap(find.byKey(const Key('grammar-mode-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('capture-button')), findsNothing);
    expect(find.byKey(const Key('grammar-source-text')), findsOneWidget);
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

Future<void> _sendShortcut(
  WidgetTester tester, {
  required LogicalKeyboardKey key,
  required PhysicalKeyboardKey physicalKey,
  required List<(LogicalKeyboardKey, PhysicalKeyboardKey)> modifiers,
}) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier.$1, physicalKey: modifier.$2);
  }
  await tester.sendKeyDownEvent(key, physicalKey: physicalKey);
  await tester.sendKeyUpEvent(key, physicalKey: physicalKey);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier.$1, physicalKey: modifier.$2);
  }
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

class _FakeGrammarService implements GrammarService {
  String? lastText;
  String? lastLanguage;
  int warmUpCount = 0;

  @override
  Future<void> warmUp() async {
    warmUpCount += 1;
  }

  @override
  Future<GrammarResult> checkGrammar({
    required String text,
    required String language,
  }) async {
    lastText = text;
    lastLanguage = language;
    return const GrammarResult(correctedText: 'This is a test.', issueCount: 1);
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
