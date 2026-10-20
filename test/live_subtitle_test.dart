import 'package:capture_translate_tool/app.dart';
import 'package:capture_translate_tool/models/analysis_result.dart';
import 'package:capture_translate_tool/models/grammar_result.dart';
import 'package:capture_translate_tool/models/live_settings.dart';
import 'package:capture_translate_tool/services/app_window_service.dart';
import 'package:capture_translate_tool/services/capture_service.dart';
import 'package:capture_translate_tool/services/grammar_service.dart';
import 'package:capture_translate_tool/services/live_settings_store.dart';
import 'package:capture_translate_tool/services/live_subtitle_controller.dart';
import 'package:capture_translate_tool/services/live_subtitle_service.dart';
import 'package:capture_translate_tool/services/translation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TermRule.parse', () {
    test('reads arrows, bare terms, comments and blank lines', () {
      final rules = TermRule.parse(
        '# names\n'
        'Geralt of Rivia\n'
        '\n'
        'Witcher => Thợ săn quái vật\r\n'
        '  => ignored because the term is empty\n',
      );
      expect(rules.map((r) => (r.from, r.to)).toList(), [
        ('Geralt of Rivia', ''),
        ('Witcher', 'Thợ săn quái vật'),
      ]);
    });
  });

  group('LiveSettings', () {
    test('round-trips through JSON and builds the backend request', () {
      const region = LiveRegion(x: 10, y: 20, width: 800, height: 120);
      final settings = const LiveSettings(
        glossaryText: 'Zorvex => Zorvex II',
        fixesText: 'bão => cơn bão',
        position: OverlayPosition.below,
        beamSize: 4,
      ).copyWith(region: region);

      final restored = LiveSettings.fromJson(settings.toJson());
      expect(restored.region, region);
      expect(restored.position, OverlayPosition.below);
      expect(restored.beamSize, 4);

      final request = settings.toBackendJson();
      expect(request['region'], {
        'x': 10,
        'y': 20,
        'width': 800,
        'height': 120,
      });
      expect(request['pre'], [
        {'from': 'Zorvex', 'to': 'Zorvex II'},
      ]);
      expect(request['post'], [
        {'from': 'bão', 'to': 'cơn bão'},
      ]);
      expect((request['overlay'] as Map)['position'], 'below');
    });

    test('clamps out-of-range numbers from a hand-edited file', () {
      final settings = LiveSettings.fromJson({
        'intervalMs': 5,
        'fontSize': 9000,
        'beamSize': 0,
      });
      expect(settings.intervalMs, 100);
      expect(settings.fontSize, 96);
      expect(settings.beamSize, 1);
    });
  });

  group('LiveSubtitleController', () {
    test('needs a region, then starts, collects history, and stops', () async {
      final service = _FakeLiveService();
      final controller = LiveSubtitleController(
        service: service,
        store: MemoryLiveSettingsStore(),
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await controller.start();
      expect(controller.isRunning, isFalse);
      expect(controller.error, contains('chọn vùng'));

      await controller.selectRegion();
      expect(controller.settings.region, service.region);

      var minimized = 0;
      final withMinimize = LiveSubtitleController(
        service: service,
        store: MemoryLiveSettingsStore(),
        minimizeWindow: () async => minimized++,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(withMinimize.dispose);
      await withMinimize.load();
      await withMinimize.updateSettings(
        withMinimize.settings.copyWith(region: service.region),
      );
      await withMinimize.start();
      expect(withMinimize.isRunning, isTrue);
      expect(minimized, 1);
      expect(service.started.single.region, service.region);

      service.statusToReturn = const LiveStatus(
        running: true,
        seq: 1,
        original: 'Hello',
        translated: 'Xin chào',
      );
      service.entries = [
        const LiveEntry(seq: 1, original: 'Hello', translated: 'Xin chào'),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(withMinimize.status.translated, 'Xin chào');
      expect(withMinimize.history.single.original, 'Hello');

      await withMinimize.stop();
      expect(withMinimize.isRunning, isFalse);
      expect(service.stopCount, 1);
    });

    test('pushes changed settings to a running session once', () async {
      final service = _FakeLiveService();
      final controller = LiveSubtitleController(
        service: service,
        store: MemoryLiveSettingsStore(),
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.updateSettings(
        controller.settings.copyWith(region: service.region),
      );
      await controller.start();

      for (final size in [30, 32, 34]) {
        await controller.updateSettings(
          controller.settings.copyWith(fontSize: size),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(service.configured, hasLength(1));
      expect(service.configured.single.fontSize, 34);
    });
  });

  group('Live subtitle screen', () {
    Future<void> openLiveMode(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        CaptureTranslateApp(
          appWindowService: _FakeWindow(),
          captureService: _FakeCapture(),
          translationService: _FakeTranslation(),
          grammarService: _FakeGrammar(),
          liveSubtitleService: _FakeLiveService(),
          liveSettingsStore: MemoryLiveSettingsStore(),
          registerSystemHotkey: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-mode-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('selects a region and starts', (tester) async {
      await openLiveMode(tester, const Size(1280, 900));
      expect(find.text('Chưa chọn vùng phụ đề'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live-toggle-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('chọn vùng phụ đề trước'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live-select-region-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('640 × 120'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live-toggle-button')));
      await tester.pumpAndSettle();
      expect(find.text('Dừng dịch'), findsOneWidget);
      expect(find.text('Đang dịch'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live-toggle-button')));
      await tester.pumpAndSettle();
      expect(find.text('Bắt đầu dịch'), findsOneWidget);
    });

    testWidgets('typing in the glossary is saved to the settings', (
      tester,
    ) async {
      await openLiveMode(tester, const Size(1280, 900));
      await tester.enterText(
        find.byKey(const Key('live-glossary-field')),
        'Zorvex',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('live-glossary-field')))
            .controller!
            .text,
        'Zorvex',
      );
    });

    for (final size in const [
      Size(1280, 900),
      Size(700, 900),
      Size(320, 700),
    ]) {
      testWidgets('lays out without overflow at ${size.width.toInt()} px', (
        tester,
      ) async {
        await openLiveMode(tester, size);
        expect(find.byKey(const Key('live-preview')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

class _FakeLiveService implements LiveSubtitleService {
  final region = const LiveRegion(x: 100, y: 800, width: 640, height: 120);
  final started = <LiveSettings>[];
  final configured = <LiveSettings>[];
  int stopCount = 0;
  LiveStatus statusToReturn = const LiveStatus(running: true);
  List<LiveEntry> entries = const [];

  @override
  Future<LiveRegion?> selectRegion() async => region;

  @override
  Future<void> start(LiveSettings settings) async => started.add(settings);

  @override
  Future<void> configure(LiveSettings settings) async =>
      configured.add(settings);

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<LiveStatus> status() async => statusToReturn;

  @override
  Future<List<LiveEntry>> history(int sinceSeq) async =>
      entries.where((e) => e.seq > sinceSeq).toList();

  @override
  void close() {}
}

class _FakeWindow implements AppWindowService {
  @override
  Future<void> hideForCapture() async {}

  @override
  Future<void> restoreAfterCapture() async {}
}

class _FakeCapture implements ScreenCaptureService {
  @override
  Future<String?> captureRegion() async => null;
}

class _FakeTranslation implements TranslationService {
  @override
  Future<AnalysisResult> analyze({
    required String imagePath,
    required String sourceLanguage,
    required String targetLanguage,
  }) async => const AnalysisResult(items: []);

  @override
  Future<String> translateText({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async => '';

  @override
  void close() {}
}

class _FakeGrammar implements GrammarService {
  @override
  Future<void> warmUp() async {}

  @override
  Future<GrammarResult> checkGrammar({
    required String text,
    required String language,
  }) async => const GrammarResult(correctedText: '', issueCount: 0);

  @override
  void close() {}
}
