import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_theme.dart';
import '../models/analysis_result.dart';
import '../models/grammar_result.dart';
import '../services/app_window_service.dart';
import '../services/capture_service.dart';
import '../services/grammar_service.dart';
import '../services/live_settings_store.dart';
import '../services/live_subtitle_controller.dart';
import '../services/live_subtitle_service.dart';
import '../services/shortcut_preferences.dart';
import '../services/translation_service.dart';
import '../widgets/grammar_issues_card.dart';
import '../widgets/translation_panel.dart';
import 'live_subtitle_panel.dart';

enum WorkspaceStatus { idle, capturing, analyzing, translating, success, error }

enum GrammarStatus { idle, warmingUp, checking, success, error }

enum WorkspaceMode { translation, grammar, live }

class _NewTranslationIntent extends Intent {
  const _NewTranslationIntent();
}

class _TranslateTypedTextIntent extends Intent {
  const _TranslateTypedTextIntent();
}

class _InsertNewlineIntent extends Intent {
  const _InsertNewlineIntent();
}

class TranslationWorkspace extends StatefulWidget {
  const TranslationWorkspace({
    required this.appWindowService,
    required this.captureService,
    required this.translationService,
    required this.grammarService,
    required this.liveSubtitleService,
    required this.liveSettingsStore,
    required this.shortcutPreferences,
    required this.registerSystemHotkey,
    super.key,
  });

  final AppWindowService appWindowService;
  final ScreenCaptureService captureService;
  final TranslationService translationService;
  final GrammarService grammarService;
  final LiveSubtitleService liveSubtitleService;
  final LiveSettingsStore liveSettingsStore;
  final ShortcutPreferences shortcutPreferences;
  final bool registerSystemHotkey;

  @override
  State<TranslationWorkspace> createState() => _TranslationWorkspaceState();
}

class _TranslationWorkspaceState extends State<TranslationWorkspace> {
  static const _sourceLanguage = 'en';
  static const _targetLanguage = 'vi';

  WorkspaceStatus _status = WorkspaceStatus.idle;
  GrammarStatus _grammarStatus = GrammarStatus.idle;
  WorkspaceMode _mode = WorkspaceMode.translation;
  AnalysisResult? _result;
  final TextEditingController _sourceController = TextEditingController();
  final FocusNode _sourceFocusNode = FocusNode();
  final TextEditingController _grammarController = TextEditingController();
  final FocusNode _grammarFocusNode = FocusNode();
  String _translatedText = '';
  String _correctedText = '';
  GrammarResult? _grammarResult;
  GrammarChoices _grammarChoices = const GrammarChoices();
  int _grammarIssueCount = 0;
  Future<void>? _grammarWarmUpFuture;
  bool _grammarIsReady = false;
  String? _lastImagePath;
  String? _errorMessage;
  String? _grammarErrorMessage;
  HotKey _configuredHotkey = _defaultCaptureHotkey();
  HotKey _newTranslationHotkey = _defaultNewTranslationHotkey();
  HotKey _translateHotkey = _defaultTranslateHotkey();
  HotKey _switchModeHotkey = _defaultSwitchModeHotkey();
  HotKey? _captureHotkey;
  late final LiveSubtitleController _live;
  HotKey? _liveHotkey;
  bool _lastActionWasTextTranslation = false;
  bool _isSettingsOpen = false;

  bool get _isBusy =>
      _status == WorkspaceStatus.capturing ||
      _status == WorkspaceStatus.analyzing ||
      _status == WorkspaceStatus.translating;

  bool get _isGrammarBusy => _grammarStatus == GrammarStatus.checking;

  bool get _isCurrentModeBusy => switch (_mode) {
    WorkspaceMode.translation => _isBusy,
    WorkspaceMode.grammar => _isGrammarBusy,
    WorkspaceMode.live => false,
  };

  @override
  void initState() {
    super.initState();
    _live = LiveSubtitleController(
      service: widget.liveSubtitleService,
      store: widget.liveSettingsStore,
      minimizeWindow: widget.registerSystemHotkey
          ? windowManager.minimize
          : null,
    );
    unawaited(_live.load());
    _sourceFocusNode.addListener(_handleSourceFocusChanged);
    HardwareKeyboard.instance.addHandler(_handleSwitchModeKeyEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeShortcuts());
  }

