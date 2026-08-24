import 'dart:io';

import 'cli_agent.dart';
import 'command_runner.dart';
import 'runners.dart';

/// Finds installed coding CLIs across every environment.
///
/// Probing costs one cheap process per (environment, CLI) pair, so it runs
/// them together rather than in sequence — six sequential `wsl.exe` calls each
/// pay WSL's start-up cost and the wait becomes obvious.
Future<List<CliAgent>> discoverCliAgents({
  List<CommandRunner>? runners,
  List<CliAgentKind> kinds = CliAgentKind.values,
  bool readVersions = true,
  bool? windowsHost,
}) async {
  final environments = runners ?? await discoverEnvironments();
  final onWindows = windowsHost ?? Platform.isWindows;

  final probes = <Future<CliAgent?>>[
    for (final runner in environments)
      for (final kind in kinds)
        _probe(
          runner,
          kind,
          readVersions: readVersions,
          windowsHost: onWindows,
        ),
  ];

  final found = await Future.wait(probes);
  return found.whereType<CliAgent>().toList();
}

Future<CliAgent?> _probe(
  CommandRunner runner,
  CliAgentKind kind, {
  required bool readVersions,
  required bool windowsHost,
}) async {
  try {
    final locate = locateCommand(
      runner.environmentId,
      kind.executable,
      windowsHost: windowsHost,
    );
    final result = await runner.run(
      CommandRequest(
        executable: locate.executable,
        arguments: locate.arguments,
      ),
    );
    if (!result.ok) return null;

    final path = firstNonEmptyLine(result.stdout);
    if (path == null) return null;

    String? version;
    if (readVersions) {
      // Best effort. A CLI that is installed but whose --version fails is
      // still usable, so a missing version must not hide it.
      try {
        final v = await runner.run(
          CommandRequest(
            executable: kind.executable,
            arguments: const ['--version'],
          ),
        );
        if (v.ok) version = parseVersion(v.stdout);
      } on CommandException {
        version = null;
      }
    }

    return CliAgent(
      kind: kind,
      environmentId: runner.environmentId,
      environmentLabel: runner.label,
      path: path,
      version: version,
    );
  } on CommandException {
    // The environment itself is unavailable — a WSL distribution that is
    // registered but not running, say. Not an error worth surfacing here.
    return null;
  }
}

/// The runner for [agent]'s environment.
CommandRunner runnerFor(CliAgent agent) => agent.environmentId == 'native'
    ? LocalCommandRunner(loginShell: !Platform.isWindows)
    : WslCommandRunner(agent.environmentId.substring('wsl:'.length));
