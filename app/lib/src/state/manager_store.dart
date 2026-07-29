/// The app as the daemon's manager, not just its window.
///
/// Everything the machine can tell us about meshd without being root — is the
/// binary there, what does it hash to, is the launchd job loaded — plus the
/// four actions that need root once each. The socket remains the truth about
/// whether it is running: a loaded job that is crash-looping is not running,
/// and only [DaemonStore] knows the difference.
///
/// The store stays usable after every failure. An install that could not reach
/// the control plane leaves a store that still knows what is on disk and an
/// error sentence in the control plane's own words.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/cli_config.dart';
import '../data/privileged.dart';
import '../data/update_client.dart';
import '../util/sha256.dart';

/// What the manager is, right now. Exactly one of these at a time.
enum ManagerState {
  /// Not macOS. See [ManagerStore.unsupportedMessage].
  unsupported,

  /// No binary at the canonical path and no daemon answering.
  notInstalled,

  /// The binary is there; nothing is answering the socket.
  installedStopped,

  /// The socket answers, which is the only thing that settles it.
  running,

  /// Installed, and the control plane holds a different build.
  updateAvailable,

  // -- busy ----------------------------------------------------------------
  downloading,
  verifying,

  /// The authorization dialog is up. Nothing has happened yet.
  awaitingAdmin,

  /// The privileged step is running, or its result is being read back.
  applying,
}

/// Which name the daemon goes by in the manifest.
const String meshdBinaryName = 'meshd';

/// How long a staleness check lasts. The same six hours meshctl's
/// `notice_if_stale` uses, and for the same reason: the control plane is not
/// interesting enough to ask more often than that on its own.
const Duration updateCheckInterval = Duration(hours: 6);