  bool _handleSwitchModeKeyEvent(KeyEvent event) {
    if (_isSettingsOpen || event is! KeyDownEvent) return false;
    if (event.physicalKey != _switchModeHotkey.physicalKey) return false;

    final modifiers = _switchModeHotkey.modifiers ?? const <HotKeyModifier>[];
    final keyboard = HardwareKeyboard.instance;
    final matchesModifiers =
        keyboard.isControlPressed ==
            modifiers.contains(HotKeyModifier.control) &&
        keyboard.isAltPressed == modifiers.contains(HotKeyModifier.alt) &&
        keyboard.isShiftPressed == modifiers.contains(HotKeyModifier.shift) &&
        keyboard.isMetaPressed == modifiers.contains(HotKeyModifier.meta);
    if (!matchesModifiers) return false;

    _setMode(
      _mode == WorkspaceMode.translation
          ? WorkspaceMode.grammar
          : WorkspaceMode.translation,
    );
    return true;
  }

  static HotKey _defaultCaptureHotkey() {
    return HotKey(
      key: PhysicalKeyboardKey.keyT,
      modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );
  }

  static HotKey _defaultNewTranslationHotkey() {
    return HotKey(
      key: PhysicalKeyboardKey.keyN,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    );
  }

  static HotKey _defaultTranslateHotkey() {
    return HotKey(
      key: PhysicalKeyboardKey.enter,
      modifiers: const [],
      scope: HotKeyScope.inapp,
    );
  }

  static HotKey _defaultSwitchModeHotkey() {
    return HotKey(
      key: PhysicalKeyboardKey.tab,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    );
  }

  void _handleSourceFocusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initializeShortcuts() async {
    final saved = await Future.wait([
      widget.shortcutPreferences.loadCaptureShortcut(),
      widget.shortcutPreferences.loadNewTranslationShortcut(),
      widget.shortcutPreferences.loadTranslateShortcut(),
      widget.shortcutPreferences.loadSwitchModeShortcut(),
    ]);
    if (!mounted) return;
    final hotkey = saved[0] ?? _configuredHotkey;
    setState(() {
      _configuredHotkey = hotkey;
      _newTranslationHotkey = saved[1] ?? _newTranslationHotkey;
      _translateHotkey = saved[2] ?? _translateHotkey;
      _switchModeHotkey = saved[3] ?? _switchModeHotkey;
    });
    if (widget.registerSystemHotkey) {
      await _activateHotkey(hotkey);
      await _registerLiveHotkey();
    }
  }

  /// Ctrl+Alt+L starts/stops live subtitles from anywhere, even while the
  /// window is minimised behind a game or a video.
  Future<void> _registerLiveHotkey() async {
    final hotkey = HotKey(
      key: PhysicalKeyboardKey.keyL,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(
        hotkey,
        keyDownHandler: (_) => unawaited(_live.toggle()),
      );
      _liveHotkey = hotkey;
    } catch (_) {
      // Another app owns the shortcut; the buttons in the window still work.
    }
  }

