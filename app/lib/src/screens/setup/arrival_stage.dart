/// Stage 3 — arrival.
///
/// The address, the lit mark, a breath, and then the dashboard. This is the
/// only screen in the app whose job is to be looked at rather than read: the
/// work is done, and the app says so once before it becomes an instrument.
///
/// It is also where `setupComplete` is written. From this moment an engine that
/// stops is a banner on the dashboard rather than a reason to start first run
/// over.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../kit/button.dart';
import '../../kit/copyable.dart';
import '../../kit/stage.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';

class ArrivalStage extends StatefulWidget {
  const ArrivalStage({
    required this.onFinished,
    required this.indicator,
    super.key,
  });

  /// Called when the breath is over, or when the button is pressed.
  final VoidCallback onFinished;

  /// The flow's step indicator zone. See `SetupFlow`.
  final Widget indicator;

  /// How long the app holds still before handing over.
  static const Duration hold = Duration(milliseconds: 2500);

  /// What that becomes when the platform asks for reduced motion. Somebody who
  /// has turned off animation is not asking to be held on a screen either, but
  /// a swap with no beat at all reads as a glitch.
  static const Duration reducedHold = Duration(seconds: 1);

  @override
  State<ArrivalStage> createState() => _ArrivalStageState();
}

class _ArrivalStageState extends State<ArrivalStage> {
  Timer? _timer;
  bool _entered = false;
  bool _left = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Arrival is the first time the stage is seen, not the first time it is
    // built: the flow builds all four up front.
    if (_entered || !TickerMode.valuesOf(context).enabled) return;
    _entered = true;
    final app = AppScope.read(context);
    // After the frame, never during it: writing the flag notifies every store
    // listener in the app, and the scope above this stage is one of them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) app.markSetupComplete();
    });
    _timer = Timer(
      FilamentMotion.reducedIn(context)
          ? ArrivalStage.reducedHold
          : ArrivalStage.hold,
      _finish,
    );
  }

  void _finish() {
    if (_left) return;
    _left = true;
    _timer?.cancel();
    widget.onFinished();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final daemon = AppScope.daemonOf(context);
    return ListenableBuilder(
      listenable: daemon,
      builder: (context, _) {
        final theme = FilamentTheme.of(context);
        final status = daemon.status;
        final address = status?.virtualIp ?? '';
        final peers = status?.peerCount ?? 0;

        return MeshStage(
          // The mark, fully lit, at the size of a thing you are meant to look
          // at. The indicator at the bottom says the same in miniature.
          mark: const MeshStepTriad(
            stagesLit: MeshStepTriad.stages,
            barWidth: 8,
            height: 40,
            gap: 8,
          ),
          title: "You're on the mesh.",
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (address.isNotEmpty)
                // The one reading on the screen, at headline size. Scaled down
                // rather than wrapped in a narrow window: an address is one
                // thing and breaking it across two lines would make it two.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: MeshCopyable(address, style: theme.type.headline),
                ),
              if (peers > 0) ...[
                const SizedBox(height: FilamentSpace.x5),
                Text(
                  peers == 1
                      ? '1 peer already reachable'
                      : '$peers peers already reachable',
                  style: theme.type.bodyDim,
                ),
              ],
            ],
          ),
          action: MeshButton.ghost(
            label: 'Open the dashboard',
            onPressed: _finish,
          ),
          indicator: widget.indicator,
        );
      },
    );
  }
}
