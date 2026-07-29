/// Stage 1 — the engine.
///
/// The stage is about getting running, never about what is absent: there is no
/// "not installed" anywhere on it. The app does every unprivileged step it can
/// the moment the stage opens, and what is left is one button whose label says
/// what macOS is about to do.
///
/// It never announces its own completion either. The moment the socket answers,
/// `SetupFlow` moves on — the daemon is the authority on whether the engine is
/// running, and a "done, continue" button would only be asking the user to
/// confirm something the app can already see.
///
/// All of that is the macOS stage. The other two are in [_unsupported], and
/// neither one may borrow a word of it: the password, the prompt and the
/// install are macOS's, and a Linux screen that mentions them is describing
/// something that is not going to happen.
library;

import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';

import '../../data/privileged.dart' show HostPlatform;
import '../../kit/button.dart';
import '../../kit/panel.dart';
import '../../kit/progress.dart';
import '../../kit/stage.dart';
import '../../state/app_state.dart';
import '../../state/manager_store.dart';
import '../../theme/theme.dart';
import 'setup_parts.dart';

/// Which button was pressed last, so a failure gets the right headline.
enum _Attempt { none, install, start }

class EngineStage extends StatefulWidget {
  const EngineStage({required this.indicator, super.key});

  /// The flow's step indicator zone. See `SetupFlow`.
  final Widget indicator;

  @override
  State<EngineStage> createState() => _EngineStageState();
}

class _EngineStageState extends State<EngineStage> {
  ManagerStore? _manager;
  bool _entered = false;
  _Attempt _attempt = _Attempt.none;