  Future<void> _registerWithHandler(HotKey hotkey) {
    return hotKeyManager.register(
      hotkey,
      keyDownHandler: (_) {
        if (_mode == WorkspaceMode.translation && !_isBusy) {
          unawaited(_captureAndTranslate());
        }
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

  Future<String?> _saveShortcuts(
    HotKey capture,
    HotKey newTranslation,
    HotKey translate,
    HotKey switchMode,
  ) async {
    final previous = _configuredHotkey;
    if (widget.registerSystemHotkey) {
      final registrationError = await _activateHotkey(capture);
      if (registrationError != null) return registrationError;
    }
    try {
      await widget.shortcutPreferences.saveShortcuts(
        capture: capture,
        newTranslation: newTranslation,
        translate: translate,
        switchMode: switchMode,
      );
    } catch (error) {
      if (widget.registerSystemHotkey) await _activateHotkey(previous);
      return 'Không thể lưu phím tắt: $error';
    }
    if (mounted) {
      setState(() {
        _configuredHotkey = capture;
        _newTranslationHotkey = newTranslation;
        _translateHotkey = translate;
        _switchModeHotkey = switchMode;
      });
    }
    return null;
  }

  SingleActivator _activatorFor(HotKey hotkey) {
    final modifiers = hotkey.modifiers ?? const <HotKeyModifier>[];
    return SingleActivator(
      hotkey.logicalKey,
      control: modifiers.contains(HotKeyModifier.control),
      alt: modifiers.contains(HotKeyModifier.alt),
      shift: modifiers.contains(HotKeyModifier.shift),
      meta: modifiers.contains(HotKeyModifier.meta),
      includeRepeats: false,
    );
  }

  void _insertSourceNewline() {
    if (_isBusy) return;
    final value = _sourceController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final updatedText = value.text.replaceRange(start, end, '\n');
    _sourceController.value = value.copyWith(
      text: updatedText,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
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

  Future<void> _checkGrammar() async {
    if (_isGrammarBusy) return;
    final sourceText = _grammarController.text.trim();
    if (sourceText.isEmpty) {
      _showGrammarError('Hãy nhập hoặc dán văn bản tiếng Anh cần kiểm tra.');
      return;
    }

    setState(() {
      _grammarStatus = GrammarStatus.checking;
      _grammarErrorMessage = null;
    });
    try {
      final result = await widget.grammarService.checkGrammar(
        text: sourceText,
        language: 'en-US',
      );
      if (!mounted) return;
      setState(() {
        _grammarResult = result;
        _grammarChoices = const GrammarChoices();
        _correctedText = result.correctedText;
        _grammarIssueCount = result.issueCount;
        _grammarIsReady = true;
        _grammarStatus = GrammarStatus.success;
      });
    } on GrammarServiceException catch (error) {
      _showGrammarError(error.message);
    } catch (error) {
      _showGrammarError('Không thể kiểm tra ngữ pháp: $error');
    }
  }

  /// Recomputes the corrected text after the user picked other suggestions.
  void _setGrammarChoices(GrammarChoices choices) {
    final result = _grammarResult;
    if (result == null || !result.hasDetails) return;
    setState(() {
      _grammarChoices = choices;
      _correctedText = applyGrammarChoices(
        result.sourceText,
        result.matches,
        choices,
      );
      _grammarIssueCount = countAppliedFixes(
        result.sourceText,
        result.matches,
        choices,
      );
    });
  }

  Widget? _buildGrammarIssues() {
    final result = _grammarResult;
    if (result == null || !result.hasDetails) return null;
    return GrammarIssuesCard(
      sourceText: result.sourceText,
      matches: result.matches,
      choices: _grammarChoices,
      onPick: (index, pick) =>
          _setGrammarChoices(_grammarChoices.withPick(index, pick)),
      onApplyBest: () => _setGrammarChoices(
        const GrammarChoices().all(result.matches, (_) => 0),
      ),
      onKeepAll: () => _setGrammarChoices(
        const GrammarChoices().all(
          result.matches,
          (_) => GrammarChoices.keepOriginal,
        ),
      ),
    );
  }

  Future<void> _warmUpGrammar() async {
    if (_grammarIsReady) return;
    final activeWarmUp = _grammarWarmUpFuture;
    if (activeWarmUp != null) return activeWarmUp;

    if (mounted) {
      setState(() {
        _grammarStatus = GrammarStatus.warmingUp;
        _grammarErrorMessage = null;
      });
    }

    final warmUp = widget.grammarService.warmUp();
    _grammarWarmUpFuture = warmUp;
    try {
      await warmUp;
      _grammarIsReady = true;
      if (mounted && _grammarStatus == GrammarStatus.warmingUp) {
        setState(() => _grammarStatus = GrammarStatus.idle);
      }
    } on GrammarServiceException catch (error) {
      if (mounted && _grammarStatus == GrammarStatus.warmingUp) {
        _showGrammarError(error.message);
      }
    } catch (error) {
      if (mounted && _grammarStatus == GrammarStatus.warmingUp) {
        _showGrammarError('Không thể khởi động LanguageTool local: $error');
      }
    } finally {
      if (identical(_grammarWarmUpFuture, warmUp)) {
        _grammarWarmUpFuture = null;
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _status = WorkspaceStatus.error;
      _errorMessage = message;
    });
  }

  void _showGrammarError(String message) {
    if (!mounted) return;
    setState(() {
      _grammarStatus = GrammarStatus.error;
      _grammarErrorMessage = message;
    });
  }

  void _startNewSession() {
    if (_isCurrentModeBusy || _mode == WorkspaceMode.live) return;
    if (_mode == WorkspaceMode.grammar) {
      setState(() {
        _grammarStatus = GrammarStatus.idle;
        _grammarController.clear();
        _correctedText = '';
        _grammarResult = null;
        _grammarChoices = const GrammarChoices();
        _grammarIssueCount = 0;
        _grammarErrorMessage = null;
      });
      _grammarFocusNode.requestFocus();
      return;
    }
    setState(() {
      _status = WorkspaceStatus.idle;
      _result = null;
      _sourceController.clear();
      _translatedText = '';
      _lastImagePath = null;
      _errorMessage = null;
      _lastActionWasTextTranslation = false;
    });
    _sourceFocusNode.requestFocus();
  }

  void _setMode(WorkspaceMode mode) {
    if (_isCurrentModeBusy || _mode == mode) return;
    setState(() => _mode = mode);
    if (mode == WorkspaceMode.grammar) {
      unawaited(_warmUpGrammar());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (mode) {
        case WorkspaceMode.grammar:
          _grammarFocusNode.requestFocus();
        case WorkspaceMode.translation:
          _sourceFocusNode.requestFocus();
        case WorkspaceMode.live:
          break;
      }
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

  Future<void> _showSetupDialog() async {
    if (_isSettingsOpen) return;
    _isSettingsOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => _ShortcutSettingsDialog(
          currentCaptureHotkey: _configuredHotkey,
          currentNewTranslationHotkey: _newTranslationHotkey,
          currentTranslateHotkey: _translateHotkey,
          currentSwitchModeHotkey: _switchModeHotkey,
          defaultCaptureHotkey: _defaultCaptureHotkey(),
          defaultNewTranslationHotkey: _defaultNewTranslationHotkey(),
          defaultTranslateHotkey: _defaultTranslateHotkey(),
          defaultSwitchModeHotkey: _defaultSwitchModeHotkey(),
          onSave: _saveShortcuts,
        ),
      );
    } finally {
      _isSettingsOpen = false;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleSwitchModeKeyEvent);
    final hotkey = _captureHotkey;
    if (hotkey != null) {
      unawaited(hotKeyManager.unregister(hotkey));
    }
    final liveHotkey = _liveHotkey;
    if (liveHotkey != null) {
      unawaited(hotKeyManager.unregister(liveHotkey));
    }
    _live.dispose();
    _sourceController.dispose();
    _sourceFocusNode
      ..removeListener(_handleSourceFocusChanged)
      ..dispose();
    _grammarController.dispose();
    _grammarFocusNode.dispose();
    widget.translationService.close();
    widget.grammarService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      if (_mode == WorkspaceMode.translation) ...{
        _activatorFor(_newTranslationHotkey): const _NewTranslationIntent(),
        if (_sourceFocusNode.hasFocus)
          _activatorFor(_translateHotkey): const _TranslateTypedTextIntent(),
        if (_sourceFocusNode.hasFocus)
          const SingleActivator(
            LogicalKeyboardKey.enter,
            shift: true,
            includeRepeats: false,
          ): const _InsertNewlineIntent(),
      },
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NewTranslationIntent: CallbackAction<_NewTranslationIntent>(
            onInvoke: (_) {
              _startNewSession();
              return null;
            },
          ),
          _TranslateTypedTextIntent: CallbackAction<_TranslateTypedTextIntent>(
            onInvoke: (_) {
              unawaited(_translateTypedText());
              return null;
            },
          ),
          _InsertNewlineIntent: CallbackAction<_InsertNewlineIntent>(
            onInvoke: (_) {
              _insertSourceNewline();
              return null;
            },
          ),
        },
        child: Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final horizontalPadding = constraints.maxWidth < 480
                    ? 12.0
                    : constraints.maxWidth < 720
                    ? 16.0
                    : 30.0;
                final verticalPadding = constraints.maxWidth < 480
                    ? 18.0
                    : 28.0;

                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _AppHeader(
                        mode: _mode,
                        isBusy: _isCurrentModeBusy,
                        onModeChanged: _setMode,
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
                            child: _mode == WorkspaceMode.live
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      LiveSubtitlePanel(
                                        controller: _live,
                                        toggleShortcutLabel: 'Ctrl + Alt + L',
                                      ),
                                      const SizedBox(height: 18),
                                      const _PrivacyFooter(),
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_mode == WorkspaceMode.translation)
                                        _WorkspaceIntro(
                                          onCapture: _captureAndTranslate,
                                          shortcutLabels: _shortcutLabels,
                                        )
                                      else
                                        const _GrammarIntro(),
                                      SizedBox(
                                        height: constraints.maxWidth < 480
                                            ? 16
                                            : 22,
                                      ),
                                      if (_mode == WorkspaceMode.translation)
                                        _TranslationCard(
                                          status: _status,
                                          result: _result,
                                          lastImagePath: _lastImagePath,
                                          errorMessage: _errorMessage,
                                          sourceController: _sourceController,
                                          sourceFocusNode: _sourceFocusNode,
                                          translatedText: _translatedText,
                                          onTranslate: _translateTypedText,
                                          onRetry: _lastActionWasTextTranslation
                                              ? _translateTypedText
                                              : _captureAndTranslate,
                                          onCopyOriginal: () =>
                                              _showCopiedMessage(
                                                'văn bản nhận diện',
                                              ),
                                          onCopyTranslation: () =>
                                              _showCopiedMessage('bản dịch'),
                                        )
                                      else
                                        _GrammarCard(
                                          status: _grammarStatus,
                                          errorMessage: _grammarErrorMessage,
                                          sourceController: _grammarController,
                                          sourceFocusNode: _grammarFocusNode,
                                          correctedText: _correctedText,
                                          issueCount: _grammarIssueCount,
                                          issues: _buildGrammarIssues(),
                                          onCheck: _checkGrammar,
                                          onRetry: _checkGrammar,
                                          onCopyOriginal: () =>
                                              _showCopiedMessage(
                                                'văn bản cần kiểm tra',
                                              ),
                                          onCopyCorrection: () =>
                                              _showCopiedMessage('bản đã sửa'),
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
        ),
      ),
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader({
    required this.mode,
    required this.isBusy,
    required this.onModeChanged,
    required this.onNew,
    required this.onSettings,
    required this.onCapture,
  });

  final WorkspaceMode mode;
  final bool isBusy;
  final ValueChanged<WorkspaceMode> onModeChanged;
  final VoidCallback onNew;
  final VoidCallback onSettings;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 900;
        final useVerticalActions = constraints.maxWidth < 260;
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
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: SvgPicture.asset(
                    'assets/spouting-whale.svg',
                    fit: BoxFit.contain,
                    semanticsLabel: 'LingoSnap',
                  ),
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

        final modeSelector = SegmentedButton<WorkspaceMode>(
          key: const Key('workspace-mode-selector'),
          segments: const [
            ButtonSegment(
              value: WorkspaceMode.translation,
              icon: Icon(Icons.translate_rounded, size: 17),
              label: Text('Dịch'),
            ),
            ButtonSegment(
              value: WorkspaceMode.grammar,
              icon: Icon(Icons.spellcheck_rounded, size: 17),
              label: Text('Ngữ pháp', key: Key('grammar-mode-button')),
            ),
            ButtonSegment(
              value: WorkspaceMode.live,
              icon: Icon(Icons.subtitles_outlined, size: 17),
              label: Text('Phụ đề', key: Key('live-mode-button')),
            ),
          ],
          selected: {mode},
          onSelectionChanged: isBusy
              ? null
              : (selection) => onModeChanged(selection.single),
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        );

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
                const SizedBox(width: 24),
                modeSelector,
                const Spacer(),
                settingsButton,
                if (mode != WorkspaceMode.live) ...[
                  const SizedBox(width: 5),
                  buildNewButton(),
                ],
                if (mode == WorkspaceMode.translation) ...[
                  const SizedBox(width: 9),
                  buildCaptureButton(),
                ],
              ],
            ),
          );
        }

