/// Stage 0 — the welcome.
///
/// Shown only on a machine where nothing at all is set up. The mark, the name,
/// one sentence about what the mesh does, and one button. No links, no fine
/// print, nothing about what is missing: the screen is an invitation, not an
/// inventory.
library;

import 'package:flutter/widgets.dart';

import '../../data/privileged.dart' show thisMachine;
import '../../kit/button.dart';
import '../../kit/stage.dart';
import 'setup_parts.dart';

class WelcomeStage extends StatelessWidget {
  const WelcomeStage({
    required this.onStart,
    required this.indicator,
    super.key,
  });

  final VoidCallback onStart;

  /// The flow's own step indicator zone. See `SetupFlow`.
  final Widget indicator;

  @override
  Widget build(BuildContext context) {
    return MeshStage(
      mark: const SetupMark(height: 56),
      title: 'Mesh',
      message:
          'One address for every machine, three paths between them — traffic '
          'rides whichever is fastest right now.',
      action: MeshButton.primary(
        label: 'Set up $thisMachine',
        autofocus: true,
        onPressed: onStart,
      ),
      indicator: indicator,
    );
  }
}
