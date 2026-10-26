import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../models/live_settings.dart';
import '../services/live_subtitle_controller.dart';

/// The "Phụ đề" mode: pick a screen region, start live translation, and tune
/// how subtitles are translated and displayed.
class LiveSubtitlePanel extends StatefulWidget {
  const LiveSubtitlePanel({
    required this.controller,
    required this.toggleShortcutLabel,
    super.key,
  });

  final LiveSubtitleController controller;
  final String toggleShortcutLabel;

  @override
  State<LiveSubtitlePanel> createState() => _LiveSubtitlePanelState();
}

class _LiveSubtitlePanelState extends State<LiveSubtitlePanel> {
  final _glossary = TextEditingController();
  final _fixes = TextEditingController();
  bool _synced = false;

  LiveSubtitleController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_syncTexts);
    _syncTexts();
  }

  @override
  void dispose() {
    _c.removeListener(_syncTexts);
    _glossary.dispose();
    _fixes.dispose();
    super.dispose();
  }

  // The saved settings arrive asynchronously; fill the text boxes once.
  void _syncTexts() {
    if (_synced || !_c.loaded) return;
    _synced = true;
    _glossary.text = _c.settings.glossaryText;
    _fixes.text = _c.settings.fixesText;
  }

  void _update(LiveSettings Function(LiveSettings s) change) {
    _c.updateSettings(change(_c.settings));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 980;
            final main = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _controlCard(context),
                const SizedBox(height: 16),
                _previewCard(context),
                const SizedBox(height: 16),
                _historyCard(context),
              ],
            );
            final tuning = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _translationCard(context),
                const SizedBox(height: 16),
                _displayCard(context),
                const SizedBox(height: 16),
                _windowCard(context),
                const SizedBox(height: 16),
                _timingCard(context),
              ],
            );
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [main, const SizedBox(height: 16), tuning],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 11, child: main),
                const SizedBox(width: 20),
                Expanded(flex: 10, child: tuning),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------- cards

  Widget _controlCard(BuildContext context) {
    final s = _c.settings;
    final running = _c.isRunning;
    return _Card(
      title: 'Dịch phụ đề trực tiếp',
      subtitle:
          'Chọn khung chứa phụ đề của phim hoặc game. App sẽ đọc khung đó liên '
          'tục và hiện bản dịch tiếng Việt ngay trên màn hình.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.crop_free_rounded,
                size: 20,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.region == null
                      ? 'Chưa chọn vùng phụ đề'
                      : 'Vùng: ${s.region!.label}',
                  key: const Key('live-region-label'),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                key: const Key('live-select-region-button'),
                onPressed: running || _c.isSelecting ? null : _c.selectRegion,
                icon: const Icon(Icons.ads_click_rounded, size: 19),
                label: Text(
                  _c.isSelecting
                      ? 'Đang chờ bạn kéo chọn…'
                      : s.region == null
                      ? 'Chọn vùng phụ đề'
                      : 'Chọn lại vùng',
                ),
              ),
              FilledButton.icon(
                key: const Key('live-toggle-button'),
                onPressed: _c.isBusy || _c.isSelecting ? null : _c.toggle,
                style: running
                    ? FilledButton.styleFrom(backgroundColor: AppColors.error)
                    : null,
                icon: Icon(
                  running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 20,
                ),
                label: Text(running ? 'Dừng dịch' : 'Bắt đầu dịch'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Phím tắt bật/tắt: ${widget.toggleShortcutLabel} (dùng được cả khi '
            'cửa sổ này đang thu nhỏ).',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          if (_c.error != null) ...[
            const SizedBox(height: 12),
            _Notice(text: _c.error!),
          ],
        ],
      ),
    );
  }

  Widget _previewCard(BuildContext context) {
    final status = _c.status;
    final hasText = status.translated.isNotEmpty;
    return _Card(
      title: 'Phụ đề hiện tại',
      trailing: _RunningBadge(running: _c.isRunning),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const Key('live-preview'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _colorOf(_c.settings.backgroundColor),
              borderRadius: BorderRadius.circular(12),
            ),
            constraints: const BoxConstraints(minHeight: 96),
            child: hasText
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        status.translated,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: _colorOf(_c.settings.textColor),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        status.original,
                        style: TextStyle(
                          color: _colorOf(
                            _c.settings.textColor,
                          ).withValues(alpha: 0.6),
                          height: 1.4,
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Xem trước: phụ đề dịch sẽ trông như thế này.',
                        key: const Key('live-preview-sample'),
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: _colorOf(_c.settings.textColor),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _c.isRunning
                            ? 'Đang chờ phụ đề xuất hiện trong vùng đã chọn…'
                            : 'Bản dịch thật sẽ hiện ở đây khi bạn bắt đầu.',
                        style: TextStyle(
                          color: _colorOf(
                            _c.settings.textColor,
                          ).withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_c.isRunning) ...[
            const SizedBox(height: 8),
            Text(
              'Đọc chữ ${status.ocrMs} ms · dịch ${status.translateMs} ms',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _historyCard(BuildContext context) {
    final items = _c.history.reversed.take(12).toList();
    return _Card(
      title: 'Lịch sử',
      child: items.isEmpty
          ? const Text(
              'Các câu đã dịch sẽ được lưu ở đây để bạn xem lại.',
              style: TextStyle(color: AppColors.textMuted),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          entry.translated,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SelectableText(
                          entry.original,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _translationCard(BuildContext context) {
    final s = _c.settings;
    return _Card(
      title: 'Tùy chỉnh bản dịch',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _FieldLabel(
            'Tên riêng và thuật ngữ',
            'Mỗi dòng một mục. Viết "Geralt of Rivia" để giữ nguyên, hoặc '
                '"Geralt of Rivia => Geralt xứ Rivia" để thay bằng chữ bạn muốn. '
                'Phần này được bảo vệ khỏi máy dịch nên không bị dịch sai.',
          ),
          TextField(
            key: const Key('live-glossary-field'),
            controller: _glossary,
            minLines: 4,
            maxLines: 8,
            onChanged: (value) =>
                _update((s) => s.copyWith(glossaryText: value)),
            decoration: const InputDecoration(
              hintText: 'Geralt of Rivia\nWitcher => Thợ săn quái vật',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          const _FieldLabel(
            'Sửa bản dịch',
            'Thay chữ trong bản dịch sau khi dịch xong. Ví dụ: "đặc vụ => tác '
                'nhân". Dùng để sửa những từ máy dịch hay dịch sai.',
          ),
          TextField(
            key: const Key('live-fixes-field'),
            controller: _fixes,
            minLines: 3,
            maxLines: 8,
            onChanged: (value) => _update((s) => s.copyWith(fixesText: value)),
            decoration: const InputDecoration(
              hintText: 'đặc vụ => tác nhân',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          _SliderRow(
            label: 'Chất lượng dịch',
            value: s.beamSize.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            display: switch (s.beamSize) {
              1 => 'Nhanh nhất',
              2 => 'Cân bằng',
              3 => 'Tốt hơn',
              4 => 'Chính xác',
              _ => 'Chính xác nhất',
            },
            onChanged: (v) => _update((s) => s.copyWith(beamSize: v.round())),
          ),
        ],
      ),
    );
  }

  Widget _displayCard(BuildContext context) {
    final s = _c.settings;
    return _Card(
      title: 'Hiển thị phụ đề',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hiện bản dịch trên màn hình'),
            value: s.overlayEnabled,
            onChanged: (v) => _update((s) => s.copyWith(overlayEnabled: v)),
          ),
          const _FieldLabel('Vị trí', null),
          SegmentedButton<OverlayPosition>(
            key: const Key('live-position-selector'),
            segments: [
              for (final p in OverlayPosition.values)
                ButtonSegment(value: p, label: Text(p.label)),
            ],
            selected: {s.position},
            showSelectedIcon: false,
            onSelectionChanged: (sel) =>
                _update((s) => s.copyWith(position: sel.single)),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 12),
          _SliderRow(
            label: 'Cỡ chữ',
            value: s.fontSize.toDouble(),
            min: 16,
            max: 64,
            display: '${s.fontSize} px',
            onChanged: (v) => _update((s) => s.copyWith(fontSize: v.round())),
          ),
          _SliderRow(
            label: 'Độ đậm của nền',
            value: s.opacity.toDouble(),
            min: 30,
            max: 100,
            display: '${s.opacity}%',
            onChanged: (v) => _update((s) => s.copyWith(opacity: v.round())),
          ),
          const SizedBox(height: 4),
          _ColorField(
            key: const Key('live-text-color-field'),
            label: 'Màu chữ',
            value: s.textColor,
            presets: _textPresets,
            onChanged: (hex) => _update((s) => s.copyWith(textColor: hex)),
          ),
          const SizedBox(height: 12),
          _ColorField(
            key: const Key('live-background-color-field'),
            label: 'Màu nền',
            value: s.backgroundColor,
            presets: _backgroundPresets,
            onChanged: (hex) =>
                _update((s) => s.copyWith(backgroundColor: hex)),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Hiện cả câu gốc tiếng Anh (chữ nhỏ)'),
            value: s.showOriginal,
            onChanged: (v) =>
                _update((s) => s.copyWith(showOriginal: v ?? false)),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Tự thu nhỏ cửa sổ này khi bắt đầu'),
            subtitle: const Text('Tránh cửa sổ che vùng phụ đề đang được đọc.'),
            value: s.minimizeOnStart,
            onChanged: (v) =>
                _update((s) => s.copyWith(minimizeOnStart: v ?? true)),
          ),
        ],
      ),
    );
  }

  Widget _windowCard(BuildContext context) {
    final s = _c.settings;
    return _Card(
      title: 'Cửa sổ dịch riêng',
      subtitle:
          'Mở một cửa sổ chỉ để hiện bản dịch, dùng chung màu và cỡ chữ ở trên. '
          'Kéo thanh tiêu đề để di chuyển, kéo cạnh để đổi kích thước; app nhớ '
          'vị trí cho lần sau. Chữ tự thu nhỏ nếu câu quá dài.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const Key('live-window-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Hiện bản dịch trong cửa sổ riêng'),
            value: s.windowEnabled,
            onChanged: (v) => _update((s) => s.copyWith(windowEnabled: v)),
          ),
          CheckboxListTile(
            key: const Key('live-window-on-top-checkbox'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Luôn nằm trên các cửa sổ khác'),
            value: s.windowOnTop,
            onChanged: s.windowEnabled
                ? (v) => _update((s) => s.copyWith(windowOnTop: v ?? true))
                : null,
          ),
        ],
      ),
    );
  }

  Widget _timingCard(BuildContext context) {
    final s = _c.settings;
    return _Card(
      title: 'Nhịp đọc màn hình',
      subtitle:
          'Đọc nhanh hơn thì phụ đề hiện sớm hơn nhưng tốn CPU hơn, nhất là '
          'khi đang chơi game.',
      child: Column(
        children: [
          _SliderRow(
            label: 'Quét mỗi',
            value: s.intervalMs.toDouble(),
            min: 150,
            max: 1500,
            display: '${s.intervalMs} ms',
            onChanged: (v) =>
                _update((s) => s.copyWith(intervalMs: (v / 50).round() * 50)),
          ),
          _SliderRow(
            label: 'Chờ chữ đứng yên',
            value: s.stableMs.toDouble(),
            min: 0,
            max: 1000,
            display: '${s.stableMs} ms',
            onChanged: (v) =>
                _update((s) => s.copyWith(stableMs: (v / 50).round() * 50)),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- pieces

const _textPresets = ['#FFFFFF', '#FFE066', '#7DF9FF', '#8CFF98', '#000000'];
const _backgroundPresets = [
  '#0C0C0E',
  '#000000',
  '#0B1B3A',
  '#2B2B2B',
  '#FFFFFF',
];

Color _colorOf(String hex) => Color(0xFF000000 | rgbOfHex(hex));

/// A row of colour swatches plus a box to type any `#RRGGBB` value.
class _ColorField extends StatefulWidget {
  const _ColorField({
    required this.label,
    required this.value,
    required this.presets,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String value;
  final List<String> presets;
  final ValueChanged<String> onChanged;

  @override
  State<_ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<_ColorField> {
  late final TextEditingController _hex = TextEditingController(
    text: widget.value,
  );
  bool _invalid = false;

  @override
  void didUpdateWidget(_ColorField old) {
    super.didUpdateWidget(old);
    // A swatch was tapped (or settings were reloaded): show the new value,
    // but leave a half-typed hex alone.
    if (normalizeHexColor(_hex.text) != widget.value) {
      _hex.text = widget.value;
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _typed(String text) {
    final hex = normalizeHexColor(text);
    setState(() => _invalid = hex == null);
    if (hex != null && hex != widget.value) widget.onChanged(hex);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            widget.label,
            style: const TextStyle(color: AppColors.text),
          ),
        ),
        for (final preset in widget.presets)
          Tooltip(
            message: preset,
            child: InkWell(
              key: Key('${(widget.key as ValueKey<String>).value}-$preset'),
              customBorder: const CircleBorder(),
              onTap: () => widget.onChanged(preset),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _colorOf(preset),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: preset == widget.value
                        ? AppColors.primary
                        : AppColors.border,
                    width: preset == widget.value ? 3 : 1,
                  ),
                ),
              ),
            ),
          ),
        SizedBox(
          width: 110,
          child: TextField(
            controller: _hex,
            onChanged: _typed,
            maxLength: 7,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              border: const OutlineInputBorder(),
              hintText: '#RRGGBB',
              errorText: _invalid ? 'Sai mã màu' : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?trailing,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.title, this.hint);

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                hint!,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: const TextStyle(color: AppColors.text)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 92,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _RunningBadge extends StatelessWidget {
  const _RunningBadge({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    final color = running ? AppColors.success : AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 9, color: color),
          const SizedBox(width: 6),
          Text(
            running ? 'Đang dịch' : 'Đang dừng',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppColors.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.error, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