        final actionButtons = mode == WorkspaceMode.live
            ? const SizedBox.shrink()
            : mode == WorkspaceMode.grammar
            ? Align(alignment: Alignment.centerRight, child: buildNewButton())
            : useVerticalActions
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
              Align(alignment: Alignment.centerLeft, child: modeSelector),
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

class _GrammarIntro extends StatelessWidget {
  const _GrammarIntro();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dán. Kiểm tra. Hoàn thiện.',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 7),
        Text(
          'Dán văn bản tiếng Anh, kiểm tra ngữ pháp và nhận lại phiên bản đã sửa.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
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
    required this.sourceFocusNode,
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
  final FocusNode sourceFocusNode;
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
                    focusNode: sourceFocusNode,
                    onAction: onTranslate,
                    actionKey: const Key('translate-button'),
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

class _GrammarCard extends StatelessWidget {
  const _GrammarCard({
    required this.status,
    required this.errorMessage,
    required this.sourceController,
    required this.sourceFocusNode,
    required this.correctedText,
    required this.issueCount,
    required this.issues,
    required this.onCheck,
    required this.onRetry,
    required this.onCopyOriginal,
    required this.onCopyCorrection,
  });

  final GrammarStatus status;
  final String? errorMessage;
  final TextEditingController sourceController;
  final FocusNode sourceFocusNode;
  final String correctedText;
  final int issueCount;
  final Widget? issues;
  final VoidCallback onCheck;
  final VoidCallback onRetry;
  final VoidCallback onCopyOriginal;
  final VoidCallback onCopyCorrection;

  @override
  Widget build(BuildContext context) {
    final isLoading = status == GrammarStatus.checking;
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
            _GrammarBar(
              status: status,
              issueCount: issueCount,
              hasDetails: issues != null,
            ),
            if (status == GrammarStatus.error && errorMessage != null) ...[
              const SizedBox(height: 12),
              _ErrorBanner(message: errorMessage!, onRetry: onRetry),
            ],
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final panels = [
                  TranslationPanel(
                    title: 'Văn bản cần kiểm tra',
                    language: 'English (US)',
                    text: '',
                    emptyTitle: 'Chưa có văn bản',
                    emptyDescription: 'Nhập hoặc dán tiếng Anh tại đây.',
                    emptyIcon: Icons.content_paste_rounded,
                    backgroundColor: Colors.white,
                    isLoading: isLoading,
                    badge: 'English (US)',
                    textKey: const Key('grammar-source-text'),
                    controller: sourceController,
                    focusNode: sourceFocusNode,
                    onAction: onCheck,
                    actionKey: const Key('grammar-check-button'),
                    actionIcon: Icons.spellcheck_rounded,
                    actionLabel: 'Kiểm tra',
                    onCopied: onCopyOriginal,
                  ),
                  TranslationPanel(
                    title: 'Bản đã sửa',
                    language: 'English (US)',
                    text: correctedText,
                    emptyTitle: 'Bản chính xác sẽ xuất hiện ở đây',
                    emptyDescription:
                        'LanguageTool xử lý ngữ pháp hoàn toàn trên máy.',
                    emptyIcon: Icons.fact_check_outlined,
                    backgroundColor: AppColors.translationSurface,
                    isLoading: isLoading,
                    badge: 'LanguageTool',
                    textKey: const Key('grammar-corrected-text'),
                    onCopied: onCopyCorrection,
                  ),
                ];

                if (constraints.maxWidth < 820) {
                  return Column(
                    children: [
                      SizedBox(height: 430, child: panels.first),
                      const SizedBox(height: 12),
                      SizedBox(height: 350, child: panels.last),
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
            if (issues != null) ...[const SizedBox(height: 14), issues!],
          ],
        ),
      ),
    );
  }
}

class _GrammarBar extends StatelessWidget {
  const _GrammarBar({
    required this.status,
    required this.issueCount,
    required this.hasDetails,
  });

