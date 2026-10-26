import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../models/grammar_result.dart';

/// Lists every problem LanguageTool found, with its explanation and the
/// suggested fixes, so the user can choose instead of accepting the first one.
class GrammarIssuesCard extends StatelessWidget {
  const GrammarIssuesCard({
    required this.sourceText,
    required this.matches,
    required this.choices,
    required this.onPick,
    required this.onApplyBest,
    required this.onKeepAll,
    super.key,
  });

  final String sourceText;
  final List<GrammarMatch> matches;
  final GrammarChoices choices;
  final void Function(int matchIndex, int pick) onPick;
  final VoidCallback onApplyBest;
  final VoidCallback onKeepAll;

  @override
  Widget build(BuildContext context) {
    final order = List<int>.generate(matches.length, (i) => i)
      ..sort((a, b) => matches[a].offset.compareTo(matches[b].offset));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 8,
              spacing: 8,
              children: [
                Text(
                  'Chi tiết ${matches.length} vấn đề',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      key: const Key('grammar-apply-best-button'),
                      onPressed: onApplyBest,
                      child: const Text('Dùng gợi ý đầu cho tất cả'),
                    ),
                    TextButton(
                      key: const Key('grammar-keep-all-button'),
                      onPressed: onKeepAll,
                      child: const Text('Giữ nguyên tất cả'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            _HighlightedText(
              sourceText: sourceText,
              matches: matches,
              choices: choices,
            ),
            const SizedBox(height: 6),
            for (final index in order)
              _IssueTile(
                key: Key('grammar-issue-$index'),
                sourceText: sourceText,
                match: matches[index],
                pick: choices.pickFor(index, matches[index]),
                onPick: (pick) => onPick(index, pick),
              ),
          ],
        ),
      ),
    );
  }
}

class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.sourceText,
    required this.matches,
    required this.choices,
  });

  final String sourceText;
  final List<GrammarMatch> matches;
  final GrammarChoices choices;

  @override
  Widget build(BuildContext context) {
    final order = List<int>.generate(matches.length, (i) => i)
      ..sort((a, b) => matches[a].offset.compareTo(matches[b].offset));
    const base = TextStyle(color: AppColors.text, fontSize: 15, height: 1.6);
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final index in order) {
      final match = matches[index];
      if (match.offset < cursor || match.end > sourceText.length) continue;
      if (match.length == 0) continue;
      final fixed =
          choices.pickFor(index, match) >= 0 && match.replacements.isNotEmpty;
      spans
        ..add(TextSpan(text: sourceText.substring(cursor, match.offset)))
        ..add(
          TextSpan(
            text: sourceText.substring(match.offset, match.end),
            style: TextStyle(
              backgroundColor: (fixed ? AppColors.success : AppColors.error)
                  .withValues(alpha: 0.14),
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.wavy,
              decorationColor: fixed ? AppColors.success : AppColors.error,
            ),
          ),
        );
      cursor = match.end;
    }
    spans.add(TextSpan(text: sourceText.substring(cursor)));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText.rich(
        TextSpan(style: base, children: spans),
        key: const Key('grammar-highlighted-text'),
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({
    required this.sourceText,
    required this.match,
    required this.pick,
    required this.onPick,
    super.key,
  });

  final String sourceText;
  final GrammarMatch match;
  final int pick;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final wrong = match.wrongText(sourceText);
    final label = [
      if (match.category.isNotEmpty) match.category,
      if (match.shortMessage.isNotEmpty) match.shortMessage,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          const SizedBox(height: 2),
          SelectableText(
            match.message,
            style: const TextStyle(color: AppColors.text, height: 1.4),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (wrong.isNotEmpty)
                Text(
                  '“$wrong”',
                  style: const TextStyle(
                    color: AppColors.error,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
              if (match.replacements.isEmpty)
                const Text(
                  'Không có gợi ý tự động',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                )
              else ...[
                const Icon(
                  Icons.arrow_forward_rounded,
                  size: 16,
                  color: AppColors.textMuted,
                ),
                for (var i = 0; i < match.replacements.length; i++)
                  ChoiceChip(
                    key: Key('grammar-choice-${match.offset}-$i'),
                    label: Text(
                      match.replacements[i].isEmpty
                          ? '(xóa)'
                          : match.replacements[i],
                    ),
                    selected: pick == i,
                    showCheckmark: false,
                    onSelected: (_) => onPick(i),
                    visualDensity: VisualDensity.compact,
                  ),
                ChoiceChip(
                  key: Key('grammar-keep-${match.offset}'),
                  label: const Text('Giữ nguyên'),
                  selected: pick == GrammarChoices.keepOriginal,
                  showCheckmark: false,
                  onSelected: (_) => onPick(GrammarChoices.keepOriginal),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
