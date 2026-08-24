/// Discovers and drives already-installed AI coding CLIs.
///
/// One `CommandRunner` abstraction with a native and a WSL implementation, so
/// the same code finds and runs a CLI on Linux, on Windows, and from a Windows
/// process reaching into a WSL distribution. Lookups go through a login shell,
/// which is what makes CLIs installed in `~/.local/bin` visible at all.
library;

export 'src/cli_agent.dart';
export 'src/cli_discovery.dart';
export 'src/cli_session.dart';
export 'src/command_runner.dart';
export 'src/io_process_handle.dart';
export 'src/runners.dart';
