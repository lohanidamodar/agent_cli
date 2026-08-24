# agent_cli

Find and drive the AI coding CLIs already installed on a machine — **Claude
Code**, **Codex**, **Gemini CLI** — including ones living inside a WSL
distribution.

The appeal is authentication. Someone using `claude` or `codex` daily has
already signed in; driving their CLI reuses that. No API key to paste, no
second subscription.

```dart
final agents = await discoverCliAgents();
// claudeCode@native   /home/you/.local/bin/claude  2.1.241
// codex@wsl:Ubuntu    /home/you/.local/bin/codex   0.146.0

final session = CliSession(agents.first);
await for (final text in session.ask('What is the capital of Nepal?')) {
  stdout.write(text);
}
```

## Why this is not a one-liner

Three things decide whether it works at all, and all three were found by it not
working.

**Lookups have to go through a login shell.** These CLIs install into
`~/.local/bin`, which `~/.profile` puts on `PATH`. A non-login shell never
sources it, so a bare `which` reports nothing on a machine with two CLIs
installed. Worse, `command -v` is a shell *builtin* — there is no executable —
so `Process.run('command', ...)` fails outright. This applies on Linux and
macOS exactly as much as inside WSL.

**Tools have to be turned off and the system prompt replaced.** These are
coding agents. Left with their own prompt they will read files and run commands
instead of answering the question. Anything embedding one as a chat backend
wants an answer, not an agent loose in the working directory.

**stdin has to be closed immediately.** A CLI that reads stdin when it is not a
terminal waits forever for input that never comes — `codex exec` prints
"Reading additional input from stdin…" and then hangs.

## Environments

`discoverEnvironments()` returns a `CommandRunner` for this machine and, on
Windows, one per installed WSL distribution. That second part matters: WSL is
where these CLIs usually live on a Windows box, so a Windows app that looked
only at its own `PATH` would report nothing installed while the user has been
using `claude` all week.

Parsing `wsl --list --quiet` has its own trap — the output is UTF-16, so read
as UTF-8 every character is followed by a zero byte. Reject those lines and
every distribution name comes back empty.

## What it costs

Measured against a local llama.cpp server answering the same question:

| backend | first text |
|---|---|
| llama.cpp, Qwen3-1.7B | 95 ms |
| llama.cpp, Gemma 3 4B | 257 ms |
| Claude Code CLI | 5542 ms |
| Codex CLI | 7407 ms |

Every call is a fresh process that loads the tool list, hooks and project
instructions before it answers — one measured invocation created 8011 cache
tokens to produce five tokens of reply. This is the convenient backend, not the
fast one. If you are building something interactive, say so where the choice is
made.

## Statelessness

Each `ask()` is a separate process, so a conversation travels in the prompt.
The CLIs do have resume modes, and this deliberately does not use them: that
would move the conversation's memory into the CLI's own session store, where
the calling code cannot trim it, inspect it, or keep it consistent with the
history it believes it has.

## Adding a CLI

`cliInvocation()` is a switch over `CliAgentKind` returning the arguments and a
line parser. Adding one is a case there plus a parser — both assertable in
tests without running anything.

## Status

Claude Code and Codex are verified end to end. Gemini CLI is implemented from
its documented interface but has not been run — it was not installed on the
machine this was built on. Treat it as untested.

## Licence

MIT.