class ManagerStore extends ChangeNotifier {
  ManagerStore({
    Map<String, String>? environment,
    PrivilegedExecutor? privileged,
    UpdateClient Function(String baseUrl)? updateClientFor,
    Future<String?> Function()? detectTargetOverride,
    Directory? downloadsDirectory,
    File? installedBinary,
    File? plistFile,
    Directory? stagingDirectory,
    File? checkMarker,
    ProcessRunner? runProcess,
    bool? macOs,
    DateTime Function()? clock,
  }) : _environment = environment ?? Platform.environment,
       _privileged = privileged ?? const OsascriptExecutor(),
       _updateClientFor =
           updateClientFor ?? ((base) => UpdateClient(baseUrl: base)),
       _detectTarget = detectTargetOverride ?? detectTarget,
       _binary = installedBinary ?? File(MeshdInstall.binary),
       _plist = plistFile ?? File(MeshdInstall.plistPath),
       _staging = stagingDirectory ?? Directory.systemTemp,
       _runProcess = runProcess ?? Process.run,
       _macOs = macOs ?? Platform.isMacOS,
       _now = clock ?? DateTime.now {
    _downloads =
        downloadsDirectory ?? Directory(_defaultDownloadsPath(_environment));
    _marker =
        checkMarker ??
        File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'mesh-app-update-check',
        );
    _cpUrl = resolveCpUrl(environment: _environment);
  }

  final Map<String, String> _environment;
  final PrivilegedExecutor _privileged;
  final UpdateClient Function(String) _updateClientFor;
  final Future<String?> Function() _detectTarget;
  final File _binary;
  final File _plist;
  final Directory _staging;
  final ProcessRunner _runProcess;
  final bool _macOs;
  final DateTime Function() _now;

  late final Directory _downloads;

  /// The marker whose mtime is the last check. In the temp directory for the
  /// reason meshctl puts its there: it is worthless if lost, and the state
  /// directory belongs to root.
  late final File _marker;

  /// Poked after every privileged step so the daemon poll does not have to be
  /// waited out. [AppState] wires this to `DaemonStore.refreshNow`.
  Future<void> Function()? onApplied;

  // -- inputs -------------------------------------------------------------

  late ResolvedCpUrl _cpUrl;
  bool? _daemonReachable;

  /// The effective control plane, resolved the way everything else resolves
  /// it: runtime environment, then the stored session, then what was compiled
  /// in, then the local default. This is what gets baked into the plist.
  ResolvedCpUrl get cpUrl => _cpUrl;

  /// Pushed in by [AppState] when the session changes, because the stored
  /// login is one of the four places the URL can come from.
  set cpUrl(ResolvedCpUrl value) {
    if (_cpUrl.url == value.url && _cpUrl.source == value.source) return;
    _cpUrl = value;
    // A different control plane is a different set of binaries; what we knew
    // about the last one says nothing about this one.
    _offered = null;
    _updateAvailable = false;
    _lastChecked = null;
    notifyListeners();
  }

  /// The socket's answer, which outranks anything on disk. Null until the
  /// daemon store's first poll lands.
  bool? get daemonReachable => _daemonReachable;

  set daemonReachable(bool? value) {
    if (_daemonReachable == value) return;
    _daemonReachable = value;
    notifyListeners();
  }

  // -- what the screens read ----------------------------------------------

  String? _target;
  bool _installed = false;
  String? _installedSha256;
  int? _installedSize;
  bool _plistPresent = false;
  bool _serviceLoaded = false;
  BinaryInfo? _offered;
  bool _updateAvailable = false;
  DateTime? _lastChecked;
  String? _error;
  bool _checking = false;
  ManagerState? _busy;
  int _downloadedBytes = 0;
  int? _downloadTotalBytes;
  bool _inspected = false;

  /// The one thing that is true right now.
  ManagerState get state {
    if (!_macOs) return ManagerState.unsupported;
    final busy = _busy;
    if (busy != null) return busy;
    if (_daemonReachable == true) {
      return _updateAvailable
          ? ManagerState.updateAvailable
          : ManagerState.running;
    }
    if (!_installed) return ManagerState.notInstalled;
    return _updateAvailable
        ? ManagerState.updateAvailable
        : ManagerState.installedStopped;
  }

  /// This Mac's target triple, null before the first [refresh] or on a machine
  /// with no build.
  String? get target => _target;

  /// Whether there is a binary at the canonical path.
  bool get installed => _installed;

  /// The installed binary's hash and size, both readable without root. Null
  /// while nothing is installed, or when it could not be read.
  String? get installedSha256 => _installedSha256;
  int? get installedSize => _installedSize;

  /// The first twelve of [installedSha256], which is what install.sh prints.
  String? get installedShortSha => _installedSha256?.substring(0, 12);

  /// Whether the plist is on disk, and whether launchd has the job loaded.
  /// Both are facts Settings shows; neither settles whether it is running.
  bool get plistPresent => _plistPresent;
  bool get serviceLoaded => _serviceLoaded;

  /// The socket answered on the last poll.
  bool get daemonRunning => _daemonReachable == true;

  /// The control plane holds a build that is not the one installed.
  bool get updateAvailable => _updateAvailable;

  /// What the control plane is offering, once a check has run.
  BinaryInfo? get offered => _offered;

  /// When the last successful check happened, null when there has not been one.
  DateTime? get lastChecked => _lastChecked;

  /// True while a check is in flight. Separate from [busy] because a check is
  /// not an action the user is waiting on and must not block the buttons.
  bool get checking => _checking;

  /// The last failure, verbatim. Null after a step that worked, and null when
  /// the user simply dismissed the password prompt.
  String? get error => _error;

  /// One of the busy states is in play; the actions are unavailable.
  bool get busy => _busy != null;

  /// Bytes down, and the total when the control plane declared one.
  int get downloadedBytes => _downloadedBytes;
  int? get downloadTotalBytes => _downloadTotalBytes;

  /// How often a download that is moving is allowed to ask for a repaint.
  ///
  /// Progress lands once per chunk, which is thousands of calls across a
  /// binary. Notifying on each one asks for far more frames than a display can
  /// show and far more than an eye can read a number off; every 30ms is
  /// already smoother than the digits it is moving.
  static const Duration _paintCadence = Duration(milliseconds: 30);

  /// Real elapsed time between repaints, deliberately not [_now]: a test may
  /// hold the clock still and the readout still has to move.
  final Stopwatch _sincePaint = Stopwatch();

  /// True on the first chunk of a download, and at most once per
  /// [_paintCadence] after that. The first one matters: a readout that waits
  /// out a cadence before its first number is the frozen "0 B" all over again.
  bool _paintDue() {
    if (!_sincePaint.isRunning) {
      _sincePaint.start();
      return true;
    }
    if (_sincePaint.elapsed < _paintCadence) return false;
    _sincePaint.reset();
    return true;
  }

  /// 0..1, or null when there is no total to divide by.
  double? get downloadProgress {
    final total = _downloadTotalBytes;
    if (total == null || total <= 0) return null;
    final v = _downloadedBytes / total;
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  /// False until the first [refresh] finishes, so a screen can hold off on
  /// saying "not installed" before anything has looked.
  bool get inspected => _inspected;

  // -- the platforms we are not -------------------------------------------

  bool get supported => _macOs;

  /// What to say on a platform this cannot manage.
  String? get unsupportedMessage {
    if (_macOs) return null;
    if (Platform.isLinux) {
      return 'This app manages meshd on macOS. On Linux, install it with the '
          'one-liner and the app will talk to it.';
    }
    if (Platform.isWindows) {
      return 'meshd does not run on Windows yet.';
    }
    return 'This app manages meshd on macOS.';
  }

  /// The install.sh one-liner for the effective control plane, for Linux to
  /// show and copy. Null anywhere it would not work.
  String? get installOneLiner =>
      Platform.isLinux ? 'curl -fsSL ${_cpUrl.url}/install.sh | sh' : null;

  // -- looking --------------------------------------------------------------

  /// Read everything the machine will tell an unprivileged process.
  ///
  /// Cheap enough to call after every action. The binary is only re-hashed
  /// when its size or mtime moved, because hashing tens of megabytes on a
  /// poll tick would be heat for nothing.
  Future<void> refresh() async {
    if (!_macOs) {
      _inspected = true;
      notifyListeners();
      return;
    }
    _target ??= await _detectTarget();
    await _readInstalled();
    _plistPresent = await _plist.exists();
    _serviceLoaded = await _isServiceLoaded();
    _recomputeUpdateAvailable();
    _inspected = true;
    notifyListeners();
  }

  DateTime? _hashedAt;
  int? _hashedSize;

  Future<void> _readInstalled() async {
    final stat = await _binary.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      _installed = false;
      _installedSha256 = null;
      _installedSize = null;
      _hashedAt = null;
      _hashedSize = null;
      return;
    }
    _installed = true;
    _installedSize = stat.size;
    if (_installedSha256 != null &&
        _hashedSize == stat.size &&
        _hashedAt == stat.modified) {
      return;
    }
    try {
      _installedSha256 = await sha256OfFile(_binary);
      _hashedSize = stat.size;
      _hashedAt = stat.modified;
    } on FileSystemException catch (e) {
      // Unreadable rather than absent: say so instead of claiming a hash.
      _installedSha256 = null;
      _hashedAt = null;
      _hashedSize = null;
      _error = 'reading ${_binary.path}: ${e.osError?.message ?? e.message}';
    }
  }

  /// `launchctl print` on the system domain answers for any user: it reports
  /// whether the label is loaded without being able to change anything.
  Future<bool> _isServiceLoaded() async {
    try {
      final result = await _runProcess('/bin/launchctl', [
        'print',
        MeshdInstall.service,
      ]);
      return result.exitCode == 0;
    } on Exception {
      return false;
    }
  }

  // -- checking -------------------------------------------------------------

  /// Ask the control plane whether what is installed is what it holds.
  ///
  /// Skipped when the last check was under [updateCheckInterval] ago, unless
  /// [force], which is what the Check for updates button passes. A failure is
  /// recorded and dropped: being unable to reach a control plane is not a
  /// reason to make the rest of the screen unusable.
  Future<void> checkForUpdates({bool force = false}) async {
    if (!_macOs || _checking) return;
    if (!force && !(await _stale())) return;

    final target = _target ??= await _detectTarget();
    if (target == null) return;

    _checking = true;
    if (force) _error = null;
    notifyListeners();
    try {
      final client = _updateClientFor(_cpUrl.url);
      try {
        final manifest = await client.manifest(target);
        _offered = manifest.get(meshdBinaryName);
        _lastChecked = _now();
        await _touchMarker();
        _recomputeUpdateAvailable();
      } finally {
        client.close();
      }
    } on UpdateException catch (e) {
      // Only worth a sentence when the user asked; a background check that
      // finds the machine offline has nothing to report.
      if (force) _error = e.message;
    } catch (e) {
      if (force) _error = '$e';
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  void _recomputeUpdateAvailable() {
    final offered = _offered;
    final have = _installedSha256;
    _updateAvailable =
        offered != null &&
        offered.sha256.isNotEmpty &&
        have != null &&
        offered.sha256 != have;
  }

  Future<bool> _stale() async {
    final last = _lastChecked;
    if (last != null) {
      return _now().difference(last) >= updateCheckInterval;
    }
    try {
      if (!await _marker.exists()) return true;
      final at = await _marker.lastModified();
      if (_now().difference(at) < updateCheckInterval) {
        _lastChecked = at;
        return false;
      }
    } on FileSystemException {
      // No marker we can read is the same as no marker.
    }
    return true;
  }

  Future<void> _touchMarker() async {
    try {
      await _marker.writeAsBytes(const [], flush: true);
    } on FileSystemException {
      // A check that cannot leave a note still checked; the in-memory
      // timestamp covers this run.
    }
  }

  // -- the actions ----------------------------------------------------------

  /// Fetch, verify, install, and load the job. One password prompt.
  Future<bool> install() => _fetchThenApply(
    build: (staged) async {
      final plist = await _stagePlist();
      return installCommand(stagedBinary: staged.path, stagedPlist: plist.path);
    },
  );

  /// Fetch, verify, swap the binary, kick the job. One password prompt.
  Future<bool> update() => _fetchThenApply(
    build: (staged) async => updateCommand(stagedBinary: staged.path),
  );

  /// Load the job, or restart it when launchd already has it.
  Future<bool> start() =>
      _privilegedStep(_serviceLoaded ? restartCommand() : startCommand());

  /// Unload the job. KeepAlive means nothing less will stop it.
  Future<bool> stop() => _privilegedStep(stopCommand());

  /// Kick it when loaded, load it when not.
  Future<bool> restart() =>
      _privilegedStep(_serviceLoaded ? restartCommand() : startCommand());

  Future<bool> _fetchThenApply({
    required Future<String> Function(File staged) build,
  }) async {
    if (busy || !_macOs) return false;

    _error = null;
    _downloadedBytes = 0;
    _downloadTotalBytes = null;
    _lastStagedPlist = null;
    _sincePaint
      ..stop()
      ..reset();
    _enter(ManagerState.downloading);

    File? staged;
    File? stagedPlist;
    try {
      final target = _target ??= await _detectTarget();
      if (target == null) {
        _error = 'no meshd build for this Mac';
        return false;
      }

      final client = _updateClientFor(_cpUrl.url);
      final VerifiedBinary verified;
      try {
        final manifest = await client.manifest(target);
        final want = manifest.get(meshdBinaryName);
        if (want == null) {
          _error = '${_cpUrl.url} has no $meshdBinaryName build for $target';
          return false;
        }
        _offered = want;
        _downloadTotalBytes = want.size > 0 ? want.size : null;
        notifyListeners();

        staged = File(
          '${_downloads.path}${Platform.pathSeparator}$meshdBinaryName',
        );
        verified = await client.download(
          target: target,
          want: want,
          into: staged,
          onProgress: (received, total) {
            _downloadedBytes = received;
            _downloadTotalBytes = total ?? _downloadTotalBytes;
            // The hash is finalised and compared the moment the last byte
            // lands, which is exactly what verifying names.
            final complete = total != null && received >= total;
            if (complete) _busy = ManagerState.verifying;
            // The count is kept for every chunk; only the repaint is rationed.
            // The last one is never rationed — a progress bar that stops at
            // 97% because the cadence swallowed the final chunk is a lie.
            if (complete || _paintDue()) notifyListeners();
          },
        );
      } finally {
        client.close();
      }

      _enter(ManagerState.verifying);
      final command = await build(verified.file);
      stagedPlist = _lastStagedPlist;

      _enter(ManagerState.awaitingAdmin);
      await _privileged.run(command);

      _enter(ManagerState.applying);
      _lastChecked = _now();
      await _touchMarker();
      return true;
    } on PrivilegedException catch (e) {
      // A dismissed prompt is a decision, not a fault.
      if (!e.cancelled) _error = e.message;
      return false;
    } on UpdateException catch (e) {
      _error = e.message;
      return false;
    } on InvalidCpUrl catch (e) {
      _error = e.message;
      return false;
    } on FileSystemException catch (e) {
      _error = '${e.path ?? ''}: ${e.osError?.message ?? e.message}'.trim();
      return false;
    } catch (e) {
      _error = '$e';
      return false;
    } finally {
      // The staged copies are re-fetchable and one of them is an executable;
      // neither is worth leaving in a user-writable directory.
      await _discard(staged);
      await _discard(stagedPlist);
      _busy = null;
      _downloadedBytes = 0;
      _downloadTotalBytes = null;
      await refresh();
      await onApplied?.call();
      notifyListeners();
    }
  }

  Future<bool> _privilegedStep(String command) async {
    if (busy || !_macOs) return false;
    _error = null;
    _enter(ManagerState.awaitingAdmin);
    try {
      await _privileged.run(command);
      _enter(ManagerState.applying);
      return true;
    } on PrivilegedException catch (e) {
      if (!e.cancelled) _error = e.message;
      return false;
    } finally {
      _busy = null;
      await refresh();
      await onApplied?.call();
      notifyListeners();
    }
  }

  File? _lastStagedPlist;

  /// The plist as a file the privileged step can copy.
  ///
  /// Written here and copied there rather than echoed through the shell: the
  /// XML would have to survive an AppleScript literal and then `sh`, and a
  /// heredoc inside a `do shell script` is one quoting mistake away from
  /// writing a root-owned file with attacker-chosen contents.
  Future<File> _stagePlist() async {
    final dir = Directory(
      '${_staging.path}${Platform.pathSeparator}'
      'mesh-app-$pid',
    );
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}${MeshdInstall.label}.plist',
    );
    await file.writeAsString(meshdPlist(_cpUrl.url), flush: true);
    _lastStagedPlist = file;
    return file;
  }

  void _enter(ManagerState phase) {
    _busy = phase;
    notifyListeners();
  }

  Future<void> _discard(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing useful to do about a file we cannot remove.
    }
  }

  bool _disposed = false;

  /// A store whose flows are all asynchronous will always have a step that
  /// lands after the window closed. Swallowing it here is cheaper than a
  /// disposal check at every await.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// `~/Library/Application Support/mesh/downloads`, beside the shared config.
String _defaultDownloadsPath(Map<String, String> environment) {
  final dir = configDirectory(environment: environment);
  final base = dir ?? Directory.systemTemp.path;
  return '$base${Platform.pathSeparator}downloads';
}
