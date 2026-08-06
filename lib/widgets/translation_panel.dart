import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';

class TranslationPanel extends StatelessWidget {
  const TranslationPanel({
    required this.title,
    required this.language,
    required this.text,
    required this.emptyTitle,
    required this.emptyDescription,
    required this.emptyIcon,
    required this.backgroundColor,
    required this.isLoading,
    required this.onCopied,
    this.badge,
    this.textKey,
    this.controller,
    this.onTranslate,
    super.key,
  });

  final String title;
  final String language;
  final String text;
  final String emptyTitle;
  final String emptyDescription;
  final IconData emptyIcon;
  final Color backgroundColor;
  final bool isLoading;
  final String? badge;
  final VoidCallback onCopied;
  final Key? textKey;
  final TextEditingController? controller;
  final VoidCallback? onTranslate;

  @override
  Widget build(BuildContext context) {
    final isEditable = controller != null;

    Widget buildFooter(String currentText) {
      final hasText = currentText.trim().isNotEmpty;
      return Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                hasText
                    ? '${currentText.characters.length} ký tự'
                    : 'Chưa có nội dung',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontSize: 12),
              ),
            ),
            IconButton(
              onPressed: hasText
                  ? () async {
                      await Clipboard.setData(ClipboardData(text: currentText));
                      onCopied();
                    }
                  : null,
              tooltip: 'Sao chép',
              icon: const Icon(Icons.content_copy_rounded, size: 19),
            ),
            if (onTranslate != null) ...[
              const SizedBox(width: 4),
              FilledButton.icon(
                key: const Key('translate-button'),
                onPressed: hasText && !isLoading ? onTranslate : null,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: const Icon(Icons.translate_rounded, size: 17),
                label: const Text('Dịch'),
              ),
            ],
          ],
        ),
      );
    }

    final body = isEditable
        ? Stack(
            children: [
              Positioned.fill(
                child: TextField(
                  key: textKey,
                  controller: controller,
                  readOnly: isLoading,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  style: Theme.of(context).textTheme.bodyLarge,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                    hintText: emptyDescription,
                    hintStyle: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
              if (isLoading)
                const Positioned(
                  left: 22,
                  right: 22,
                  top: 8,
                  child: LinearProgressIndicator(minHeight: 3),
                ),
            ],
          )
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: isLoading
                ? const _PanelLoading(key: ValueKey('loading'))
                : text.trim().isNotEmpty
                ? SingleChildScrollView(
                    key: const ValueKey('content'),
                    padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                    child: SelectableText(
                      text,
                      key: textKey,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  )
                : _PanelEmpty(
                    key: const ValueKey('empty'),
                    title: emptyTitle,
                    description: emptyDescription,
                    icon: emptyIcon,
                  ),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 17, 14, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        language,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (badge != null) _PanelBadge(label: badge!),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(child: body),
          if (controller != null)
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller!,
              builder: (context, value, _) => buildFooter(value.text),
            )
          else
            buildFooter(text),
        ],
      ),
    );
  }
}

class _PanelBadge extends StatelessWidget {
  const _PanelBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PanelLoading extends StatelessWidget {
  const _PanelLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 24),
          Container(height: 14, width: 220, color: AppColors.border),
          const SizedBox(height: 12),
          Container(height: 14, width: 280, color: AppColors.border),
          const SizedBox(height: 12),
          Container(height: 14, width: 170, color: AppColors.border),
        ],
      ),
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty({
    required this.title,
    required this.description,
    required this.icon,
    super.key,
  });

  final String title;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: AppColors.primaryDark, size: 23),
              ),
              const SizedBox(height: 15),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                description,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
