/// A rectangle on the screen in physical pixels.
class LiveRegion {
  const LiveRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory LiveRegion.fromJson(Map<String, dynamic> json) {
    int read(String key) => (json[key] as num?)?.round() ?? 0;
    return LiveRegion(
      x: read('x'),
      y: read('y'),
      width: read('width'),
      height: read('height'),
    );
  }

  final int x;
  final int y;
  final int width;
  final int height;

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  String get label => '$width × $height  (tại $x, $y)';

  @override
  bool operator ==(Object other) =>
      other is LiveRegion &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// One line of a glossary or fix list: `from => to`.
class TermRule {
  const TermRule(this.from, this.to);

  final String from;
  final String to;

  Map<String, String> toJson() => {'from': from, 'to': to};

  /// Parses text where each line is `từ gốc => thay bằng`. A line with no
  /// arrow is a term to keep exactly as it is. Blank lines and lines starting
  /// with `#` are ignored.
  static List<TermRule> parse(String text) {
    final rules = <TermRule>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final arrow = line.indexOf('=>');
      if (arrow < 0) {
        rules.add(TermRule(line, ''));
        continue;
      }
      final from = line.substring(0, arrow).trim();
      if (from.isEmpty) continue;
      rules.add(TermRule(from, line.substring(arrow + 2).trim()));
    }
    return rules;
  }
}

/// Returns `#RRGGBB` (upper case) for text like `ff8800`, `#FF8800`, or null
/// when it is not a valid six-digit hex colour.
String? normalizeHexColor(String input) {
  final text = input.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(text)) return null;
  return '#${text.toUpperCase()}';
}

/// The 24-bit RGB value of a colour from [normalizeHexColor].
int rgbOfHex(String hex) => int.parse(hex.replaceFirst('#', ''), radix: 16);

enum OverlayPosition {
  cover('cover', 'Che phụ đề gốc'),
  below('below', 'Bên dưới'),
  above('above', 'Bên trên');

  const OverlayPosition(this.wire, this.label);

  final String wire;
  final String label;

  static OverlayPosition fromWire(String? value) => OverlayPosition.values
      .firstWhere((p) => p.wire == value, orElse: () => OverlayPosition.cover);
}

class LiveSettings {
  const LiveSettings({
    this.region,
    this.intervalMs = 300,
    this.stableMs = 300,
    this.beamSize = 2,
    this.glossaryText = '',
    this.fixesText = '',
    this.overlayEnabled = true,
    this.position = OverlayPosition.cover,
    this.fontSize = 28,
    this.opacity = 85,
    this.showOriginal = false,
    this.textColor = defaultTextColor,
    this.backgroundColor = defaultBackgroundColor,
    this.minimizeOnStart = true,
  });

  static const defaultTextColor = '#FFFFFF';
  static const defaultBackgroundColor = '#0C0C0E';

