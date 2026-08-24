import 'dart:convert';

/// A coding CLI that can also answer a plain question.
///
/// The appeal is authentication: someone already using `claude` or `codex` has
/// logged in, and driving the CLI reuses that. No API key to paste, no second
/// subscription. The cost is latency and tokens — each invocation is a fresh
/// session that reloads the tool list, hooks and project instructions before
/// it answers.
enum CliAgentKind {
  claudeCode('claude', 'Claude Code'),
  codex('codex', 'Codex CLI'),
  geminiCli('gemini', 'Gemini CLI');

  const CliAgentKind(this.executable, this.label);

  /// Base name to look for on PATH.
  final String executable;
  final String label;

  static CliAgentKind? byId(String id) {
    for (final k in values) {
      if (k.name == id) return k;
    }
    return null;
  }
}

/// A CLI found in a particular environment.
class CliAgent {
  const CliAgent({
    required this.kind,
    required this.environmentId,
    required this.environmentLabel,
    required this.path,
    this.version,
  });

  final CliAgentKind kind;

  /// Which [CommandRunner] found it — `native`, `wsl:Ubuntu`.
  final String environmentId;
  final String environmentLabel;

  /// Resolved path in that environment.
  final String path;
  final String? version;

  /// Stable id for storing a user's choice.
  String get id => '${kind.name}@$environmentId';

  String get label => '${kind.label} · $environmentLabel';

  @override
  String toString() => '$label ($path${version == null ? '' : ' $version'})';
}

/// How to ask a CLI one question, and how to read its answer.
///
/// Kept as data so adding a CLI is a case here rather than a new code path,
/// and so the arguments can be asserted in tests without running anything.
class CliInvocation {
  const CliInvocation({required this.arguments, required this.parse});

  final List<String> arguments;

  /// Pulls assistant text out of one line of output. Returns null for lines
  /// that carry no text — progress, session banners, usage totals.
  final String? Function(String line) parse;
}

/// Builds the one-shot invocation for [kind].
///
/// [systemPrompt] replaces the CLI's own agent prompt: these are coding agents,
/// and left alone they will happily start reading files and running commands
/// instead of answering. Tools are disabled for the same reason — a voice
/// assistant that edits your repository because you thought aloud is not what
/// anyone asked for.
CliInvocation cliInvocation(
  CliAgentKind kind,
  String prompt, {
  String? systemPrompt,
  String? model,
}) => switch (kind) {
  CliAgentKind.claudeCode => CliInvocation(
    arguments: [
      '-p', prompt,
      '--output-format', 'stream-json',
      '--verbose',
      // No tools: answer from the conversation, do not act on it.
      '--allowed-tools', '',
      if (systemPrompt != null) ...['--system-prompt', systemPrompt],
      if (model != null) ...['--model', model],
    ],
    parse: parseClaudeStreamJson,
  ),
  CliAgentKind.codex => CliInvocation(
    arguments: [
      'exec',
      // Codex refuses to run outside a git repository otherwise, and the
      // app's working directory is not one.
      '--skip-git-repo-check',
      '--json',
      if (model != null) ...['--model', model],
      if (systemPrompt != null) '$systemPrompt\n\n$prompt' else prompt,
    ],
    parse: parseCodexJsonl,
  ),
  CliAgentKind.geminiCli => CliInvocation(
    arguments: [
      '-p',
      if (systemPrompt != null) '$systemPrompt\n\n$prompt' else prompt,
      if (model != null) ...['-m', model],
    ],
    // Gemini CLI prints the answer as plain text, so every line counts.
    parse: (line) => line.trim().isEmpty ? null : line,
  ),
};

/// Reads Claude Code's `--output-format stream-json` lines.
///
/// Only `assistant` messages carry the reply. The stream also contains session
/// initialisation, hook results and a final `result` object — the init frame
/// alone lists every tool and skill, which is far larger than the answer.
String? parseClaudeStreamJson(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('{')) return null;
  try {
    final json = jsonDecode(trimmed) as Map<String, dynamic>;
    if (json['type'] != 'assistant') return null;
    final message = json['message'] as Map<String, dynamic>?;
    final content = message?['content'];
    if (content is! List) return null;

    final text = StringBuffer();
    for (final block in content) {
      if (block is Map<String, dynamic> && block['type'] == 'text') {
        text.write(block['text'] ?? '');
      }
    }
    final out = text.toString();
    return out.isEmpty ? null : out;
  } on FormatException {
    return null;
  }
}

/// Reads Codex's `--json` lines.
///
/// The answer arrives as a completed `agent_message` item; `thread.started`,
/// `turn.started` and `turn.completed` are bookkeeping.
String? parseCodexJsonl(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('{')) return null;
  try {
    final json = jsonDecode(trimmed) as Map<String, dynamic>;
    if (json['type'] != 'item.completed') return null;
    final item = json['item'] as Map<String, dynamic>?;
    if (item?['type'] != 'agent_message') return null;
    final text = item?['text'] as String?;
    return (text == null || text.isEmpty) ? null : text;
  } on FormatException {
    return null;
  }
}

/// The command that locates an executable, per environment.
///
/// `where` on Windows; `command -v` inside a login shell elsewhere, so PATH
/// additions from `~/.profile` are present.
({String executable, List<String> arguments}) locateCommand(
  String environmentId,
  String executableName, {
  required bool windowsHost,
}) => environmentId == 'native' && windowsHost
    ? (executable: 'where', arguments: [executableName])
    : (executable: 'command', arguments: ['-v', executableName]);

/// First non-blank line of [text], trimmed.
String? firstNonEmptyLine(String text) {
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// A semantic version from `--version` output, or the first line if there is
/// no version-looking token in it.
String? parseVersion(String output) {
  final match = RegExp(
    r'\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.]+)?',
  ).firstMatch(output);
  return match?.group(0) ?? firstNonEmptyLine(output);
}