  /// The last busy phase seen. A failure that arrives after the password prompt
  /// is a failure to start, whatever the button that began it said.
  ManagerState? _phase;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final manager = AppScope.managerOf(context);
    if (!identical(manager, _manager)) {
      _manager?.removeListener(_onManager);
      _manager = manager..addListener(_onManager);
    }
    // Entry is the first time the stage is *seen*, not the first time it is
    // built: the flow builds every stage up front and holds the ones you are
    // not looking at off stage with their tickers muted.
    if (!_entered && TickerMode.valuesOf(context).enabled) _enter();
  }

  void _enter() {
    _entered = true;
    final manager = _manager!;
    if (!manager.supported || manager.busy || manager.installed) return;
    // The download starts here, not under a button: it needs no password and
    // nobody has to agree to it, so it happens while the user is still reading
    // the sentence. What is left for the one button is the part macOS asks
    // about.
    //
    // After the frame, never during it: the store announces that it is
    // downloading the moment it starts, and a store that notifies mid-build
    // marks the scope above this stage as needing to build while it is
    // building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(manager.prepare());
    });
  }

  void _onManager() {
    final manager = _manager;
    if (manager == null) return;
    if (manager.busy) _phase = manager.state;
  }

  @override
  void dispose() {
    _manager?.removeListener(_onManager);
    super.dispose();
  }

  void _run(_Attempt attempt) {
    final manager = _manager!;
    if (manager.busy) return;
    setState(() {
      _attempt = attempt;
      _phase = null;
    });
    unawaited(switch (attempt) {
      _Attempt.install => manager.install(),
      _Attempt.start => manager.start(),
      // Nothing has been pressed yet, so what failed was the download the
      // stage started for itself. Try that again.
      _Attempt.none => manager.prepare(),
    });
  }

  /// What to try again after a failure: whatever failed, or the look-around
  /// that failed before anything was ever pressed.
  void _retry() => _run(_attempt);

  String get _failureHeadline {
    if (_attempt == _Attempt.start) return "Couldn't start the engine";
    return switch (_phase) {
      ManagerState.awaitingAdmin ||
      ManagerState.applying => "Couldn't start the engine",
      _ => "Couldn't download the engine",
    };
  }

  @override
  Widget build(BuildContext context) {
    final manager = _manager ?? AppScope.managerOf(context);
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) => _stage(context, manager),
    );
  }

  Widget _stage(BuildContext context, ManagerStore manager) {
    if (!manager.supported) return _unsupported(context, manager);

    final error = manager.error;
    final busy = manager.busy || manager.checking;
    final installed = manager.installed;

    if (busy) {
      return MeshStage(
        title: manager.state == ManagerState.awaitingAdmin
            ? 'Waiting for macOS…'
            : 'Setting up the mesh engine',
        body: _activity(manager),
        indicator: widget.indicator,
      );
    }

    if (error != null) {
      return MeshStage(
        title: 'Setting up the mesh engine',
        body: SetupFailure(headline: _failureHeadline, detail: error),
        action: MeshButton.primary(
          label: 'Try again',
          autofocus: true,
          onPressed: _retry,
        ),
        indicator: widget.indicator,
      );
    }

    return MeshStage(
      title: 'Setting up the mesh engine',
      message: installed
          ? 'The engine is on this Mac, but nothing is running it.'
          : 'The engine runs quietly in the background and keeps this Mac '
                'reachable from your other machines.',
      action: MeshButton.primary(
        label: installed ? 'Start the engine' : 'Install and start',
        autofocus: true,
        onPressed: () => _run(installed ? _Attempt.start : _Attempt.install),
      ),
      footnote: 'macOS will ask for your administrator password.',
      indicator: widget.indicator,
    );
  }

  /// The phases, named for what is actually happening. "Waiting for macOS" is a
  /// prompt somebody has to answer, not work in progress, and saying so is the
  /// difference between a hung app and an app waiting on a person.
  Widget _activity(ManagerStore manager) => switch (manager.state) {
    ManagerState.downloading => MeshProgress(
      label: 'Getting the mesh engine',
      value: manager.downloadProgress,
      received: manager.downloadedBytes,
      total: manager.downloadTotalBytes,
    ),
    ManagerState.verifying => const MeshProgress.indeterminate(
      label: 'Checking what arrived',
      detail:
          'Making sure it is exactly what your network published. Anything '
          'else is deleted.',
    ),
    ManagerState.awaitingAdmin => const MeshProgress.indeterminate(
      label: 'Waiting for macOS…',
      detail:
          'Nothing has been changed yet, and dismissing the prompt changes '
          'nothing.',
    ),
    ManagerState.applying => const MeshProgress.indeterminate(
      label: 'Starting the engine',
    ),
    _ => const MeshProgress.indeterminate(label: 'Getting ready'),
  };

  /// The platforms this app cannot install anything on.
  ///
  /// Linux has a way in, so it gets the command and the promise that the screen
  /// is watching — `SetupFlow` is listening to the same socket the daemon will
  /// bind, and moves the flow on by itself the moment something answers.
  /// Windows gets one sentence and no button, because there is nothing else
  /// that is true: no build, no transport, and no stage after this one.
  ///
  /// Not a word about launchd, administrator passwords or macOS anywhere on
  /// this path. None of it is happening here.
  Widget _unsupported(BuildContext context, ManagerStore manager) {
    final theme = FilamentTheme.of(context);
    final oneLiner = manager.installOneLiner;

    if (oneLiner == null) {
      return MeshStage(
        title: 'Setting up the mesh engine',
        message: manager.platform == HostPlatform.windows
            ? 'The mesh engine does not run on Windows yet.'
            : 'The mesh engine cannot be installed from this app on this '
                  'system.',
        indicator: widget.indicator,
      );
    }

    return MeshStage(
      title: 'Setting up the mesh engine',
      message: 'On this system the engine is installed from a terminal.',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MeshCommandLine(oneLiner),
          const SizedBox(height: FilamentSpace.x3),
          Text(
            'Run this in a terminal — this screen will notice when the engine '
            'is up.',
            style: theme.type.small,
            textAlign: TextAlign.center,
          ),
        ],
      ),
      indicator: widget.indicator,
    );
  }
}
