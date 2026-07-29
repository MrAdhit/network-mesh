/// The app's own preferences: `ui.json`, beside the CLI's `config.json`.
///
/// Kept in a separate file on purpose. `config.json` belongs to `meshctl` and
/// holds a credential; adding `theme` to it would mean the app rewrites a
/// credential file every time somebody flips a switch, and would put app keys
/// in a file another program owns.
///
/// Nothing in here is a secret, so it is written plainly with no fuss about
/// permissions.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../theme/theme.dart';
import 'cli_config.dart';

/// The poll intervals Settings offers. The daemon's own tick is 2s, which is
/// why that is the default.
const List<Duration> pollIntervalChoices = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
];

const Duration defaultPollInterval = Duration(seconds: 2);

/// The file's contents, and nothing more.
@immutable
class UiPrefs {
  const UiPrefs({
    this.themeMode = MeshThemeMode.system,
    this.pollInterval = defaultPollInterval,
  });

  final MeshThemeMode themeMode;
  final Duration pollInterval;

  factory UiPrefs.fromJson(Map<String, Object?> j) {
    final ms = j['poll_interval_ms'];
    final interval = ms is num
        ? Duration(milliseconds: ms.toInt())
        : defaultPollInterval;
    return UiPrefs(
      themeMode: MeshThemeMode.fromName(
        j['theme'] is String ? j['theme'] as String : null,
      ),
      // An out-of-range value in a hand-edited file is not worth honouring:
      // a 10ms poll would hammer the daemon.
      pollInterval: pollIntervalChoices.contains(interval)
          ? interval
          : defaultPollInterval,
    );
  }

  Map<String, Object?> toJson() => {
    'theme': themeMode.name,
    'poll_interval_ms': pollInterval.inMilliseconds,
  };

  UiPrefs copyWith({MeshThemeMode? themeMode, Duration? pollInterval}) =>
      UiPrefs(
        themeMode: themeMode ?? this.themeMode,
        pollInterval: pollInterval ?? this.pollInterval,
      );

  @override
  bool operator ==(Object other) =>
      other is UiPrefs &&
      other.themeMode == themeMode &&
      other.pollInterval == pollInterval;

  @override
  int get hashCode => Object.hash(themeMode, pollInterval);
}

/// Reads and writes `ui.json`.
class PrefsFile {
  PrefsFile({Map<String, String>? environment})
    : environment = environment ?? Platform.environment;

  final Map<String, String> environment;

  /// Null when there is no config directory to sit in, in which case the app
  /// runs on defaults and simply does not remember anything.
  String? get path {
    final dir = configDirectory(environment: environment);
    return dir == null ? null : '$dir${Platform.pathSeparator}ui.json';
  }

  /// Defaults on anything going wrong. Unlike the session file, a broken
  /// `ui.json` costs nothing to ignore: worst case the theme resets.
  Future<UiPrefs> load() async {
    final p = path;
    if (p == null) return const UiPrefs();
    try {
      final file = File(p);
      if (!await file.exists()) return const UiPrefs();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const UiPrefs();
      return UiPrefs.fromJson(
        decoded is Map<String, Object?>
            ? decoded
            : decoded.map((k, v) => MapEntry('$k', v)),
      );
    } on FileSystemException {
      return const UiPrefs();
    } on FormatException {
      return const UiPrefs();
    }
  }

  /// Best effort, atomic. Losing a theme preference is not worth an error
  /// panel, so failures are swallowed and reported as `false`.
  Future<bool> save(UiPrefs prefs) async {
    final p = path;
    if (p == null) return false;
    try {
      final file = File(p);
      await file.parent.create(recursive: true);
      final tmp = File('$p.tmp');
      await tmp.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(prefs.toJson())}\n',
        flush: true,
      );
      await tmp.rename(p);
      return true;
    } on FileSystemException {
      return false;
    }
  }
}

/// The live preferences.
///
/// Exposes the two settings as `ValueNotifier`s because that is what their
/// consumers want: `MeshApp` takes a `ValueListenable<MeshThemeMode>`, and
/// `DaemonStore` watches the interval. Writes are debounced so dragging
/// through a select does not produce a burst of file writes.
class PrefsStore extends ChangeNotifier {
  PrefsStore({PrefsFile? file}) : _file = file ?? PrefsFile();

  final PrefsFile _file;

  final ValueNotifier<MeshThemeMode> themeMode = ValueNotifier(
    MeshThemeMode.system,
  );
  final ValueNotifier<Duration> pollInterval = ValueNotifier(
    defaultPollInterval,
  );

  bool _loaded = false;
  bool get loaded => _loaded;

  /// Where the file is, for the Settings screen to show.
  String? get path => _file.path;

  Future<void> load() async {
    final prefs = await _file.load();
    themeMode.value = prefs.themeMode;
    pollInterval.value = prefs.pollInterval;
    _loaded = true;
    notifyListeners();
  }

  UiPrefs get value =>
      UiPrefs(themeMode: themeMode.value, pollInterval: pollInterval.value);

  void setThemeMode(MeshThemeMode mode) {
    if (themeMode.value == mode) return;
    themeMode.value = mode;
    notifyListeners();
    _persist();
  }

  void setPollInterval(Duration interval) {
    if (pollInterval.value == interval) return;
    pollInterval.value = interval;
    notifyListeners();
    _persist();
  }

  Future<void>? _writing;
  bool _dirty = false;

  void _persist() {
    _dirty = true;
    if (_writing != null) return;
    _writing = _drain();
  }

  Future<void> _drain() async {
    while (_dirty) {
      _dirty = false;
      await _file.save(value);
    }
    _writing = null;
  }

  @override
  void dispose() {
    themeMode.dispose();
    pollInterval.dispose();
    super.dispose();
  }
}
