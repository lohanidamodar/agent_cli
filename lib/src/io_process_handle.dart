import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_runner.dart';

/// [ProcessHandle] over a real `dart:io` [Process].
class IoProcessHandle implements ProcessHandle {
  IoProcessHandle(this._process)
    : stdoutLines = _process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream(),
      stderrLines = _process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();

  final Process _process;

  @override
  final Stream<String> stdoutLines;

  @override
  final Stream<String> stderrLines;

  @override
  void writeLine(String line) => _process.stdin.writeln(line);

  @override
  Future<void> closeStdin() async {
    try {
      await _process.stdin.close();
    } catch (_) {
      // Already closed, or the process is gone. Either way there is nothing
      // left to close.
    }
  }

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> kill() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
