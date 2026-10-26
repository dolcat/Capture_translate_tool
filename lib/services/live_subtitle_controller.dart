import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/live_settings.dart';
import 'live_settings_store.dart';
import 'live_subtitle_service.dart';

/// Owns the live subtitle session: settings, the running state, and the
/// subtitles the backend has translated so far.
class LiveSubtitleController extends ChangeNotifier {
  LiveSubtitleController({
    required this.service,
    required this.store,
    this.minimizeWindow,
    this.pollInterval = const Duration(milliseconds: 500),
  });

  final LiveSubtitleService service;
  final LiveSettingsStore store;

  /// Called when a session starts and "minimize on start" is on, so the app
  /// window does not cover the subtitles being watched.
  final Future<void> Function()? minimizeWindow;
  final Duration pollInterval;

  LiveSettings _settings = const LiveSettings();
  LiveStatus _status = const LiveStatus();
  final List<LiveEntry> _history = [];
  bool _loaded = false;
  bool _running = false;
  bool _busy = false;
  bool _selecting = false;
  bool _disposed = false;
  String? _error;
  int _lastSeq = 0;
  Timer? _poll;
  Timer? _pushTimer;
  bool _polling = false;

  LiveSettings get settings => _settings;
  LiveStatus get status => _status;
  List<LiveEntry> get history => List.unmodifiable(_history);
  bool get loaded => _loaded;
  bool get isRunning => _running;
  bool get isBusy => _busy;
  bool get isSelecting => _selecting;
  String? get error => _error;

  Future<void> load() async {
    _settings = await store.load();
    _loaded = true;
    _notify();
  }

  Future<void> selectRegion() async {
    if (_selecting) return;
    _selecting = true;
    _error = null;
    _notify();
    try {
      final region = await service.selectRegion();
      if (region != null) {
        await updateSettings(_settings.copyWith(region: region));
      }
    } on LiveSubtitleException catch (error) {
      _error = error.message;
    } finally {
      _selecting = false;
      _notify();
    }
  }

  Future<void> toggle() => _running ? stop() : start();

  Future<void> start() async {
    if (_running || _busy) return;
    if (_settings.region == null) {
      _error = 'Hãy chọn vùng phụ đề trước khi bắt đầu.';
      _notify();
      return;
    }
    _busy = true;
    _error = null;
    _notify();
    try {
      await service.start(_settings);
      _running = true;
      _history.clear();
      _lastSeq = 0;
      _status = const LiveStatus(running: true);
      _poll = Timer.periodic(pollInterval, (_) => unawaited(_refresh()));
      if (_settings.minimizeOnStart) {
        try {
          await minimizeWindow?.call();
        } catch (_) {
          // Not being able to minimise is harmless.
        }
      }
    } on LiveSubtitleException catch (error) {
      _error = error.message;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> stop() async {
    if (!_running || _busy) return;
    _busy = true;
    _notify();
    _poll?.cancel();
    _poll = null;
    try {
      await service.stop();
    } on LiveSubtitleException catch (error) {
      _error = error.message;
    } finally {
      _running = false;
      _busy = false;
      _notify();
    }
  }

  /// Saves the new settings and, while running, applies them after a short
  /// pause so dragging a slider does not flood the backend.
  Future<void> updateSettings(LiveSettings next) async {
    _settings = next;
    _notify();
    try {
      await store.save(next);
    } catch (_) {
      // A failed save only means settings are not remembered next time.
    }
    if (!_running) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 400), () async {
      try {
        await service.configure(_settings);
      } on LiveSubtitleException catch (error) {
        _error = error.message;
        _notify();
      }
    });
  }

  Future<void> _refresh() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final status = await service.status();
      final entries = status.seq > _lastSeq
          ? await service.history(_lastSeq)
          : const <LiveEntry>[];
      if (_disposed) return;
      for (final entry in entries) {
        _history.add(entry);
        _lastSeq = entry.seq;
      }
      if (_history.length > 50) _history.removeRange(0, _history.length - 50);
      _status = status;
      _error = status.error;
      await _followWindow(status);
      _notify();
    } on LiveSubtitleException catch (error) {
      _error = error.message;
      _notify();
    } finally {
      _polling = false;
    }
  }

  /// Keeps the settings in step with the separate translation window: remember
  /// where the user moved it, and switch the setting off when they close it.
  Future<void> _followWindow(LiveStatus status) async {
    var next = _settings;
    if (status.windowClosed && next.windowEnabled) {
      next = next.copyWith(windowEnabled: false);
      // The backend forgets "closed" once it is told the window is off.
      _pushSettings(next);
    }
    final rect = status.windowRect;
    if (rect != null && rect != next.windowRect) {
      next = next.copyWith(windowRect: rect); // saved only; the backend knows
    }
    if (identical(next, _settings)) return;
    _settings = next;
    try {
      await store.save(next);
    } catch (_) {
      // Not remembering the position is harmless.
    }
  }

  void _pushSettings(LiveSettings settings) {
    unawaited(
      service.configure(settings).catchError((Object error) {
        _error = error is LiveSubtitleException ? error.message : '$error';
        _notify();
      }),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _pushTimer?.cancel();
    if (_running) unawaited(service.stop().catchError((_) {}));
    service.close();
    super.dispose();
  }
}