  factory LiveSettings.fromJson(Map<String, dynamic> json) {
    int readInt(String key, int fallback, int min, int max) {
      final value = json[key];
      if (value is! num) return fallback;
      return value.round().clamp(min, max);
    }

    final region = json['region'];
    return LiveSettings(
      region: region is Map
          ? LiveRegion.fromJson(
              region.map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
      intervalMs: readInt('intervalMs', 300, 100, 3000),
      stableMs: readInt('stableMs', 300, 0, 3000),
      beamSize: readInt('beamSize', 2, 1, 5),
      glossaryText: json['glossaryText'] as String? ?? '',
      fixesText: json['fixesText'] as String? ?? '',
      overlayEnabled: json['overlayEnabled'] as bool? ?? true,
      position: OverlayPosition.fromWire(json['position'] as String?),
      fontSize: readInt('fontSize', 28, 12, 96),
      opacity: readInt('opacity', 85, 30, 100),
      showOriginal: json['showOriginal'] as bool? ?? false,
      textColor:
          normalizeHexColor(json['textColor'] as String? ?? '') ??
          defaultTextColor,
      backgroundColor:
          normalizeHexColor(json['backgroundColor'] as String? ?? '') ??
          defaultBackgroundColor,
      minimizeOnStart: json['minimizeOnStart'] as bool? ?? true,
    );
  }

  final LiveRegion? region;
  final int intervalMs;
  final int stableMs;
  final int beamSize;
  final String glossaryText;
  final String fixesText;
  final bool overlayEnabled;
  final OverlayPosition position;
  final int fontSize;
  final int opacity;
  final bool showOriginal;

  /// `#RRGGBB` colours of the subtitle text and its background bar.
  final String textColor;
  final String backgroundColor;
  final bool minimizeOnStart;

  LiveSettings copyWith({
    LiveRegion? region,
    int? intervalMs,
    int? stableMs,
    int? beamSize,
    String? glossaryText,
    String? fixesText,
    bool? overlayEnabled,
    OverlayPosition? position,
    int? fontSize,
    int? opacity,
    bool? showOriginal,
    String? textColor,
    String? backgroundColor,
    bool? minimizeOnStart,
  }) {
    return LiveSettings(
      region: region ?? this.region,
      intervalMs: intervalMs ?? this.intervalMs,
      stableMs: stableMs ?? this.stableMs,
      beamSize: beamSize ?? this.beamSize,
      glossaryText: glossaryText ?? this.glossaryText,
      fixesText: fixesText ?? this.fixesText,
      overlayEnabled: overlayEnabled ?? this.overlayEnabled,
      position: position ?? this.position,
      fontSize: fontSize ?? this.fontSize,
      opacity: opacity ?? this.opacity,
      showOriginal: showOriginal ?? this.showOriginal,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      minimizeOnStart: minimizeOnStart ?? this.minimizeOnStart,
    );
  }

  /// What is saved to disk.
  Map<String, dynamic> toJson() => {
    if (region != null) 'region': region!.toJson(),
    'intervalMs': intervalMs,
    'stableMs': stableMs,
    'beamSize': beamSize,
    'glossaryText': glossaryText,
    'fixesText': fixesText,
    'overlayEnabled': overlayEnabled,
    'position': position.wire,
    'fontSize': fontSize,
    'opacity': opacity,
    'showOriginal': showOriginal,
    'textColor': textColor,
    'backgroundColor': backgroundColor,
    'minimizeOnStart': minimizeOnStart,
  };

  /// What is sent to the backend to start or reconfigure live translation.
  Map<String, dynamic> toBackendJson() => {
    if (region != null) 'region': region!.toJson(),
    'intervalMs': intervalMs,
    'stableMs': stableMs,
    'beamSize': beamSize,
    'pre': TermRule.parse(glossaryText).map((r) => r.toJson()).toList(),
    'post': TermRule.parse(fixesText).map((r) => r.toJson()).toList(),
    'overlay': {
      'enabled': overlayEnabled,
      'position': position.wire,
      'fontSize': fontSize,
      'opacity': opacity,
      'showOriginal': showOriginal,
      'textColor': textColor,
      'backgroundColor': backgroundColor,
    },
  };
}

class LiveEntry {
  const LiveEntry({
    required this.seq,
    required this.original,
    required this.translated,
  });

  factory LiveEntry.fromJson(Map<String, dynamic> json) => LiveEntry(
    seq: (json['seq'] as num?)?.toInt() ?? 0,
    original: json['original'] as String? ?? '',
    translated: json['translated'] as String? ?? '',
  );

  final int seq;
  final String original;
  final String translated;
}

class LiveStatus {
  const LiveStatus({
    this.running = false,
    this.seq = 0,
    this.original = '',
    this.translated = '',
    this.ocrMs = 0,
    this.translateMs = 0,
    this.error,
  });

  factory LiveStatus.fromJson(Map<String, dynamic> json) => LiveStatus(
    running: json['running'] as bool? ?? false,
    seq: (json['seq'] as num?)?.toInt() ?? 0,
    original: json['original'] as String? ?? '',
    translated: json['translated'] as String? ?? '',
    ocrMs: (json['ocrMs'] as num?)?.toInt() ?? 0,
    translateMs: (json['translateMs'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );

  final bool running;
  final int seq;
  final String original;
  final String translated;
  final int ocrMs;
  final int translateMs;
  final String? error;
}
