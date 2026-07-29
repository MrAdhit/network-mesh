/// The theme carrier: an InheritedWidget holding the resolved [FilamentTokens]
/// and the type scale, plus the three-way theme mode the app switches on.
library;

import 'package:flutter/widgets.dart';

import 'tokens.dart';

export 'tokens.dart';

/// Dark, light, or follow the OS.
enum MeshThemeMode {
  dark,
  light,
  system;

  /// The label the settings screen shows.
  String get label => switch (this) {
    MeshThemeMode.dark => 'Dark',
    MeshThemeMode.light => 'Light',
    MeshThemeMode.system => 'System',
  };

  /// Resolves against the platform brightness for [MeshThemeMode.system].
  Brightness resolve(Brightness platform) => switch (this) {
    MeshThemeMode.dark => Brightness.dark,
    MeshThemeMode.light => Brightness.light,
    MeshThemeMode.system => platform,
  };

  static MeshThemeMode fromName(String? name) => MeshThemeMode.values
      .firstWhere((m) => m.name == name, orElse: () => MeshThemeMode.system);
}

/// What a coloured pixel is saying. State is the decoration: a widget takes a
/// tone, not a colour, so "down" is the same red everywhere.
enum MeshTone {
  /// No statement. Hairlines and dim text.
  neutral,

  /// Up, winning, the one primary action.
  signal,

  /// Up but not winning.
  signalDim,

  /// Degraded, lossy, expiring.
  caution,

  /// Down, errors, destructive.
  alarm,

  /// Links, relay/info accents.
  link;

  Color color(FilamentTokens t) => switch (this) {
    MeshTone.neutral => t.textDim,
    MeshTone.signal => t.signal,
    MeshTone.signalDim => t.signalDim,
    MeshTone.caution => t.caution,
    MeshTone.alarm => t.alarm,
    MeshTone.link => t.link,
  };

  /// The quiet fill behind a badge or chip of this tone.
  Color fill(FilamentTokens t) => this == MeshTone.neutral
      ? t.surfaceHigh
      : color(t).withValues(alpha: 0.14);

  /// The border for a badge or chip of this tone.
  Color border(FilamentTokens t) =>
      this == MeshTone.neutral ? t.hairline : color(t).withValues(alpha: 0.35);
}

/// The mono stack from DESIGN.md. Every number, address, key, hash and unit is
/// set in this face; the UI face is deliberately whatever the platform uses.
const String _monoFamily = 'SF Mono';
const List<String> _monoFallback = <String>[
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
  'monospace',
];

/// Digits that line up in a column. Data cells and live values need this or
/// they shimmer as values tick.
const List<FontFeature> _tabular = <FontFeature>[
  FontFeature.tabularFigures(),
  FontFeature.slashedZero(),
];

/// The type scale, pre-coloured for one palette.
///
/// Sizes are the ones DESIGN.md fixes: 11 labels (tracked +0.5), 13 base, 14
/// emphasised, 15 section titles, 18–20 stat-tile numbers, 44 the single
/// headline number on Overview. Weights are 400/500/600 and nothing else.
///
/// Values outrank their labels everywhere: a reading is set two steps larger
/// than the label above it, which is what makes the eye land on numbers first.
class FilamentTypography {
  FilamentTypography(this.tokens);

  final FilamentTokens tokens;

  // ---- UI face ----

  /// 11/500 in `textDim`, tracked +0.5. Column headers, field and tile labels.
  ///
  /// The tracking is what keeps 11px from reading as a squashed version of the
  /// body size instead of as a different kind of thing.
  TextStyle get label => TextStyle(
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: tokens.textDim,
    letterSpacing: 0.5,
  );

  /// 11/400 in `textFaint`. Hints, secondary annotations. Untracked: this is
  /// prose that should recede, not a label that should read as a heading.
  TextStyle get small =>
      TextStyle(fontSize: 11, height: 1.4, color: tokens.textFaint);

  /// 13/400 in `text`. The base UI size.
  TextStyle get body =>
      TextStyle(fontSize: 13, height: 1.4, color: tokens.text);

