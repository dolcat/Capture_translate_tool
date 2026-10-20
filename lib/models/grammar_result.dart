/// One problem found by LanguageTool. [offset] and [length] are UTF-16 code
/// units into [GrammarResult.sourceText], which is how Dart indexes strings.
class GrammarMatch {
  const GrammarMatch({
    required this.offset,
    required this.length,
    required this.message,
    this.shortMessage = '',
    this.ruleId = '',
    this.category = '',
    this.replacements = const [],
  });

  factory GrammarMatch.fromJson(Map<String, dynamic> json) {
    final replacements = json['replacements'];
    return GrammarMatch(
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      length: (json['length'] as num?)?.toInt() ?? 0,
      message: json['message'] as String? ?? '',
      shortMessage: json['shortMessage'] as String? ?? '',
      ruleId: json['ruleId'] as String? ?? '',
      category: json['category'] as String? ?? '',
      replacements: replacements is List
          ? replacements.whereType<String>().toList()
          : const [],
    );
  }

  final int offset;
  final int length;
  final String message;
  final String shortMessage;
  final String ruleId;
  final String category;

  /// Suggested fixes, best first.
  final List<String> replacements;

  int get end => offset + length;

  /// The wrong text inside [source], or an empty string if out of range.
  String wrongText(String source) =>
      offset >= 0 && end <= source.length ? source.substring(offset, end) : '';
}

class GrammarResult {
  const GrammarResult({
    required this.correctedText,
    required this.issueCount,
    this.sourceText = '',
    this.matches = const [],
  });

  factory GrammarResult.fromJson(Map<String, dynamic> json) {
    final correctedText = json['corrected'];
    final issueCount = json['issueCount'];
    if (correctedText is! String || issueCount is! num) {
      throw const FormatException('Phản hồi kiểm tra ngữ pháp không hợp lệ.');
    }
    final rawMatches = json['matches'];
    return GrammarResult(
      correctedText: correctedText,
      issueCount: issueCount.toInt(),
      sourceText: json['text'] as String? ?? '',
      matches: rawMatches is List
          ? rawMatches
                .whereType<Map>()
                .map(
                  (m) => GrammarMatch.fromJson(
                    m.map((key, value) => MapEntry(key.toString(), value)),
                  ),
                )
                .toList()
          : const [],
    );
  }

  /// The text with the best suggestion applied to every problem.
  final String correctedText;
  final int issueCount;

  /// The exact text that was checked; match offsets refer to it.
  final String sourceText;
  final List<GrammarMatch> matches;

  /// Whether per-issue details are available for [sourceText].
  bool get hasDetails => sourceText.isNotEmpty && matches.isNotEmpty;
}

/// What the user picked for each problem. Missing entries mean "the best
/// suggestion" (or nothing, if there is none); [keepOriginal] means leave the
/// text as it was written.
class GrammarChoices {
  const GrammarChoices([this.picks = const {}]);

  static const keepOriginal = -1;

  /// Match index -> replacement index, or [keepOriginal].
  final Map<int, int> picks;

  int pickFor(int index, GrammarMatch match) {
    final picked = picks[index];
    if (picked != null) return picked;
    return match.replacements.isEmpty ? keepOriginal : 0;
  }

  GrammarChoices withPick(int index, int pick) =>
      GrammarChoices({...picks, index: pick});

  GrammarChoices all(List<GrammarMatch> matches, int Function(int) pick) {
    return GrammarChoices({
      for (var i = 0; i < matches.length; i++)
        i: matches[i].replacements.isEmpty ? keepOriginal : pick(i),
    });
  }
}

/// Applies the chosen suggestions to [source]. Overlapping problems are
/// skipped (the first one wins), as is anything outside the text.
String applyGrammarChoices(
  String source,
  List<GrammarMatch> matches,
  GrammarChoices choices,
) {
  final order = List<int>.generate(matches.length, (i) => i)
    ..sort((a, b) => matches[a].offset.compareTo(matches[b].offset));
  final out = StringBuffer();
  var cursor = 0;
  for (final index in order) {
    final match = matches[index];
    if (match.offset < cursor || match.end > source.length) continue;
    final pick = choices.pickFor(index, match);
    if (pick < 0 || pick >= match.replacements.length) continue;
    out
      ..write(source.substring(cursor, match.offset))
      ..write(match.replacements[pick]);
    cursor = match.end;
  }
  out.write(source.substring(cursor));
  return out.toString();
}

/// How many problems currently have a suggestion applied.
int countAppliedFixes(
  String source,
  List<GrammarMatch> matches,
  GrammarChoices choices,
) {
  var count = 0;
  var cursor = 0;
  final order = List<int>.generate(matches.length, (i) => i)
    ..sort((a, b) => matches[a].offset.compareTo(matches[b].offset));
  for (final index in order) {
    final match = matches[index];
    if (match.offset < cursor || match.end > source.length) continue;
    final pick = choices.pickFor(index, match);
    if (pick >= 0 && pick < match.replacements.length) {
      count++;
      cursor = match.end;
    }
  }
  return count;
}
