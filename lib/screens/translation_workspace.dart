import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../core/app_theme.dart';
import '../models/analysis_result.dart';
import '../services/app_window_service.dart';
import '../services/capture_service.dart';
import '../services/shortcut_preferences.dart';
import '../services/translation_service.dart';
import '../widgets/translation_panel.dart';

enum WorkspaceStatus { idle, capturing, analyzing, translating, success, error }

class TranslationWorkspace extends StatefulWidget {
  const TranslationWorkspace({
    required this.appWindowService,
    required this.captureService,
    required this.translationService,
    required this.shortcutPreferences,
    required this.registerSystemHotkey,
    super.key,
  });

  final AppWindowService appWindowService;
  final ScreenCaptureService captureService;
  final TranslationService translationService;
  final ShortcutPreferences shortcutPreferences;
  final bool registerSystemHotkey;

  @override
  State<TranslationWorkspace> createState() => _TranslationWorkspaceState();
}

class _TranslationWorkspaceState extends State<TranslationWorkspace> {
  static const _sourceLanguage = 'en';
  static const _targetLanguage = 'vi';

  WorkspaceStatus _status = WorkspaceStatus.idle;
  AnalysisResult? _result;
  final TextEditingController _sourceController = TextEditingController();
  String _translatedText = '';
  String? _lastImagePath;
  String? _errorMessage;
  HotKey _configuredHotkey = _defaultCaptureHotkey();
  HotKey? _captureHotkey;
  bool _lastActionWasTextTranslation = false;

