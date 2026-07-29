/// Renders the macOS app icon: the Mesh triad mark on a Filament plate.
///
///     flutter test tool/render_app_icon.dart
///
/// Set `MESH_ICON_REVIEW_DIR` to drop review copies of 16/32/128/1024
/// somewhere outside the tree as well, plus a 1024 of the variant that is not
/// shipping, so the two can be looked at side by side:
///
///     MESH_ICON_REVIEW_DIR=/tmp/icons flutter test tool/render_app_icon.dart
///
/// It runs under `flutter test` because that is the cheapest way to get a live
/// engine — nothing here is a test of the app, it is a build step that happens
/// to need `dart:ui`. Rerunnable: it overwrites the asset catalog in place, and
/// the sizes it renders are read out of `Contents.json` rather than guessed, so
/// the catalog stays the single source of truth for which files exist.
///
/// The mark is `_AppMark` from `kit/rail.dart`, in the rail's exact geometry:
/// three bottom-aligned pills, equal widths, 60/100/60 heights, a gap of two
/// thirds of a bar, and a bloom on the tall middle one. It ships in the rail's
/// own colours too — see [_Variant]. Set `MESH_ICON_VARIANT=signal` to compile
/// the green one into the catalog instead of just reviewing it.
///
/// Every size is drawn, not scaled. At 32 and below the haze and the edge light
/// are below the resolution that could carry them — they would only silt up the
/// silhouette — so those sizes drop them, fatten the bars and snap to whole
/// pixels, which is what keeps 16 legible. That is also why the icon is not
/// generated from the SVG: one vector scaled seven ways gives you a mushy 16.
///
/// **The canonical art is `assets/brand/*.svg`, not this file.** The SVGs are
/// what anyone drawing the logo should open — docs, the web, a slide. This is
/// the pipeline that compiles the appiconset PNGs, and the two are expected to
/// agree: every constant below has a twin in `icon-mono.svg`, and a change to
/// one that is not made in the other is a bug. If you retune the geometry, the
/// gradients or the palette here, re-cut the SVGs in the same pass and check
/// the 1024 render against them.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_app/src/theme/tokens.dart';

/// The palette. The icon is brand, and brand is dark: it does not follow the
/// system theme, so this is the dark palette always.
const FilamentTokens _tokens = FilamentTokens.dark();

/// How the triad is coloured. The plate underneath is the same either way.
///
/// [mono] ships. It is `_AppMark`'s own colouring, bar for bar, and it carries
/// the rail's argument onto the brand: green is what the app says when it has
/// measured something, so an icon — which has measured nothing — has no
/// business wearing it. [signal] is kept because it is worth being able to look
/// at, not because anything renders it by default.
class _Variant {
  const _Variant._(this.name, {required this.hazeScale});

  /// The rail's mark: `textFaint` flanks, `text` middle, blooming near-white.
  static const _Variant mono = _Variant._('mono', hazeScale: 1.25);

  /// The same mark in `signal`, bloom included.
  static const _Variant signal = _Variant._('signal', hazeScale: 2.5);

  static const List<_Variant> all = <_Variant>[mono, signal];

  final String name;

  /// What the plate's green haze runs at, as a multiple of `hazeOpacity`.
  ///
  /// Green behind green is atmosphere; green behind a near-white bar is a
  /// colour cast, because there is nothing in the mark to absorb it. So [mono]
  /// takes half of what [signal] does — 5% rather than 10% — which at 256px is
  /// the point where you stop reading it as a tint under the bars and start
  /// reading it as depth behind them. Halved rather than dropped on purpose:
  /// it is the one whisper of brand green the mono icon keeps.
  final double hazeScale;

  Color get flank => this == signal ? _tokens.signal : _tokens.textFaint;

  Color get tall => this == signal ? _tokens.signal : _tokens.text;

  /// A bloom is the colour of the thing that casts it.
  Color get bloom => tall;

