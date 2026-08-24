# Changelog

## 0.1.0

First release.

- `discoverEnvironments()` — this machine, plus each installed WSL distribution.
- `discoverCliAgents()` — locates Claude Code, Codex and Gemini CLI in every
  environment, with versions.
- `CliSession` — asks one question and streams the answer back.
- `CommandRunner` — the process abstraction, with native and WSL
  implementations.
