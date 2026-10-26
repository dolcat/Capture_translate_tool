import 'package:capture_translate_tool/app.dart';
import 'package:capture_translate_tool/models/analysis_result.dart';
import 'package:capture_translate_tool/models/grammar_result.dart';
import 'package:capture_translate_tool/services/app_window_service.dart';
import 'package:capture_translate_tool/services/capture_service.dart';
import 'package:capture_translate_tool/services/grammar_service.dart';
import 'package:capture_translate_tool/services/translation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _text = 'I has a apple and he dont like it.';
const _matches = [
  GrammarMatch(
    offset: 2,
    length: 3,
    message: 'The verb form does not agree with the subject.',
    category: 'Grammar',
    replacements: ['have', 'had'],
  ),
  GrammarMatch(
    offset: 6,
    length: 1,
    message: 'Use "an" before a vowel sound.',
    replacements: ['an'],
  ),
  GrammarMatch(
    offset: 21,
    length: 4,
    message: 'Possible spelling mistake.',
    replacements: ['don\'t', 'dont.'],
  ),
  GrammarMatch(offset: 30, length: 2, message: 'Style note, no fix.'),
];

void main() {
  group('applyGrammarChoices', () {
    test('uses the best suggestion by default', () {
      expect(
        applyGrammarChoices(_text, _matches, const GrammarChoices()),
        "I have an apple and he don't like it.",
      );
    });

    test('applies a different suggestion and keeps originals', () {
      final choices = const GrammarChoices()
          .withPick(0, 1)
          .withPick(1, GrammarChoices.keepOriginal);
      expect(
        applyGrammarChoices(_text, _matches, choices),
        "I had a apple and he don't like it.",
      );
      expect(countAppliedFixes(_text, _matches, choices), 2);
    });

    test('keeping everything returns the original text', () {
      final keep = const GrammarChoices().all(
        _matches,
        (_) => GrammarChoices.keepOriginal,
      );
      expect(applyGrammarChoices(_text, _matches, keep), _text);
      expect(countAppliedFixes(_text, _matches, keep), 0);
    });

    test('skips overlapping and out-of-range matches', () {
      const overlapping = [
        GrammarMatch(offset: 2, length: 5, message: 'a', replacements: ['X']),
        GrammarMatch(offset: 4, length: 2, message: 'b', replacements: ['Y']),
        GrammarMatch(offset: 90, length: 2, message: 'c', replacements: ['Z']),
      ];
      expect(
        applyGrammarChoices(_text, overlapping, const GrammarChoices()),
        'I X apple and he dont like it.',
      );
    });

    test('works with characters outside the basic plane', () {
      const source = 'Hi 😀 teh end';
      // The emoji is two UTF-16 units, as LanguageTool counts it.
      const match = GrammarMatch(
        offset: 6,
        length: 3,
        message: 'typo',
        replacements: ['the'],
      );
      expect(
        applyGrammarChoices(source, [match], const GrammarChoices()),
        'Hi 😀 the end',
      );
    });
  });

  test('GrammarResult.fromJson reads match details', () {
    final result = GrammarResult.fromJson({
      'corrected': 'She goes.',
      'issueCount': 1,
      'text': 'She go.',
      'matches': [
        {
          'offset': 4,
          'length': 2,
          'message': 'Agreement',
          'ruleId': 'HE_VERB_AGR',
          'category': 'Grammar',
          'replacements': ['goes'],
        },
      ],
    });
    expect(result.hasDetails, isTrue);
    expect(result.matches.single.wrongText(result.sourceText), 'go');
    expect(result.matches.single.replacements, ['goes']);
  });

  group('Grammar screen', () {
    Future<void> openGrammar(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        CaptureTranslateApp(
          appWindowService: _Window(),
          captureService: _Capture(),
          translationService: _Translation(),
          grammarService: _Grammar(),
          registerSystemHotkey: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grammar-mode-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('grammar-source-text')),
        _text,
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('grammar-check-button')));
      await tester.tap(find.byKey(const Key('grammar-check-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists each issue and lets the user choose a fix', (
      tester,
    ) async {
      await openGrammar(tester, const Size(1280, 1000));
      expect(find.text('Chi tiết 4 vấn đề'), findsOneWidget);
      expect(
        find.text('The verb form does not agree with the subject.'),
        findsOneWidget,
      );
      expect(find.text('Đã sửa 3 lỗi'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('grammar-choice-2-1')));
      await tester.tap(find.byKey(const Key('grammar-choice-2-1')));
      await tester.pumpAndSettle();
      expect(find.text('Đã sửa 3 lỗi'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('grammar-keep-6')));
      await tester.tap(find.byKey(const Key('grammar-keep-6')));
      await tester.pumpAndSettle();
      expect(find.text('Đã sửa 2 lỗi'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('grammar-keep-all-button')),
      );
      await tester.tap(find.byKey(const Key('grammar-keep-all-button')));
      await tester.pumpAndSettle();
      expect(find.text('Chưa áp dụng gợi ý nào'), findsOneWidget);

      await tester.tap(find.byKey(const Key('grammar-apply-best-button')));
      await tester.pumpAndSettle();
      expect(find.text('Đã sửa 3 lỗi'), findsOneWidget);
    });

    testWidgets('the "see details" button scrolls the issue list into view', (
      tester,
    ) async {
      await openGrammar(tester, const Size(1280, 700));
      final tile = find.byKey(const Key('grammar-issue-0'));
      expect(tester.getRect(tile).top, greaterThan(700));

      await tester.ensureVisible(
        find.byKey(const Key('grammar-show-issues-button')),
      );
      await tester.tap(find.byKey(const Key('grammar-show-issues-button')));
      await tester.pumpAndSettle();
      expect(tester.getRect(tile).top, lessThan(700));
    });

    for (final size in const [
      Size(1280, 900),
      Size(700, 900),
      Size(320, 700),
    ]) {
      testWidgets('issue list fits at ${size.width.toInt()} px', (
        tester,
      ) async {
        await openGrammar(tester, size);
        expect(find.byKey(const Key('grammar-issue-0')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

class _Grammar implements GrammarService {
  @override
  Future<void> warmUp() async {}

  @override
  Future<GrammarResult> checkGrammar({
    required String text,
    required String language,
  }) async => const GrammarResult(
    correctedText: "I have an apple and he don't like it.",
    issueCount: 3,
    sourceText: _text,
    matches: _matches,
  );

  @override
  void close() {}
}

class _Window implements AppWindowService {
  @override
  Future<void> hideForCapture() async {}

  @override
  Future<void> restoreAfterCapture() async {}
}

class _Capture implements ScreenCaptureService {
  @override
  Future<String?> captureRegion() async => null;
}

class _Translation implements TranslationService {
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