  bool get _isBusy =>
      _status == WorkspaceStatus.capturing ||
      _status == WorkspaceStatus.analyzing ||
      _status == WorkspaceStatus.translating;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeHotkey());
  }

  static HotKey _defaultCaptureHotkey() {
    return HotKey(
      key: PhysicalKeyboardKey.keyT,
      modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );
  }

  Future<void> _initializeHotkey() async {
    final saved = await widget.shortcutPreferences.loadCaptureShortcut();
    if (!mounted) return;
    final hotkey = saved ?? _configuredHotkey;
    setState(() => _configuredHotkey = hotkey);
    if (widget.registerSystemHotkey) {
      await _activateHotkey(hotkey);
    }
  }

  Future<void> _registerWithHandler(HotKey hotkey) {
    return hotKeyManager.register(
      hotkey,
      keyDownHandler: (_) {
        if (!_isBusy) unawaited(_captureAndTranslate());
      },
    );
  }

  Future<String?> _activateHotkey(HotKey hotkey) async {
    final previous = _captureHotkey;
    try {
      if (previous != null) await hotKeyManager.unregister(previous);
      await _registerWithHandler(hotkey);
      _captureHotkey = hotkey;
      return null;
    } catch (error) {
      if (previous != null) {
        try {
          await _registerWithHandler(previous);
          _captureHotkey = previous;
        } catch (_) {
          _captureHotkey = null;
        }
      }
      return 'Không thể đăng ký tổ hợp này. Có thể phím tắt đang được ứng dụng khác sử dụng.';
    }
  }

  Future<String?> _saveCaptureHotkey(HotKey hotkey) async {
    final previous = _configuredHotkey;
    if (widget.registerSystemHotkey) {
      final registrationError = await _activateHotkey(hotkey);
      if (registrationError != null) return registrationError;
    }
    try {
      await widget.shortcutPreferences.saveCaptureShortcut(hotkey);
    } catch (error) {
      if (widget.registerSystemHotkey) await _activateHotkey(previous);
      return 'Không thể lưu phím tắt: $error';
    }
    if (mounted) setState(() => _configuredHotkey = hotkey);
    return null;
  }

  List<String> get _shortcutLabels {
    final labels = <String>[
      for (final modifier in _configuredHotkey.modifiers ?? const [])
        switch (modifier) {
          HotKeyModifier.control => 'Ctrl',
          HotKeyModifier.alt => 'Alt',
          HotKeyModifier.shift => 'Shift',
          HotKeyModifier.meta => 'Win',
          _ => modifier.name,
        },
      _configuredHotkey.physicalKey.keyLabel.toUpperCase(),
    ];
    return labels;
  }

  Future<void> _captureAndTranslate() async {
    if (_isBusy) return;
    setState(() {
      _status = WorkspaceStatus.capturing;
      _errorMessage = null;
      _lastActionWasTextTranslation = false;
    });

    try {
      String? imagePath;
      await widget.appWindowService.hideForCapture();
      try {
        imagePath = await widget.captureService.captureRegion();
      } finally {
        await widget.appWindowService.restoreAfterCapture();
      }

      if (!mounted) return;
      if (imagePath == null) {
        setState(() {
          _status =
              _sourceController.text.trim().isEmpty && _translatedText.isEmpty
              ? WorkspaceStatus.idle
              : WorkspaceStatus.success;
        });
        return;
      }

      setState(() {
        _lastImagePath = imagePath;
        _status = WorkspaceStatus.analyzing;
      });

      final result = await widget.translationService.analyze(
        imagePath: imagePath,
        sourceLanguage: _sourceLanguage,
        targetLanguage: _targetLanguage,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _sourceController.text = result.originalText;
        _translatedText = result.translatedText;
        _status = WorkspaceStatus.success;
      });
    } on TranslationServiceException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError('Không thể chụp hoặc xử lý vùng màn hình: $error');
    }
  }

  Future<void> _translateTypedText() async {
    if (_isBusy) return;
    final sourceText = _sourceController.text.trim();
    if (sourceText.isEmpty) {
      _showError('Hãy nhập văn bản tiếng Anh cần dịch.');
      return;
    }

    setState(() {
      _status = WorkspaceStatus.translating;
      _errorMessage = null;
      _lastActionWasTextTranslation = true;
    });
    try {
      final translated = await widget.translationService.translateText(
        text: sourceText,
        sourceLanguage: _sourceLanguage,
        targetLanguage: _targetLanguage,
      );
      if (!mounted) return;
      setState(() {
        _translatedText = translated;
        _status = WorkspaceStatus.success;
      });
    } on TranslationServiceException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError('Không thể dịch văn bản: $error');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _status = WorkspaceStatus.error;
      _errorMessage = message;
    });
  }

  void _startNewSession() {
    if (_isBusy) return;
    setState(() {
      _status = WorkspaceStatus.idle;
      _result = null;
      _sourceController.clear();
      _translatedText = '';
      _lastImagePath = null;
      _errorMessage = null;
      _lastActionWasTextTranslation = false;
    });
  }

  void _showCopiedMessage(String label) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Đã sao chép $label'),
          behavior: SnackBarBehavior.floating,
          width: 280,
        ),
      );
  }

  void _showSetupDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => _ShortcutSettingsDialog(
        currentHotkey: _configuredHotkey,
        defaultHotkey: _defaultCaptureHotkey(),
        onSave: _saveCaptureHotkey,
      ),
    );
  }

  @override
  void dispose() {
    final hotkey = _captureHotkey;
    if (hotkey != null) {
      unawaited(hotKeyManager.unregister(hotkey));
    }
    _sourceController.dispose();
    widget.translationService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth < 480
                ? 12.0
                : constraints.maxWidth < 720
                ? 16.0
                : 30.0;
            final verticalPadding = constraints.maxWidth < 480 ? 18.0 : 28.0;

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AppHeader(
                    isBusy: _isBusy,
                    onNew: _startNewSession,
                    onSettings: _showSetupDialog,
                    onCapture: _captureAndTranslate,
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      verticalPadding,
                      horizontalPadding,
                      24,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1360),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _WorkspaceIntro(
                              onCapture: _captureAndTranslate,
                              shortcutLabels: _shortcutLabels,
                            ),
                            SizedBox(
                              height: constraints.maxWidth < 480 ? 16 : 22,
                            ),
                            _TranslationCard(
                              status: _status,
                              result: _result,
                              lastImagePath: _lastImagePath,
                              errorMessage: _errorMessage,
                              sourceController: _sourceController,
                              translatedText: _translatedText,
                              onTranslate: _translateTypedText,
                              onRetry: _lastActionWasTextTranslation
                                  ? _translateTypedText
                                  : _captureAndTranslate,
                              onCopyOriginal: () =>
                                  _showCopiedMessage('văn bản nhận diện'),
                              onCopyTranslation: () =>
                                  _showCopiedMessage('bản dịch'),
                            ),
                            const SizedBox(height: 18),
                            const _PrivacyFooter(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader({
    required this.isBusy,
    required this.onNew,
    required this.onSettings,
    required this.onCapture,
  });

  final bool isBusy;
  final VoidCallback onNew;
  final VoidCallback onSettings;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 720;
        final useVerticalActions = constraints.maxWidth < 360;
        final showBrandName = constraints.maxWidth >= 300;
        final showOfflineBadge = constraints.maxWidth >= 430;
        final padding = EdgeInsets.symmetric(
          horizontal: isCompact ? 14 : 24,
          vertical: 13,
        );

        Widget buildBrand() {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: isCompact ? 34 : 38,
                height: isCompact ? 34 : 38,
                decoration: BoxDecoration(
                  color: AppColors.primaryDark,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.document_scanner_outlined,
                  color: Colors.white,
                  size: 21,
                ),
              ),
              if (showBrandName) ...[
                const SizedBox(width: 11),
                const Text(
                  'LingoSnap',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
              if (showOfflineBadge) ...[
                const SizedBox(width: 12),
                const _OfflineBadge(),
              ],
            ],
          );
        }

        Widget buildNewButton() {
          return OutlinedButton.icon(
            key: const Key('new-session-button'),
            onPressed: isBusy ? null : onNew,
            icon: const Icon(Icons.add_rounded, size: 19),
            label: const Text('New'),
          );
        }

        Widget buildCaptureButton() {
          return FilledButton.icon(
            key: const Key('capture-button'),
            onPressed: isBusy ? null : onCapture,
            icon: const Icon(Icons.crop_free_rounded, size: 19),
            label: Text(isBusy ? 'Đang xử lý…' : 'Chụp vùng'),
          );
        }

        final settingsButton = IconButton(
          key: const Key('settings-button'),
          onPressed: onSettings,
          tooltip: 'Thiết lập',
          icon: const Icon(Icons.settings_outlined),
        );

        if (!isCompact) {
          return Container(
            color: Colors.white,
            padding: padding,
            child: Row(
              children: [
                buildBrand(),
                const Spacer(),
                settingsButton,
                const SizedBox(width: 5),
                buildNewButton(),
                const SizedBox(width: 9),
                buildCaptureButton(),
              ],
            ),
          );
        }

        final actionButtons = useVerticalActions
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  buildNewButton(),
                  const SizedBox(height: 8),
                  buildCaptureButton(),
                ],
              )
            : Row(
                children: [
                  Expanded(child: buildNewButton()),
                  const SizedBox(width: 8),
                  Expanded(child: buildCaptureButton()),
                ],
              );

        return Container(
          color: Colors.white,
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [buildBrand(), const Spacer(), settingsButton]),
              const SizedBox(height: 10),
              actionButtons,
            ],
          ),
        );
      },
    );
  }
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF7F1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: AppColors.success, size: 7),
          SizedBox(width: 6),
          Text(
            'OFFLINE',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceIntro extends StatelessWidget {
  const _WorkspaceIntro({
    required this.onCapture,
    required this.shortcutLabels,
  });

  final VoidCallback onCapture;
  final List<String> shortcutLabels;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget buildDescription() {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Chụp. Nhận diện. Dịch.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 7),
              Text(
                'Kéo chọn một vùng trên màn hình để dịch nhanh sang tiếng Việt.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
        }

        final shortcut = InkWell(
          onTap: onCapture,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < shortcutLabels.length; index++) ...[
                  if (index > 0) const SizedBox(width: 5),
                  _KeyCap(label: shortcutLabels[index]),
                ],
              ],
            ),
          ),
        );

        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              buildDescription(),
              const SizedBox(height: 10),
              shortcut,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: buildDescription()),
            const SizedBox(width: 20),
            shortcut,
          ],
        );
      },
    );
  }
}

