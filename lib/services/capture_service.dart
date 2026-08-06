import 'dart:io';

import 'package:screen_capturer/screen_capturer.dart';

abstract interface class ScreenCaptureService {
  Future<String?> captureRegion();
}

class WindowsScreenCaptureService implements ScreenCaptureService {
  @override
  Future<String?> captureRegion() async {
    final captureDirectory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}capture_translate_tool',
    );
    await captureDirectory.create(recursive: true);

    final imagePath =
        '${captureDirectory.path}${Platform.pathSeparator}'
        'capture_${DateTime.now().millisecondsSinceEpoch}.png';

    final capturedData = await screenCapturer.capture(
      mode: CaptureMode.region,
      imagePath: imagePath,
      copyToClipboard: false,
    );

    if (capturedData == null || !await File(imagePath).exists()) {
      return null;
    }
    return imagePath;
  }
}