  /// 13/400 in `textDim`. Body copy that should recede.
  TextStyle get bodyDim =>
      TextStyle(fontSize: 13, height: 1.4, color: tokens.textDim);

  /// 14/600 in `text`. Emphasised rows, the app mark.
  TextStyle get emphasis => TextStyle(
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: tokens.text,
  );

  /// 15/600 in `text`. Panel titles and screen titles.
  TextStyle get section => TextStyle(
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: tokens.text,
  );

  /// 20/600 in `text`. The title of a full-window stage, and nothing else.
  ///
  /// One step above [section], on the same scale the mono face uses for its
  /// heroes: a whole window with one sentence in it needs a title that carries
  /// the room, and 15px in the middle of 720px of space reads as a caption.
  TextStyle get stage => TextStyle(
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: tokens.text,
  );

  // ---- Data face ----

  /// 11 mono in `textDim`.
  TextStyle get monoSmall => _mono(11, tokens.textDim);

  /// 13 mono in `text`. The default data cell.
  TextStyle get mono => _mono(13, tokens.text);

  /// 14/500 mono in `text`.
  TextStyle get monoEmphasis => _mono(14, tokens.text, FontWeight.w500);

  /// 15/500 mono in `text`.
  TextStyle get monoSection => _mono(15, tokens.text, FontWeight.w500);

  /// 18/600 mono. The number on a stat tile.
  TextStyle get stat => _mono(18, tokens.text, FontWeight.w600);

  /// 20/600 mono. A stat tile carrying the screen's most important reading.
  TextStyle get hero => _mono(20, tokens.text, FontWeight.w600);

  /// 44/600 mono. The single headline number on Overview, and nothing else.
  TextStyle get headline => _mono(44, tokens.text, FontWeight.w600);

  /// Units sit in `textFaint` one size below their number. Pass the number's
  /// size; you get the unit's style.
  TextStyle unitFor(TextStyle numberStyle) => _mono(
    _unitSizeFor(numberStyle.fontSize ?? 13),
    tokens.textFaint,
  ).copyWith(fontWeight: FontWeight.w400);

  /// Errors are quoted verbatim from the daemon or control plane, in mono.
  TextStyle get error => _mono(13, tokens.alarm);

  /// The mono face at an arbitrary size, for the rare one-off.
  TextStyle monoAt(double size, {Color? color, FontWeight? weight}) =>
      _mono(size, color ?? tokens.text, weight);

  TextStyle _mono(double size, Color color, [FontWeight? weight]) => TextStyle(
    fontFamily: _monoFamily,
    fontFamilyFallback: _monoFallback,
    fontFeatures: _tabular,
    fontSize: size,
    height: 1.35,
    fontWeight: weight ?? FontWeight.w400,
    color: color,
  );

  /// The next step down the scale, used for units.
  static double _unitSizeFor(double size) {
    const steps = <double>[11, 13, 14, 15, 18, 20, 44];
    final i = steps.indexOf(size);
    if (i > 0) return steps[i - 1];
    if (i == 0) return 11;
    // Off-scale size: shave a proportional amount rather than snapping.
    return (size * 0.8).clamp(9, size);
  }
}

/// Provides [FilamentTokens] and [FilamentTypography] to the tree.
///
/// Installed by `MeshApp`. Nothing else should construct one except tests and
/// the odd preview.
class FilamentTheme extends InheritedWidget {
  FilamentTheme({required this.tokens, required super.child, super.key})
    : type = FilamentTypography(tokens);

  final FilamentTokens tokens;
  final FilamentTypography type;

  static FilamentTheme of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<FilamentTheme>();
    assert(
      theme != null,
      'No FilamentTheme above this widget. Wrap in MeshApp.',
    );
    return theme!;
  }

  /// Tokens without a full [of] lookup at the call site.
  static FilamentTokens tokensOf(BuildContext context) => of(context).tokens;

  /// Type scale without a full [of] lookup at the call site.
  static FilamentTypography typeOf(BuildContext context) => of(context).type;

  @override
  bool updateShouldNotify(FilamentTheme oldWidget) =>
      oldWidget.tokens.brightness != tokens.brightness;
}
