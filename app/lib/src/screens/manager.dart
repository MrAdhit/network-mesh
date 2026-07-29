/// The manager's furniture: what the app is doing right now and what went
/// wrong last ([ManagerActivity]), what the binary on disk is ([ManagerBuild],
/// [ManagerServiceLine]), and what a platform this app cannot manage gets told
/// instead ([ManagerUnsupportedNote]). Settings drives all three; the banner
/// over the shell drives the actions behind them.
///
/// Nothing here polls or acts. These are readings of [ManagerStore]; the
/// screens own the buttons.
library;

import 'package:flutter/widgets.dart';

import '../data/privileged.dart' show MeshdInstall;
import '../kit/copyable.dart';
import '../kit/panel.dart';
import '../kit/progress.dart';
import '../kit/status_dot.dart';
import '../state/manager_store.dart';
import '../theme/theme.dart';
import '../util/format.dart';

/// The busy line, and the last failure under it.
///
/// Renders nothing at all when the manager is idle and nothing has failed, and
/// carries its own top gap so a panel can drop it at the end of a column
/// without a conditional spacer above it.
///
/// The phases are named for what is actually happening. "Waiting for
/// authorization" is a prompt the user has to answer, not work in progress, and
/// saying so is the difference between a hung app and an app waiting on a
/// person.
class ManagerActivity extends StatelessWidget {
  const ManagerActivity({required this.manager, super.key});

  final ManagerStore manager;

  @override
  Widget build(BuildContext context) {
    final progress = _progress(manager);
    final error = manager.error;
    if (progress == null && error == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: FilamentSpace.x5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?progress,
          if (error != null) ...[
            if (progress != null) const SizedBox(height: FilamentSpace.x4),
            // The control plane's or the shell's own words, never rewritten.
            MeshErrorNote(error),
          ],
        ],
      ),
    );
  }

  static Widget? _progress(ManagerStore manager) => switch (manager.state) {
    ManagerState.downloading => MeshProgress(
      label: 'Downloading meshd',
      value: manager.downloadProgress,
      received: manager.downloadedBytes,
      total: manager.downloadTotalBytes,
    ),
    ManagerState.verifying => const MeshProgress.indeterminate(
      label: 'Verifying sha256',
      detail:
          'Checking the download against the hash the control plane '
          'published. A mismatch deletes it.',
    ),
    ManagerState.awaitingAdmin => const MeshProgress.indeterminate(
      label: 'Waiting for authorization',
      detail:
          'macOS is asking for an administrator password. Nothing has been '
          'changed yet, and dismissing the prompt changes nothing.',
    ),
    ManagerState.applying => const MeshProgress.indeterminate(
      label: 'Applying',
      detail: 'The privileged step is running.',
    ),
    _ => null,
  };
}

/// The installed binary's identity: the twelve hex characters install.sh
/// prints, and how big the file is.
///
/// The hash is the identity — that is the whole premise of the update protocol
/// — so it is the copyable, and it copies in full even though twelve characters
/// are all anyone can compare by eye.
class ManagerBuild extends StatelessWidget {
  const ManagerBuild({required this.sha256, required this.size, super.key});

  final String? sha256;
  final int? size;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final sha = sha256;
    return Row(
      children: [
        if (sha == null)
          Text('Could not be read', style: theme.type.small)
        else
          Flexible(
            child: MeshCopyable(
              sha,
              display: sha.length <= 12 ? sha : sha.substring(0, 12),
              style: theme.type.monoEmphasis,
            ),
          ),
        if (size != null) ...[
          const SizedBox(width: FilamentSpace.x3),
          MeshMeasure(bytesParts(size), style: theme.type.mono),
        ],
      ],
    );
  }
}

/// Whether launchd has the job, which is a different question from whether
/// anything is answering the socket.
///
/// A loaded job that is crash-looping is loaded and not running, so this line
/// never wears the signal colour: it is a fact about launchd's table, not a
/// claim about the daemon's health.
class ManagerServiceLine extends StatelessWidget {
  const ManagerServiceLine({
    required this.loaded,
    required this.plistPresent,
    super.key,
  });

  final bool loaded;
  final bool plistPresent;

  @override
  Widget build(BuildContext context) {
    return MeshStatusLine(
      tone: MeshTone.neutral,
      hollow: !loaded,
      label: loaded ? 'Loaded' : 'Not loaded',
      detail: plistPresent ? MeshdInstall.label : 'no plist',
    );
  }
}

/// What a platform this app cannot manage is told, plus the way in on the one
/// where there is one.
///
/// Linux gets the install.sh one-liner against the effective control plane, in
/// a box, copyable — the same command the README hands out. Windows gets the
/// sentence and nothing else, because there is nothing else that is true.
class ManagerUnsupportedNote extends StatelessWidget {
  const ManagerUnsupportedNote({required this.manager, super.key});

  final ManagerStore manager;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final message = manager.unsupportedMessage;
    final oneLiner = manager.installOneLiner;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message != null) Text(message, style: theme.type.bodyDim),
        if (oneLiner != null) ...[
          const SizedBox(height: FilamentSpace.x4),
          MeshCommandLine(oneLiner),
          const SizedBox(height: FilamentSpace.x2),
          Text(
            'It installs the same binary this app would, and the app talks to '
            'it over the socket once it is up.',
            style: theme.type.small,
          ),
        ],
      ],
    );
  }
}
