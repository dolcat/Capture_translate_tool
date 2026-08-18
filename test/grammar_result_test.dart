import 'package:capture_translate_tool/models/grammar_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a grammar result', () {
    final result = GrammarResult.fromJson(const {
      'corrected': 'This is correct.',
      'issueCount': 2,
    });

    expect(result.correctedText, 'This is correct.');
    expect(result.issueCount, 2);
  });

  test('rejects an invalid grammar result', () {
    expect(
      () => GrammarResult.fromJson(const {'corrected': 1}),
      throwsFormatException,
    );
  });
}
