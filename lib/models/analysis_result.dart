class AnalysisItem {
  const AnalysisItem({
    required this.original,
    required this.translated,
    required this.confidence,
    required this.box,
  });

  factory AnalysisItem.fromJson(Map<String, dynamic> json) {
    final rawBox = json['box'];
    return AnalysisItem(
      original: json['original'] as String? ?? '',
      translated: json['translated'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble(),
      box: rawBox is List
          ? rawBox.whereType<num>().map((value) => value.toDouble()).toList()
          : const [],
    );
  }

  final String original;
  final String translated;
  final double? confidence;
  final List<double> box;
}

class AnalysisResult {
  const AnalysisResult({required this.items});

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException('Phản hồi thiếu danh sách items.');
    }

    return AnalysisResult(
      items: rawItems
          .whereType<Map>()
          .map(
            (item) => AnalysisItem.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList(),
    );
  }

  final List<AnalysisItem> items;

  String get originalText => _join((item) => item.original);
  String get translatedText => _join((item) => item.translated);

  double? get averageConfidence {
    final values = items
        .map((item) => item.confidence)
        .whereType<double>()
        .toList();
    if (values.isEmpty) return null;
    return values.reduce((left, right) => left + right) / values.length;
  }

  String _join(String Function(AnalysisItem item) selector) {
    return items
        .map(selector)
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n');
  }
}