  final GrammarStatus status;
  final int issueCount;
  final bool hasDetails;

  @override
  Widget build(BuildContext context) {
    final statusText = switch (status) {
      GrammarStatus.idle => 'Sẵn sàng',
      GrammarStatus.warmingUp => 'Đang khởi động LanguageTool…',
      GrammarStatus.checking => 'Đang kiểm tra ngữ pháp…',
      GrammarStatus.success when issueCount == 0 && hasDetails =>
        'Chưa áp dụng gợi ý nào',
      GrammarStatus.success when issueCount == 0 => 'Không phát hiện lỗi',
      GrammarStatus.success => 'Đã sửa $issueCount lỗi',
      GrammarStatus.error => 'Cần thử lại',
    };
    final statusColor = switch (status) {
      GrammarStatus.success => AppColors.success,
      GrammarStatus.error => AppColors.error,
      _ => AppColors.primaryDark,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      child: Row(
        children: [
          const _LanguageLabel(label: 'English (US)', isActive: true),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 19,
              color: AppColors.textMuted,
            ),
          ),
          const Flexible(
            child: _LanguageLabel(label: 'English đã sửa', isActive: true),
          ),
          const Spacer(),
          Flexible(
            child: _StatusBadge(text: statusText, color: statusColor),
          ),
        ],
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
    required this.currentCaptureHotkey,
    required this.currentNewTranslationHotkey,
    required this.currentTranslateHotkey,
    required this.currentSwitchModeHotkey,
    required this.defaultCaptureHotkey,
    required this.defaultNewTranslationHotkey,
    required this.defaultTranslateHotkey,
    required this.defaultSwitchModeHotkey,
    required this.onSave,
  });

