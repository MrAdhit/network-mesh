/// First run: four stages, one window, no rail.
///
/// The flow is derived, not stored. Where it starts is worked out from what is
/// true about this Mac — nothing installed, an engine that is not running, an
/// engine running but not on a network — so quitting halfway through and coming
/// back resumes exactly where it was without anything having been written down.
/// It only ever moves forward: an engine that dies while somebody is typing an
/// enrollment key does not yank the screen out from under them, and the join
/// will say so in the daemon's own words if they press it.
///
/// The step indicator belongs to the flow rather than to the stages. It is the
/// product's own mark — three bars, one per stage — and a bar ignites where it
/// stands as its stage completes. Handing each stage its own would replace the
/// mark along with the screen under it, and an ignition that happens during a
/// crossfade is not an ignition.
library;

import 'package:flutter/widgets.dart';

import '../../kit/scaffold.dart';
import '../../kit/stage.dart';
import '../../state/app_state.dart';
import '../../state/daemon_store.dart';
import '../../theme/theme.dart';
import 'arrival_stage.dart';
import 'engine_stage.dart';
import 'network_stage.dart';
import 'welcome_stage.dart';

/// The four stages, in the order they happen. The order is the spatial model
/// too: the flow travels down this list and never back up it.
enum SetupStage {
  /// Only for a Mac where nothing at all is set up.
  welcome(0),

  /// Get the engine installed and running.
  engine(0),

  /// Get this Mac onto a network.
  network(1),

  /// Done. The address, and the way out.
  arrival(MeshStepTriad.stages);

  const SetupStage(this.stagesLit);

  /// How many bars of the indicator are lit while this stage is on screen —
  /// that is, how many stages are behind it. Arrival lights the lot: it is the
  /// last stage and its own completion.
  final int stagesLit;
}

class SetupFlow extends StatefulWidget {
  const SetupFlow({required this.onFinished, super.key});

  /// Called by the arrival stage when it is done being looked at. The window
  /// crossfades to the shell; this widget never unmounts itself.
  final VoidCallback onFinished;

  /// Where first run begins on this machine.
  ///
  /// The socket outranks the disk, as everywhere else: something answering is
  /// proof the engine is running, and nothing on disk is proof of anything.
  /// Only call this once boot has settled — `AppState.bootSettled` — or it will
  /// answer for a machine nobody has looked at yet.
  static SetupStage stageFor(AppState app) {
    // A platform with no daemon opens on the stage that says so and stops
    // there. Welcoming somebody into a flow that cannot finish, and then
    // asking them to press a button to be told no, is worse than saying it on
    // the first screen.
    if (!app.manager.platform.runsDaemon) return SetupStage.engine;
    if (app.daemon.reachable) {
      return app.daemon.enrolled ? SetupStage.arrival : SetupStage.network;
    }
    // Nothing running and nothing on disk is a machine where nothing has
    // happened yet, and that is the only case that gets a welcome.
    return app.manager.installed ? SetupStage.engine : SetupStage.welcome;
  }

  @override
  State<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<SetupFlow> {
  DaemonStore? _daemon;
  SetupStage? _stage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    _stage ??= SetupFlow.stageFor(app);
    if (identical(app.daemon, _daemon)) return;
    _daemon?.removeListener(_onDaemon);
    _daemon = app.daemon..addListener(_onDaemon);
  }

  /// The stages complete themselves. The socket answering is what finishes the
  /// engine stage and being enrolled is what finishes the network stage, so
  /// neither one has a "continue" button on it.
  void _onDaemon() {
    if (!mounted) return;
    _go(SetupFlow.stageFor(AppScope.read(context)));
  }

  /// Forward only. A stage behind the one on screen is not a place to go back
  /// to; it is a fact that has stopped being true for a moment.
  void _go(SetupStage stage) {
    if (stage.index <= _stage!.index) return;
    setState(() => _stage = stage);
  }

  @override
  void dispose() {
    _daemon?.removeListener(_onDaemon);
    super.dispose();
  }

  /// What a stage puts in `MeshStage.indicator`: nothing, at the size of
  /// nothing. It reserves the zone the flow's own triad floats in, so no stage
  /// lays its content out over the mark.
  static const Widget _reserved = SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    final stage = _stage!;
    return Stack(
      fit: StackFit.expand,
      children: [
        MeshScreenSwitcher(
          index: stage.index,
          children: [
            WelcomeStage(
              onStart: () => _go(SetupStage.engine),
              indicator: _reserved,
            ),
            const EngineStage(indicator: _reserved),
            const NetworkStage(indicator: _reserved),
            ArrivalStage(onFinished: widget.onFinished, indicator: _reserved),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: FilamentSpace.x8,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [MeshStepTriad(stagesLit: stage.stagesLit)],
          ),
        ),
      ],
    );
  }
}
