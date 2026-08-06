import 'package:capture_translate_tool/models/analysis_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses analysis response and combines lines', () {
    final result = AnalysisResult.fromJson({
      'items': [
        {
          'original': 'Press E',
          'translated': 'Nhấn E',
          'confidence': 0.9,
          'box': [0, 0, 100, 20],
        },
        {
          'original': 'to continue',
          'translated': 'để tiếp tục',
          'confidence': 1.0,
          'box': [0, 24, 100, 44],
        },
      ],
    });

    expect(result.originalText, 'Press E\nto continue');
    expect(result.translatedText, 'Nhấn E\nđể tiếp tục');
    expect(result.averageConfidence, closeTo(0.95, 0.001));
    expect(result.items.first.box, [0, 0, 100, 20]);
  });

  test('rejects a response without items', () {
    expect(() => AnalysisResult.fromJson(const {}), throwsFormatException);
  });
}
