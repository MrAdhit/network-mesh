/// The four things that need root, and the one prompt that buys them.
///
/// The app runs unprivileged and stays that way. Everything that has to touch
/// `/usr/local/bin`, `/Library/LaunchDaemons` or the system launchd domain is
/// packed into a single compound shell command and handed to
/// `osascript -e 'do shell script "…" with administrator privileges'`, which is
/// one authorization prompt per thing the user asked for. Two prompts for one
/// button is how people learn to type their password without reading.
///
/// The installation this manages is the same one `packaging/install.sh` makes:
/// same path, same label, same plist. Neither side gets a private variant,
/// because a machine that was installed by the script and is then updated by
/// the app must end up with exactly what it started with.
///
/// Nothing untrusted is interpolated. The destinations are compile-time
/// constants, the staged sources are paths this app chose, quoted for `sh`
/// anyway, and the control plane URL is validated as a URL before it is allowed
/// anywhere near the plist.
///
/// Because all of that is macOS and nothing else, this is also where the app
/// keeps [HostPlatform]: the one place it asks which desktop it is on, and the
/// list of what each one gets.
library;

import 'dart:io';

/// How a subprocess gets run. A seam, so tests can answer without forking.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

// ---------------------------------------------------------------------------
// which desktop this is
// ---------------------------------------------------------------------------

/// The desktop the app is running on, asked once instead of everywhere.
///
/// Everything above depends on osascript, launchctl, `/usr/local` and
/// `/Library/LaunchDaemons`, none of which exist off macOS, so every screen
/// that could reach one of them has to know where it is. They all ask this
/// rather than `Platform.isX` for two reasons: the answers to "what does this
/// platform get" are then one list instead of a dozen scattered conditions, and
/// [current] is assignable, which is the only way to put a Linux or a Windows
/// in front of the app on a Mac and see what it renders.
enum HostPlatform {
  macOS,
  linux,
  windows,

  /// A unix that is neither. The socket transport works there; nothing this app
  /// can do installs a daemon on it.
  other;

  /// What this process is actually running on.
  ///
  /// Assignable for tests, which set it and put it back. Nothing in the app
  /// ever writes it.
  static HostPlatform current = detect();

  static HostPlatform detect() {
    if (Platform.isMacOS) return HostPlatform.macOS;
    if (Platform.isLinux) return HostPlatform.linux;
    if (Platform.isWindows) return HostPlatform.windows;
    return HostPlatform.other;
  }

  bool get isMacOS => this == HostPlatform.macOS;

  /// The app installs, starts, stops and updates meshd itself here. macOS only,
  /// and everything in this file is why.
  bool get managesDaemon => isMacOS;

  /// meshd runs here at all, whoever put it there — the app talks to a daemon
  /// it did not install on Linux, and cannot on Windows, where there is no
  /// build and no transport dart:io can open.
  bool get runsDaemon => this != HostPlatform.windows;

  /// The daemon listens on a unix socket here. False on Windows, where it is a
  /// named pipe with no dart:io equivalent.
  bool get hasUnixSocket => this != HostPlatform.windows;
}

/// What the app calls the machine it is running on, in its own voice.
///
/// "This Mac" is the sentence DESIGN.md writes, and on a Mac it is the right
/// one — but it is a proper noun, and on a Linux box it is simply false. One
/// getter, so the platform is checked once rather than at every sentence.
String get thisMachine =>
    HostPlatform.current.isMacOS ? 'this Mac' : 'this machine';

/// [thisMachine] where a sentence starts.
String get thisMachineCapitalized =>
    HostPlatform.current.isMacOS ? 'This Mac' : 'This machine';

// ---------------------------------------------------------------------------
// the installation
// ---------------------------------------------------------------------------

/// The canonical macOS installation, spelled once.
///
/// These match `start_launchd()` in `packaging/install.sh` with the default
/// prefix. Changing one without the other splits an installation in two.
abstract final class MeshdInstall {
  static const String prefix = '/usr/local';
  static const String binary = '$prefix/bin/meshd';
  static const String binDir = '$prefix/bin';
  static const String label = 'net.mesh.meshd';
  static const String plistPath = '/Library/LaunchDaemons/$label.plist';
  static const String logPath = '/var/log/meshd.log';

  /// How launchctl names the job: the system domain plus the label.
  static const String service = 'system/$label';
}