class _TranslationCard extends StatelessWidget {
  const _TranslationCard({
    required this.status,
    required this.result,
    required this.lastImagePath,
    required this.errorMessage,
    required this.sourceController,
    required this.translatedText,
    required this.onTranslate,
    required this.onRetry,
    required this.onCopyOriginal,
    required this.onCopyTranslation,
  });

  final WorkspaceStatus status;
  final AnalysisResult? result;
  final String? lastImagePath;
  final String? errorMessage;
  final TextEditingController sourceController;
  final String translatedText;
  final VoidCallback onTranslate;
  final VoidCallback onRetry;
  final VoidCallback onCopyOriginal;
  final VoidCallback onCopyTranslation;

  bool get _isLoading =>
      status == WorkspaceStatus.capturing ||
      status == WorkspaceStatus.analyzing ||
      status == WorkspaceStatus.translating;

  @override
  Widget build(BuildContext context) {
    final confidence = result?.averageConfidence;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A101828),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LanguageBar(status: status, lastImagePath: lastImagePath),
            if (status == WorkspaceStatus.error && errorMessage != null) ...[
              const SizedBox(height: 12),
              _ErrorBanner(message: errorMessage!, onRetry: onRetry),
            ],
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final panels = [
                  TranslationPanel(
                    title: 'Văn bản nguồn',
                    language: 'English',
                    text: '',
                    emptyTitle: status == WorkspaceStatus.capturing
                        ? 'Chọn vùng cần dịch'
                        : 'Chưa có văn bản',
                    emptyDescription: status == WorkspaceStatus.capturing
                        ? 'Kéo chuột quanh nội dung trên màn hình rồi thả để chụp.'
                        : 'Nhập hoặc dán tiếng Anh tại đây, hoặc dùng “Chụp vùng”.',
                    emptyIcon: Icons.document_scanner_outlined,
                    backgroundColor: Colors.white,
                    isLoading: _isLoading,
                    badge: confidence == null
                        ? 'OCR'
                        : 'OCR ${(confidence * 100).round()}%',
                    textKey: const Key('recognized-text'),
                    controller: sourceController,
                    onTranslate: onTranslate,
                    onCopied: onCopyOriginal,
                  ),
                  TranslationPanel(
                    title: 'Bản dịch',
                    language: 'Tiếng Việt',
                    text: translatedText,
                    emptyTitle: 'Bản dịch sẽ xuất hiện ở đây',
                    emptyDescription:
                        'Nội dung được xử lý hoàn toàn trên máy của bạn.',
                    emptyIcon: Icons.translate_rounded,
                    backgroundColor: AppColors.translationSurface,
                    isLoading: _isLoading,
                    badge: 'Argos',
                    textKey: const Key('translated-text'),
                    onCopied: onCopyTranslation,
                  ),
                ];