  final HotKey currentCaptureHotkey;
  final HotKey currentNewTranslationHotkey;
  final HotKey currentTranslateHotkey;
  final HotKey currentSwitchModeHotkey;
  final HotKey defaultCaptureHotkey;
  final HotKey defaultNewTranslationHotkey;
  final HotKey defaultTranslateHotkey;
  final HotKey defaultSwitchModeHotkey;
  final Future<String?> Function(
    HotKey capture,
    HotKey newTranslation,
    HotKey translate,
    HotKey switchMode,
  )
  onSave;

  @override
  State<_ShortcutSettingsDialog> createState() =>
      _ShortcutSettingsDialogState();
}

enum _ShortcutTarget { capture, newTranslation, translate, switchMode }

class _ShortcutSettingsDialogState extends State<_ShortcutSettingsDialog> {
  static const _supportedModifiers = {
    HotKeyModifier.control,
    HotKeyModifier.alt,
    HotKeyModifier.shift,
    HotKeyModifier.meta,
  };

  late HotKey _captureCandidate;
  late HotKey _newTranslationCandidate;
  late HotKey _translateCandidate;
  late HotKey _switchModeCandidate;
  _ShortcutTarget? _recordingTarget;
  bool _isSaving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _captureCandidate = widget.currentCaptureHotkey;
    _newTranslationCandidate = widget.currentNewTranslationHotkey;
    _translateCandidate = widget.currentTranslateHotkey;
    _switchModeCandidate = widget.currentSwitchModeHotkey;
  }

