import 'dart:io';

import 'command_runner.dart';
import 'io_process_handle.dart';

/// Runs commands on this machine, as this process's user.
class LocalCommandRunner implements CommandRunner {
  const LocalCommandRunner({this.loginShell = false});

  /// Run through `bash -lc`. Needed on POSIX for the same two reasons WSL
  /// needs it: `command -v` is a shell builtin with no executable to run, and
  /// `~/.local/bin` — where these CLIs install — is put on PATH by
  /// `~/.profile`, which only a login shell reads.
  final bool loginShell;

  bool get _wrap => loginShell && !Platform.isWindows;

  CommandRequest _prepare(CommandRequest request) {
    if (!_wrap) return request;
    final quoted = [
      request.executable,
      ...request.arguments,
    ].map(singleQuote).join(' ');
    return CommandRequest(
      executable: 'bash',
      arguments: ['-lc', quoted],
      workingDirectory: request.workingDirectory,
      environment: request.environment,
    );
  }

  @override
  String get environmentId => 'native';

  @override
  String get label => Platform.operatingSystem;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final call = _prepare(request);
    try {
      final result = await Process.run(
        call.executable,
        call.arguments,
        workingDirectory: call.workingDirectory,
        environment: call.environment.isEmpty ? null : call.environment,
      );
      return CommandResult(
        exitCode: result.exitCode,
        stdout: '${result.stdout}',
        stderr: '${result.stderr}',
      );
    } on ProcessException catch (e) {
      throw CommandException('Could not run "$request"', cause: e);
    }
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    try {
      final call = _prepare(request);
      return IoProcessHandle(
        await Process.start(
          call.executable,
          call.arguments,
          workingDirectory: call.workingDirectory,
          environment: call.environment.isEmpty ? null : call.environment,
        ),
      );
    } on ProcessException catch (e) {
      throw CommandException('Could not start "$request"', cause: e);
    }
  }
}

/// Wraps [value] for a POSIX shell.
///
/// Prompts are user text and routinely contain quotes, newlines and Devanagari;
/// handing them to a shell unquoted is both a correctness and a safety problem.
String singleQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The `wsl.exe` command line that runs [request] inside [distribution].
///
/// Pure, so it can be checked without a WSL install. The `--` matters as soon
/// as the command has flags of its own: without it, `wsl -d Ubuntu claude -p x`
/// hands `-p` to wsl rather than to claude.
({String executable, List<String> arguments}) buildWslInvocation(
  String distribution,
  CommandRequest request, {
  bool loginShell = false,
}) {
  final args = <String>['-d', distribution];
  if (request.workingDirectory case final cwd?) {
    args
      ..add('--cd')
      ..add(cwd);
  }
  args.add('--');

  if (loginShell) {
    // A login shell so the distro's PATH additions are present. Agent CLIs are
    // commonly installed in ~/.local/bin, which is put on PATH by ~/.profile;
    // a non-login shell never sources it, and the CLI looks absent.
    final quoted = [
      request.executable,
      ...request.arguments,
    ].map(singleQuote).join(' ');
    args
      ..add('bash')
      ..add('-lc')
      ..add(quoted);
  } else {
    args
      ..add(request.executable)
      ..addAll(request.arguments);
  }
  return (executable: 'wsl.exe', arguments: args);
}

/// Runs commands inside a WSL distribution, from the Windows host.
class WslCommandRunner implements CommandRunner {
  const WslCommandRunner(this.distribution, {this.loginShell = true});

  final String distribution;

  /// Run through `bash -lc`. On by default: without it, anything installed in
  /// `~/.local/bin` is invisible.
  final bool loginShell;

  @override
  String get environmentId => 'wsl:$distribution';

  @override
  String get label => 'WSL - $distribution';

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final call = buildWslInvocation(
      distribution,
      request,
      loginShell: loginShell,
    );
    try {
      final result = await Process.run(call.executable, call.arguments);
      return CommandResult(
        exitCode: result.exitCode,
        stdout: '${result.stdout}',
        stderr: '${result.stderr}',
      );
    } on ProcessException catch (e) {
      throw CommandException(
        'Could not run "$request" in WSL "$distribution"',
        cause: e,
      );
    }
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    final call = buildWslInvocation(
      distribution,
      request,
      loginShell: loginShell,
    );
    try {
      return IoProcessHandle(
        await Process.start(call.executable, call.arguments),
      );
    } on ProcessException catch (e) {
      throw CommandException(
        'Could not start "$request" in WSL "$distribution"',
        cause: e,
      );
    }
  }
}

/// Every environment commands can be run in: this machine, plus each installed
/// WSL distribution when running on Windows.
///
/// WSL is where these CLIs usually live on a Windows box, so an app that looked
/// only at its own PATH would report nothing installed while the user has been
/// using `claude` all week.
Future<List<CommandRunner>> discoverEnvironments() async {
  // A login shell on POSIX, for the PATH the CLIs actually install into.
  final runners = <CommandRunner>[
    LocalCommandRunner(loginShell: !Platform.isWindows),
  ];
  if (!Platform.isWindows) return runners;

  try {
    final result = await Process.run('wsl.exe', ['--list', '--quiet']);
    if (result.exitCode != 0) return runners;
    for (final name in parseDistributions('${result.stdout}')) {
      runners.add(WslCommandRunner(name));
    }
  } on ProcessException {
    // No WSL on this machine.
  }
  return runners;
}

/// Reads `wsl --list --quiet` output.
///
/// That output is UTF-16, so decoding it as UTF-8 leaves a zero byte between
/// every character. Stripping them beats rejecting the line — otherwise every
/// distribution name comes back empty and WSL looks uninstalled.
List<String> parseDistributions(String raw) {
  final names = <String>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final cleaned = line.replaceAll(RegExp(r'[^\x21-\x7E]'), '').trim();
    if (cleaned.isNotEmpty) names.add(cleaned);
  }
  return names;
}