                if (constraints.maxWidth < 820) {
                  return Column(
                    children: [
                      SizedBox(height: 300, child: panels.first),
                      const SizedBox(height: 12),
                      SizedBox(height: 300, child: panels.last),
                    ],
                  );
                }

                return SizedBox(
                  height: 390,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: panels.first),
                      const SizedBox(width: 12),
                      Expanded(child: panels.last),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageBar extends StatelessWidget {
  const _LanguageBar({required this.status, required this.lastImagePath});

  final WorkspaceStatus status;
  final String? lastImagePath;

  @override
  Widget build(BuildContext context) {
    final statusText = switch (status) {
      WorkspaceStatus.idle => 'Sẵn sàng',
      WorkspaceStatus.capturing => 'Đang chờ chọn vùng…',
      WorkspaceStatus.analyzing => 'Đang nhận diện và dịch…',
      WorkspaceStatus.translating => 'Đang dịch văn bản…',
      WorkspaceStatus.success => 'Hoàn tất',
      WorkspaceStatus.error => 'Cần thử lại',
    };
    final statusColor = switch (status) {
      WorkspaceStatus.success => AppColors.success,
      WorkspaceStatus.error => AppColors.error,
      _ => AppColors.primaryDark,
    };

    final statusBadge = _StatusBadge(text: statusText, color: statusColor);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 520;
        final languages = Row(
          mainAxisSize: isCompact ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (isCompact)
              const Expanded(
                child: _LanguageLabel(label: 'English', isActive: true),
              )
            else
              const _LanguageLabel(label: 'English', isActive: true),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 19,
                color: AppColors.textMuted,
              ),
            ),
            if (isCompact)
              const Expanded(
                child: _LanguageLabel(label: 'Tiếng Việt', isActive: true),
              )
            else
              const _LanguageLabel(label: 'Tiếng Việt', isActive: true),
          ],
        );
        final captureIcon = lastImagePath == null
            ? null
            : const Icon(
                Icons.image_outlined,
                size: 18,
                color: AppColors.textMuted,
              );

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: isCompact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    languages,
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (captureIcon != null) ...[
                          captureIcon,
                          const SizedBox(width: 8),
                        ],
                        Flexible(child: statusBadge),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    languages,
                    const Spacer(),
                    if (captureIcon != null) ...[
                      captureIcon,
                      const SizedBox(width: 12),
                    ],
                    statusBadge,
                  ],
                ),
        );
      },
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LanguageLabel extends StatelessWidget {
  const _LanguageLabel({required this.label, required this.isActive});

  final String label;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isActive ? AppColors.primaryDark : AppColors.textMuted,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final messageRow = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.error),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: AppColors.error, fontSize: 13),
              ),
            ),
          ],
        );

        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3F2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFECACA)),
          ),
          child: constraints.maxWidth < 420
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    messageRow,
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: onRetry,
                        child: const Text('Thử lại'),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: messageRow),
                    TextButton(
                      onPressed: onRetry,
                      child: const Text('Thử lại'),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _PrivacyFooter extends StatelessWidget {
  const _PrivacyFooter();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.textMuted),
        SizedBox(width: 7),
        Flexible(
          child: Text(
            'Ảnh và nội dung được xử lý cục bộ, không gửi lên Internet',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(color: AppColors.border, offset: Offset(0, 1)),
        ],
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

class _ShortcutSettingsDialog extends StatefulWidget {
  const _ShortcutSettingsDialog({
    required this.currentHotkey,
    required this.defaultHotkey,
    required this.onSave,
  });

  final HotKey currentHotkey;
  final HotKey defaultHotkey;
  final Future<String?> Function(HotKey hotkey) onSave;

  @override
  State<_ShortcutSettingsDialog> createState() =>
      _ShortcutSettingsDialogState();
}

class _ShortcutSettingsDialogState extends State<_ShortcutSettingsDialog> {
  static const _supportedModifiers = {
    HotKeyModifier.control,
    HotKeyModifier.alt,
    HotKeyModifier.shift,
    HotKeyModifier.meta,
  };

  late HotKey _candidate;
  bool _isRecording = false;
  bool _isSaving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _candidate = widget.currentHotkey;
  }

  bool _isModifierKey(PhysicalKeyboardKey key) {
    return HotKeyModifier.values.any(
      (modifier) => modifier.physicalKeys.contains(key),
    );
  }

  void _recordHotkey(HotKey recorded) {
    final key = recorded.physicalKey;
    final modifiers = (recorded.modifiers ?? const <HotKeyModifier>[])
        .where(_supportedModifiers.contains)
        .toList();
    if (_isModifierKey(key) || modifiers.isEmpty) {
      setState(() {
        _message =
            'Tổ hợp cần có ít nhất Ctrl, Alt, Shift hoặc Win cùng một phím.';
      });
      return;
    }

    setState(() {
      _candidate = HotKey(
        identifier: widget.currentHotkey.identifier,
        key: key,
        modifiers: modifiers,
        scope: HotKeyScope.system,
      );
      _isRecording = false;
      _message = null;
    });
  }

  void _resetToDefault() {
    setState(() {
      _candidate = HotKey(
        identifier: widget.currentHotkey.identifier,
        key: widget.defaultHotkey.key,
        modifiers: widget.defaultHotkey.modifiers,
        scope: HotKeyScope.system,
      );
      _isRecording = false;
      _message = null;
    });
  }

  Future<void> _save() async {
    if (_isSaving || _isRecording) return;
    setState(() {
      _isSaving = true;
      _message = null;
    });
    final error = await widget.onSave(_candidate);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _isSaving = false;
      _message = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Thiết lập'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SetupRow(
              icon: Icons.hub_outlined,
              title: 'Backend cục bộ',
              value: 'http://127.0.0.1:8765',
            ),
            const SizedBox(height: 16),
            const _SetupRow(
              icon: Icons.memory_rounded,
              title: 'Engine',
              value: 'RapidOCR ONNX + Argos / CTranslate2',
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Divider(height: 1),
            ),
            Text(
              'Phím tắt chụp vùng',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Phím tắt hoạt động trên toàn hệ thống, kể cả khi cửa sổ đang ẩn.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Container(
              key: const Key('shortcut-preview'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceSubtle,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: _isRecording
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Nhấn tổ hợp phím mới…'),
                        const SizedBox(height: 10),
                        HotKeyRecorder(
                          key: const Key('hotkey-recorder'),
                          initalHotKey: _candidate,
                          onHotKeyRecorded: _recordHotkey,
                        ),
                      ],
                    )
                  : HotKeyVirtualView(hotKey: _candidate),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(
                _message!,
                key: const Key('shortcut-message'),
                style: const TextStyle(color: AppColors.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('record-shortcut-button'),
                  onPressed: _isSaving
                      ? null
                      : () => setState(() {
                          _isRecording = !_isRecording;
                          _message = null;
                        }),
                  icon: Icon(
                    _isRecording ? Icons.close_rounded : Icons.keyboard_rounded,
                    size: 18,
                  ),
                  label: Text(_isRecording ? 'Hủy ghi' : 'Thay đổi'),
                ),
                TextButton(
                  onPressed: _isSaving ? null : _resetToDefault,
                  child: const Text('Khôi phục mặc định'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Hủy'),
        ),
        FilledButton(
          key: const Key('save-shortcut-button'),
          onPressed: _isSaving || _isRecording ? null : _save,
          child: Text(_isSaving ? 'Đang lưu…' : 'Lưu'),
        ),
      ],
    );
  }
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.primaryDark, size: 21),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              SelectableText(
                value,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