  bool _isModifierKey(PhysicalKeyboardKey key) {
    return HotKeyModifier.values.any(
      (modifier) => modifier.physicalKeys.contains(key),
    );
  }

  HotKey _candidateFor(_ShortcutTarget target) => switch (target) {
    _ShortcutTarget.capture => _captureCandidate,
    _ShortcutTarget.newTranslation => _newTranslationCandidate,
    _ShortcutTarget.translate => _translateCandidate,
    _ShortcutTarget.switchMode => _switchModeCandidate,
  };

  HotKey _defaultFor(_ShortcutTarget target) => switch (target) {
    _ShortcutTarget.capture => widget.defaultCaptureHotkey,
    _ShortcutTarget.newTranslation => widget.defaultNewTranslationHotkey,
    _ShortcutTarget.translate => widget.defaultTranslateHotkey,
    _ShortcutTarget.switchMode => widget.defaultSwitchModeHotkey,
  };

  void _setCandidate(_ShortcutTarget target, HotKey hotkey) {
    switch (target) {
      case _ShortcutTarget.capture:
        _captureCandidate = hotkey;
      case _ShortcutTarget.newTranslation:
        _newTranslationCandidate = hotkey;
      case _ShortcutTarget.translate:
        _translateCandidate = hotkey;
      case _ShortcutTarget.switchMode:
        _switchModeCandidate = hotkey;
    }
  }

  void _recordHotkey(_ShortcutTarget target, HotKey recorded) {
    final key = recorded.physicalKey;
    final modifiers = (recorded.modifiers ?? const <HotKeyModifier>[])
        .where(_supportedModifiers.contains)
        .toList();
    final allowsPlainEnter =
        target == _ShortcutTarget.translate &&
        (key == PhysicalKeyboardKey.enter ||
            key == PhysicalKeyboardKey.numpadEnter);
    final isReservedShiftEnter =
        target == _ShortcutTarget.translate &&
        allowsPlainEnter &&
        modifiers.length == 1 &&
        modifiers.single == HotKeyModifier.shift;
    if (isReservedShiftEnter) {
      setState(() => _message = 'Shift+Enter được dành để xuống dòng.');
      return;
    }
    if (_isModifierKey(key) || (modifiers.isEmpty && !allowsPlainEnter)) {
      setState(() {
        _message = target == _ShortcutTarget.translate
            ? 'Phím dịch không có bổ trợ chỉ được phép là Enter.'
            : 'Tổ hợp cần có ít nhất Ctrl, Alt, Shift hoặc Win cùng một phím.';
      });
      return;
    }

    setState(() {
      final current = _candidateFor(target);
      _setCandidate(
        target,
        HotKey(
          identifier: current.identifier,
          key: key,
          modifiers: modifiers,
          scope: target == _ShortcutTarget.capture
              ? HotKeyScope.system
              : HotKeyScope.inapp,
        ),
      );
      _recordingTarget = null;
      _message = null;
    });
  }

  void _resetToDefault(_ShortcutTarget target) {
    setState(() {
      final current = _candidateFor(target);
      final defaultHotkey = _defaultFor(target);
      _setCandidate(
        target,
        HotKey(
          identifier: current.identifier,
          key: defaultHotkey.key,
          modifiers: defaultHotkey.modifiers,
          scope: defaultHotkey.scope,
        ),
      );
      _recordingTarget = null;
      _message = null;
    });
  }

