/// A command to run, described independently of where it runs.
class CommandRequest {
  const CommandRequest({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
  });

  final String executable;
  final List<String> arguments;

  /// A path in the *runner's* environment, not the caller's. A WSL runner
  /// wants `/home/you/project`, a Windows runner `C:\Users\you\project`.
  final String? workingDirectory;

  final Map<String, String> environment;

  @override
  String toString() => [executable, ...arguments].join(' ');
}

/// The output of a command that ran to completion.
class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// The command could not be run at all.
///
/// A non-zero exit code is **not** this: a process that ran and failed
/// reports through [CommandResult.exitCode]. This means nothing started.
class CommandException implements Exception {
  const CommandException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'CommandException: $message${cause == null ? '' : ' ($cause)'}';
}

/// A handle on a process that is still running.
abstract interface class ProcessHandle {
  /// stdout, split into lines with the terminator removed.
  Stream<String> get stdoutLines;

  /// stderr, split the same way.
  Stream<String> get stderrLines;

  void writeLine(String line);

  /// Closes stdin. A CLI that reads stdin when it is not a terminal will wait
  /// forever otherwise — `codex exec` prints "Reading additional input from
  /// stdin…" and hangs.
  Future<void> closeStdin();

  Future<int> get exitCode;
  Future<void> kill();
}

/// The single place process execution happens.
///
/// Callers depend on this rather than `dart:io` directly, which is what lets
/// the same code run a CLI natively, inside a WSL distribution, or against a
/// fake in tests.
abstract interface class CommandRunner {
  /// Identifies the environment this runner targets — `native`, `wsl:Ubuntu`.
  String get environmentId;

  /// Human-readable name for that environment.
  String get label;

  Future<CommandResult> run(CommandRequest request);

  Future<ProcessHandle> start(CommandRequest request);
}