/// A control plane URL that is not fit to bake into a root-owned plist.
class InvalidCpUrl implements Exception {
  const InvalidCpUrl(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The URL, trailing slash removed, or an exception saying why not.
///
/// install.sh does `CP_URL="${CP_URL%/}"` and nothing else, so this strips the
/// same one slash and then refuses anything that would change the shape of the
/// XML or the shell command it is about to travel through. A control plane URL
/// containing a quote or an angle bracket is not a typo worth accommodating.
String validatedCpUrl(String url) {
  var v = url.trim();
  if (v.endsWith('/')) v = v.substring(0, v.length - 1);
  if (v.isEmpty) {
    throw const InvalidCpUrl('no control plane URL to install against');
  }
  final parsed = Uri.tryParse(v);
  if (parsed == null || !parsed.isAbsolute || parsed.host.isEmpty) {
    throw InvalidCpUrl('"$v" is not a control plane URL');
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    throw InvalidCpUrl('"$v" is not http or https');
  }
  for (final rune in v.runes) {
    if (rune <= 0x20 || rune == 0x7f) {
      throw InvalidCpUrl('"$v" contains whitespace or a control character');
    }
  }
  if (v.contains(RegExp(r'''[<>&"'\\]'''))) {
    throw InvalidCpUrl('"$v" contains a character no URL needs');
  }
  return v;
}

/// The launchd job, byte for byte what `start_launchd()` writes.
///
/// Only the prefix and the control plane URL differ between the two, and the
/// app only ever uses the default prefix, so the one variable here is the URL.
String meshdPlist(String cpUrl) {
  final url = validatedCpUrl(cpUrl);
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${MeshdInstall.label}</string>
    <key>ProgramArguments</key>
    <array><string>${MeshdInstall.binary}</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${MeshdInstall.logPath}</string>
    <key>StandardErrorPath</key><string>${MeshdInstall.logPath}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MESH_CP_URL</key><string>$url</string>
    </dict>
</dict>
</plist>
''';
}

// ---------------------------------------------------------------------------
// the commands
// ---------------------------------------------------------------------------

/// A first install: binary into place, plist into place, reload the job.
///
/// `bootout` is allowed to fail and is braced so that failing does not excuse
/// the rest of the chain — an install that could not put the binary down must
/// not go on to bootstrap the old one. install.sh boots out first for the same
/// reason: bootstrapping an already-loaded label is an error, not a no-op.
String installCommand({
  required String stagedBinary,
  required String stagedPlist,
}) =>
    'mkdir -p ${MeshdInstall.binDir}'
    ' && install -m 0755 ${_sh(stagedBinary)} ${MeshdInstall.binary}'
    ' && install -m 0644 ${_sh(stagedPlist)} ${MeshdInstall.plistPath}'
    ' && { launchctl bootout ${MeshdInstall.service} 2>/dev/null || true; }'
    ' && launchctl bootstrap system ${MeshdInstall.plistPath}';

/// An update: swap the binary and restart the job that is already loaded.
///
/// `kickstart -k` rather than bootout/bootstrap, because the job's definition
/// has not changed — only the file it execs — and killing the service is a
/// shorter outage than unloading and reloading it.
String updateCommand({required String stagedBinary}) =>
    'install -m 0755 ${_sh(stagedBinary)} ${MeshdInstall.binary}'
    ' && launchctl kickstart -k ${MeshdInstall.service}';

/// Stop: unload the job. KeepAlive means nothing else will do.
String stopCommand() => 'launchctl bootout ${MeshdInstall.service}';

/// Start: load the job from the plist already on disk.
String startCommand() => 'launchctl bootstrap system ${MeshdInstall.plistPath}';

/// Restart a job that is already loaded.
String restartCommand() => 'launchctl kickstart -k ${MeshdInstall.service}';

/// Single-quote for `sh`. The only character that matters inside single quotes
/// is the single quote itself, which is closed, escaped and reopened.
String _sh(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Escape for an AppleScript string literal: backslash first, then the quote.
String appleScriptEscape(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

// ---------------------------------------------------------------------------
// running them
// ---------------------------------------------------------------------------

/// A privileged step that did not happen.
class PrivilegedException implements Exception {
  const PrivilegedException(this.message, {this.cancelled = false});

  /// Whatever the failure said, verbatim. Shown in mono in the panel that
  /// asked for the step.
  final String message;

  /// The user dismissed the authorization prompt. Not a failure — nothing was
  /// attempted and nothing needs reporting as broken.
  final bool cancelled;

  @override
  String toString() => message;
}

/// Runs one compound command as root.
///
/// An interface with one real implementation, so the store's flows can be
/// driven end to end in a test: the real one puts a system authorization
/// dialog on the screen, which nothing headless can answer.
abstract class PrivilegedExecutor {
  /// Runs [command] with administrator privileges, or throws.
  Future<void> run(String command);
}

/// The real one: one `osascript`, one prompt, one command.
class OsascriptExecutor implements PrivilegedExecutor {
  const OsascriptExecutor({this.runProcess = Process.run});

  final ProcessRunner runProcess;

  static const String osascript = '/usr/bin/osascript';

  /// osascript's exit for a dismissed authorization dialog.
  static const int userCancelled = -128;

  /// The `-e` argument for [command], exposed so a test can assert the
  /// escaping without running anything.
  static String script(String command) =>
      'do shell script "${appleScriptEscape(command)}" '
      'with administrator privileges';

  @override
  Future<void> run(String command) async {
    final ProcessResult result;
    try {
      result = await runProcess(osascript, ['-e', script(command)]);
    } on ProcessException catch (e) {
      throw PrivilegedException('$osascript: ${e.message}');
    }
    if (result.exitCode == 0) return;

    final stderr = '${result.stderr}'.trim();
    if (stderr.contains('($userCancelled)') ||
        stderr.contains('User canceled')) {
      throw const PrivilegedException(
        'cancelled at the password prompt',
        cancelled: true,
      );
    }
    throw PrivilegedException(
      stderr.isEmpty ? 'osascript exited ${result.exitCode}' : stderr,
    );
  }
}