  Future<void> _save() async {
    if (_isSaving || _recordingTarget != null) return;
    final signatures = {
      _shortcutSignature(_captureCandidate),
      _shortcutSignature(_newTranslationCandidate),
      _shortcutSignature(_translateCandidate),
      _shortcutSignature(_switchModeCandidate),
    };
    if (signatures.length != 4) {
      setState(() => _message = 'Mỗi hành động cần một phím tắt khác nhau.');
      return;
    }
    setState(() {
      _isSaving = true;
      _message = null;
    });
    final error = await widget.onSave(
      _captureCandidate,
      _newTranslationCandidate,
      _translateCandidate,
      _switchModeCandidate,
    );
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

  String _shortcutSignature(HotKey hotkey) {
    final modifiers =
        (hotkey.modifiers ?? const <HotKeyModifier>[])
            .map((modifier) => modifier.name)
            .toList()
          ..sort();
    return '${hotkey.physicalKey.usbHidUsage}:${modifiers.join(',')}';
  }

  Widget _buildShortcutEditor({
    required _ShortcutTarget target,
    required String title,
    required String description,
    required Key previewKey,
    required Key recorderKey,
    required Key buttonKey,
  }) {
    final candidate = _candidateFor(target);
    final isRecording = _recordingTarget == target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(description, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        Container(
          key: previewKey,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: isRecording
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Nhấn tổ hợp phím mới…'),
                    const SizedBox(height: 10),
                    HotKeyRecorder(
                      key: recorderKey,
                      initalHotKey: candidate,
                      onHotKeyRecorded: (hotkey) =>
                          _recordHotkey(target, hotkey),
                    ),
                  ],
                )
              : HotKeyVirtualView(hotKey: candidate),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: buttonKey,
              onPressed: _isSaving
                  ? null
                  : () => setState(() {
                      _recordingTarget = isRecording ? null : target;
                      _message = null;
                    }),
              icon: Icon(
                isRecording ? Icons.close_rounded : Icons.keyboard_rounded,
                size: 18,
              ),
              label: Text(isRecording ? 'Hủy ghi' : 'Thay đổi'),
            ),
            TextButton(
              onPressed: _isSaving ? null : () => _resetToDefault(target),
              child: const Text('Khôi phục mặc định'),
            ),
          ],
        ),
      ],
    );
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
              value: 'RapidOCR + CTranslate2 + LanguageTool',
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Divider(height: 1),
            ),
            _buildShortcutEditor(
              target: _ShortcutTarget.capture,
              title: 'Chụp vùng màn hình',
              description:
                  'Hoạt động trên toàn hệ thống, kể cả khi cửa sổ đang ẩn.',
              previewKey: const Key('shortcut-preview'),
              recorderKey: const Key('hotkey-recorder'),
              buttonKey: const Key('record-shortcut-button'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),
            _buildShortcutEditor(
              target: _ShortcutTarget.newTranslation,
              title: 'Bản dịch mới',
              description:
                  'Xóa nội dung hiện tại và đưa con trỏ về ô văn bản nguồn.',
              previewKey: const Key('new-shortcut-preview'),
              recorderKey: const Key('new-hotkey-recorder'),
              buttonKey: const Key('record-new-shortcut-button'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),
            _buildShortcutEditor(
              target: _ShortcutTarget.translate,
              title: 'Dịch văn bản nhập tay',
              description:
                  'Chỉ hoạt động khi đang nhập ô nguồn. Dùng Shift+Enter để xuống dòng.',
              previewKey: const Key('translate-shortcut-preview'),
              recorderKey: const Key('translate-hotkey-recorder'),
              buttonKey: const Key('record-translate-shortcut-button'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),
            _buildShortcutEditor(
              target: _ShortcutTarget.switchMode,
              title: 'Chuyển Dịch / Ngữ pháp',
              description:
                  'Chuyển qua lại giữa hai chức năng ở bất kỳ ô nhập nào.',
              previewKey: const Key('switch-mode-shortcut-preview'),
              recorderKey: const Key('switch-mode-hotkey-recorder'),
              buttonKey: const Key('record-switch-mode-shortcut-button'),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(
                _message!,
                key: const Key('shortcut-message'),
                style: const TextStyle(color: AppColors.error, fontSize: 12),
              ),
            ],
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
          onPressed: _isSaving || _recordingTarget != null ? null : _save,
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
