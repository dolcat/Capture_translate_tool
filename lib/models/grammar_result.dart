class GrammarResult {
  const GrammarResult({required this.correctedText, required this.issueCount});

  factory GrammarResult.fromJson(Map<String, dynamic> json) {
    final correctedText = json['corrected'];
    final issueCount = json['issueCount'];
    if (correctedText is! String || issueCount is! num) {
      throw const FormatException('Phản hồi kiểm tra ngữ pháp không hợp lệ.');
    }
    return GrammarResult(
      correctedText: correctedText,
      issueCount: issueCount.toInt(),
    );
  }

  final String correctedText;
  final int issueCount;
}