  /// Whether the tall bar still blooms below [_depthFloor].
  ///
  /// At 32px a bloom is two pixels of halo, and near-white throws a far
  /// brighter one than `signal` does over the same near-black plate: it stops
  /// reading as glow and starts reading as a bar that failed to render
  /// sharply, next to two flanks that came out crisp. [mono] does not need it
  /// — `text` already outranks `textFaint` by two steps of lightness, which is
  /// the whole hierarchy the bloom was there to carry.
  bool get bloomsWhenSmall => this == signal;

  _Variant get other => this == mono ? signal : mono;
}

/// Which variant the asset catalog gets. `MESH_ICON_VARIANT` overrides it.
_Variant _shipped() {
  final want = Platform.environment['MESH_ICON_VARIANT'];
  if (want == null || want.isEmpty) return _Variant.mono;
  return _Variant.all.firstWhere(
    (v) => v.name == want,
    orElse: () => throw StateError(
      '$want is not a variant; try ${_Variant.all.map((v) => v.name).join(' or ')}',
    ),
  );
}

/// Apple's Big Sur icon grid: an 824pt plate centred in a 1024pt canvas, with
/// a corner radius of 22.5% of the plate. Expressed as ratios so every size
/// lands on the same shape.
const double _plateInsetRatio = 0.0977;
const double _cornerRatio = 0.225;

/// The tall bar as a fraction of the plate, and the rail's own 6:1 ratio of
/// tall-bar height to bar width — which fixes the whole triad, since the gap is
/// two thirds of a bar and the short bars are 60%.
const double _markHeightRatio = 0.60;
const double _barsPerTall = 6;
const double _gapRatio = 2 / 3;
const double _shortRatio = 0.6;

/// The triad's mass sits low — two of the three bars only occupy the bottom
/// 60% — so a geometrically centred mark reads as having sagged. Lift it by 2%
/// of the plate and it sits where the eye expects.
const double _opticalLift = 0.02;

/// Which sizes get the full depth treatment: haze, edge light, wide bloom.
const int _depthFloor = 64;

void main() {
  test('renders the macOS app icon set', () async {
    final root = _packageRoot();
    final catalog = Directory(
      '${root.path}/macos/Runner/Assets.xcassets/AppIcon.appiconset',
    );
    expect(
      catalog.existsSync(),
      isTrue,
      reason: 'no asset catalog at ${catalog.path}',
    );

    final sizes = _catalogSizes(File('${catalog.path}/Contents.json'));
    expect(sizes, isNotEmpty, reason: 'Contents.json names no icon files');

    final review = Platform.environment['MESH_ICON_REVIEW_DIR'];
    final reviewDir = review == null || review.isEmpty
        ? null
        : (Directory(review)..createSync(recursive: true));

    final shipped = _shipped();
    // ignore: avoid_print
    print('  shipping the ${shipped.name} mark');

    for (final size in sizes) {
      final bytes = await _render(size, shipped);
      final file = File('${catalog.path}/app_icon_$size.png');
      file.writeAsBytesSync(bytes, flush: true);
      // ignore: avoid_print
      print(
        '  ${size.toString().padLeft(4)}px  ${bytes.length} bytes  '
        '${file.path}',
      );

      if (reviewDir != null && const [16, 32, 128, 1024].contains(size)) {
        File('${reviewDir.path}/icon-$size.png').writeAsBytesSync(bytes);
      }

      expect(bytes.length, greaterThan(0));
      expect(file.lengthSync(), bytes.length);
    }

    // The variant that is not shipping, at 1024 only, so the two can be put
    // next to each other without either one reaching the bundle.
    if (reviewDir != null) {
      final other = shipped.other;
      final bytes = await _render(1024, other);
      File(
        '${reviewDir.path}/icon-1024-${other.name}.png',
      ).writeAsBytesSync(bytes);
      // ignore: avoid_print
      print('  1024px  ${bytes.length} bytes  ${other.name} (review only)');
      expect(bytes.length, greaterThan(0));
    }
  });
}

// ---------------------------------------------------------------------------
// the drawing
// ---------------------------------------------------------------------------

