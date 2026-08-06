import 'package:window_manager/window_manager.dart';

abstract interface class AppWindowService {
  Future<void> hideForCapture();

  Future<void> restoreAfterCapture();
}

class DesktopAppWindowService implements AppWindowService {
  DesktopAppWindowService({
    this.hideSettleDuration = const Duration(milliseconds: 180),
  });

  final Duration hideSettleDuration;

  @override
  Future<void> hideForCapture() async {
    await windowManager.hide();
    await Future<void>.delayed(hideSettleDuration);
  }

  @override
  Future<void> restoreAfterCapture() async {
    await windowManager.show();
    await windowManager.focus();
  }
}