Future<List<int>> _render(int size, _Variant variant) async {
  final plan = _Plan.forSize(size);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  final plate = plan.plate;
  final shape = RSuperellipse.fromRectXY(plate, plan.corner, plan.corner);

  // The plate: `bg`, lit from above. Same instruction as `panelFill` — lean the
  // top toward `surfaceHigh` and let it fall back to the base — just longer and
  // quieter, because this is a background and not a card.
  canvas.drawRSuperellipse(
    shape,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color.lerp(_tokens.bg, _tokens.surfaceHigh, 0.6)!,
          _tokens.bg,
        ],
        stops: const <double>[0, 0.72],
      ).createShader(plate),
  );

  // Everything atmospheric is clipped to the plate: a blur that leaks past the
  // corner is the one thing that would give the shape away as a fake.
  canvas.save();
  canvas.clipRSuperellipse(shape);

  if (plan.depth) {
    // The window's phosphor haze, opened up: on a 1024px plate the 4% it runs
    // at in the app is nothing at all, and the mark needs something to sit in.
    // Green in both variants — it is atmosphere, not a reading. See
    // [_Variant.hazeScale] for why mono takes less of it.
    final centre = Offset(plan.size / 2, plan.markCentreY);
    final radius = plate.width * 0.6;
    final scale = variant.hazeScale;
    canvas.drawRect(
      plate,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            _tokens.signal.withValues(alpha: _tokens.hazeOpacity * scale),
            _tokens.signal.withValues(
              alpha: _tokens.hazeOpacity * scale * 0.44,
            ),
            _tokens.signal.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: centre, radius: radius)),
    );
  }

  final bars = plan.bars;

  // The tall bar's bloom, under all three. Two passes: a wide one for the glow
  // in the air around it, a tight one for the heat at the bar itself.
  final bloomScale = plan.depth || variant.bloomsWhenSmall
      ? plan.bloomScale
      : 0.0;
  if (bloomScale > 0) {
    final tall = bars[1];
    if (plan.depth) {
      canvas.drawRRect(
        tall,
        Paint()
          ..color = variant.bloom.withValues(alpha: _tokens.bloomOpacity * 0.8)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            plan.barWidth * 1.5 * bloomScale,
          ),
      );
    }
    canvas.drawRRect(
      tall,
      Paint()
        ..color = variant.bloom.withValues(alpha: _tokens.bloomOpacity * 1.2)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          plan.barWidth * 0.5 * bloomScale,
        ),
    );
  }

  // Flanks, then the tall one, in the mark's own order.
  final flank = Paint()..color = variant.flank;
  canvas.drawRRect(bars[0], flank);
  canvas.drawRRect(bars[2], flank);
  canvas.drawRRect(bars[1], Paint()..color = variant.tall);

  canvas.restore();

  // The inner top edge, last, on top of everything: a reflection is the colour
  // of the light, not of the thing, so it is `edgeLight` and not `text`.
  if (plan.depth) {
    final width = plan.edgeWidth;
    canvas.drawRSuperellipse(
      RSuperellipse.fromRectXY(
        plate.deflate(width / 2),
        plan.corner - width / 2,
        plan.corner - width / 2,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            _tokens.edgeLight,
            _tokens.edgeLight.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.35],
        ).createShader(plate),
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  if (data == null) throw StateError('the engine encoded no PNG for $size');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

// ---------------------------------------------------------------------------
// the geometry
// ---------------------------------------------------------------------------

/// One size, resolved to pixels.
class _Plan {
  const _Plan._({
    required this.size,
    required this.inset,
    required this.barWidth,
    required this.gap,
    required this.tall,
    required this.short,
    required this.left,
    required this.bottom,
    required this.depth,
    required this.bloomScale,
  });

  /// The small sizes are drawn by hand rather than derived, because below 32px
  /// the derivation is dominated by rounding: what matters there is that the
  /// bars land on whole pixels and stay at least 2px wide, and hand numbers say
  /// that in one line instead of three ratios and a rounding rule.
  factory _Plan.forSize(int size) {
    switch (size) {
      case 16:
        // A 14px plate, 2px bars, 1px gaps. Any thinner and the outer bars
        // antialias into the background and the triad becomes one smear.
        return const _Plan._(
          size: 16,
          inset: 1,
          barWidth: 2,
          gap: 1,
          tall: 9,
          short: 5,
          left: 4,
          bottom: 12,
          depth: false,
          bloomScale: 0,
        );
      case 32:
        // The rail's own numbers, exactly: 3px bars, 2px gaps.
        return const _Plan._(
          size: 32,
          inset: 3,
          barWidth: 3,
          gap: 2,
          tall: 15,
          short: 9,
          left: 9,
          bottom: 23,
          depth: false,
          bloomScale: 0.45,
        );
    }

    final s = size.toDouble();
    // Up to 128px a bar edge that lands mid-pixel is a visibly soft bar, so
    // everything snaps. Past that the antialiasing is finer than the artifact.
    final snap = size <= 128;
    double fit(double v) => snap ? v.roundToDouble() : v;

    final inset = fit(s * _plateInsetRatio);
    final plateSize = s - inset * 2;
    final barWidth = fit(plateSize * _markHeightRatio / _barsPerTall);
    final gap = fit(barWidth * _gapRatio);
    final tall = fit(barWidth * _barsPerTall);
    final short = fit(tall * _shortRatio);
    final width = barWidth * 3 + gap * 2;

    return _Plan._(
      size: s,
      inset: inset,
      barWidth: barWidth,
      gap: gap,
      tall: tall,
      short: short,
      left: fit((s - width) / 2),
      bottom: fit(inset + (plateSize + tall) / 2 - plateSize * _opticalLift),
      depth: size >= _depthFloor,
      bloomScale: 1,
    );
  }

  final double size;
  final double inset;
  final double barWidth;
  final double gap;
  final double tall;
  final double short;

  /// Left edge of the first bar, and the baseline all three sit on.
  final double left;
  final double bottom;

  /// Haze, inner edge light and the wide half of the bloom.
  final bool depth;

  /// 0 for no bloom at all.
  final double bloomScale;

  Rect get plate =>
      Rect.fromLTWH(inset, inset, size - inset * 2, size - inset * 2);

  double get corner => plate.width * _cornerRatio;

  double get edgeWidth => size * 0.0045 < 1 ? 1 : size * 0.0045;

  double get markCentreY => bottom - tall / 2;

  /// The three bars, in rail order, with fully rounded caps.
  List<RRect> get bars {
    final radius = Radius.circular(barWidth / 2);
    RRect at(double x, double height) => RRect.fromRectAndRadius(
      Rect.fromLTWH(x, bottom - height, barWidth, height),
      radius,
    );
    final step = barWidth + gap;
    return <RRect>[
      at(left, short),
      at(left + step, tall),
      at(left + step * 2, short),
    ];
  }
}

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

/// The sizes the asset catalog actually asks for. Reading them out of
/// `Contents.json` means adding an entry there is the whole change: this tool
/// never has its own opinion about which files should exist.
List<int> _catalogSizes(File contents) {
  final decoded =
      jsonDecode(contents.readAsStringSync()) as Map<String, Object?>;
  final images = decoded['images'] as List<Object?>;
  final pattern = RegExp(r'^app_icon_(\d+)\.png$');
  final sizes = <int>{};
  for (final entry in images) {
    final name = (entry as Map<String, Object?>)['filename'] as String?;
    if (name == null || name.isEmpty) continue;
    final match = pattern.firstMatch(name);
    if (match == null) {
      throw StateError('$name is not a size this tool knows how to render');
    }
    sizes.add(int.parse(match.group(1)!));
  }
  return sizes.toList()..sort();
}

/// `flutter test` runs from the package root, but resolve it rather than trust
/// it so the tool works from a subdirectory too.
Directory _packageRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'run this from the app package: flutter test tool/render_app_icon.dart',
  );
}
