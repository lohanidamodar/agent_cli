import 'package:agent_cli/agent_cli.dart';
import 'package:test/test.dart';

void main() {
  group('buildWslInvocation', () {
    test('separates wsl flags from the command with --', () {
      // Without the separator, `-p` is consumed by wsl instead of by claude.
      final call = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(executable: 'claude', arguments: ['-p', 'hi']),
      );

      expect(call.executable, 'wsl.exe');
      expect(call.arguments, ['-d', 'Ubuntu', '--', 'claude', '-p', 'hi']);
    });

    test('runs through a login shell so ~/.local/bin is on PATH', () {
      // The CLIs install there, and ~/.profile is what puts it on PATH. A
      // non-login shell never sources it, so the CLI looks uninstalled.
      final call = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(executable: 'claude', arguments: ['-p', 'hi']),
        loginShell: true,
      );

      expect(call.arguments.sublist(0, 4), ['-d', 'Ubuntu', '--', 'bash']);
      expect(call.arguments[4], '-lc');
      expect(call.arguments[5], "'claude' '-p' 'hi'");
    });

    test('quotes a prompt containing quotes and newlines', () {
      final call = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(
          executable: 'claude',
          arguments: ["it's here\nand here"],
        ),
        loginShell: true,
      );

      // The apostrophe must not end the quoted string.
      expect(call.arguments.last, contains(r"it'\''s here"));
    });

    test('passes a working directory as a WSL path', () {
      final call = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(executable: 'ls', workingDirectory: '/home/you'),
      );
      expect(call.arguments, containsAllInOrder(['--cd', '/home/you']));
    });
  });

  group('parseDistributions', () {
    test('reads UTF-16 output decoded as UTF-8', () {
      // wsl --list --quiet emits UTF-16; read as UTF-8 every character is
      // followed by a zero byte. Rejecting those lines makes WSL look absent.
      const raw = 'U\u0000b\u0000u\u0000n\u0000t\u0000u\u0000\r\n';
      expect(parseDistributions(raw), ['Ubuntu']);
    });

    test('handles plain output too', () {
      expect(parseDistributions('Ubuntu\nDebian\n'), ['Ubuntu', 'Debian']);
    });

    test('ignores blank lines', () {
      expect(parseDistributions('\n\nUbuntu\n\n'), ['Ubuntu']);
    });
  });

  group('locateCommand', () {
    test('uses where on a Windows host', () {
      final c = locateCommand('native', 'claude', windowsHost: true);
      expect(c.executable, 'where');
    });

    test('uses command -v everywhere else, including inside WSL', () {
      expect(
        locateCommand('native', 'claude', windowsHost: false).executable,
        'command',
      );
      expect(
        locateCommand('wsl:Ubuntu', 'claude', windowsHost: true).executable,
        'command',
      );
    });
  });

  group('parseClaudeStreamJson', () {
    test('extracts assistant text', () {
      const line =
          '{"type":"assistant","message":{"content":[{"type":"text","text":"one two three"}]}}';
      expect(parseClaudeStreamJson(line), 'one two three');
    });

    test('ignores the init frame, which is far larger than any answer', () {
      const line = '{"type":"system","subtype":"init","tools":["Bash","Read"]}';
      expect(parseClaudeStreamJson(line), isNull);
    });

    test('ignores hooks, rate-limit events and the final result object', () {
      for (final line in const [
        '{"type":"system","subtype":"hook_started"}',
        '{"type":"rate_limit_event","rate_limit_info":{}}',
        '{"type":"result","result":"one two three"}',
      ]) {
        expect(parseClaudeStreamJson(line), isNull, reason: line);
      }
    });

    test('ignores non-text blocks in an assistant message', () {
      const line =
          '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}';
      expect(
        parseClaudeStreamJson(line),
        isNull,
        reason: 'reasoning must never be spoken aloud',
      );
    });

    test('survives a partial or non-JSON line', () {
      expect(parseClaudeStreamJson('{"type":"assist'), isNull);
      expect(parseClaudeStreamJson('Loading...'), isNull);
      expect(parseClaudeStreamJson(''), isNull);
    });
  });

  group('parseCodexJsonl', () {
    test('extracts the agent message', () {
      const line =
          '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hello"}}';
      expect(parseCodexJsonl(line), 'hello');
    });

    test('ignores thread and turn bookkeeping', () {
      for (final line in const [
        '{"type":"thread.started","thread_id":"x"}',
        '{"type":"turn.started"}',
        '{"type":"turn.completed","usage":{"input_tokens":14994}}',
      ]) {
        expect(parseCodexJsonl(line), isNull, reason: line);
      }
    });

    test('ignores completed items that are not the answer', () {
      const line =
          '{"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}';
      expect(parseCodexJsonl(line), isNull);
    });
  });

  group('cliInvocation', () {
    test('claude runs with tools off and a replaced system prompt', () {
      // These are coding agents. Left alone they will read files and run
      // commands instead of answering a spoken question.
      final call = cliInvocation(
        CliAgentKind.claudeCode,
        'What is the capital of Nepal?',
        systemPrompt: 'You are a voice assistant.',
      );

      expect(call.arguments, containsAllInOrder(['--allowed-tools', '']));
      expect(
        call.arguments,
        containsAllInOrder(['--system-prompt', 'You are a voice assistant.']),
      );
      expect(
        call.arguments,
        containsAllInOrder(['--output-format', 'stream-json']),
      );
      expect(call.arguments.first, '-p');
    });

    test('codex is told to run outside a git repository', () {
      // It refuses otherwise, and an app's working directory is not a repo.
      final call = cliInvocation(CliAgentKind.codex, 'hi');
      expect(call.arguments, contains('--skip-git-repo-check'));
      expect(call.arguments, contains('--json'));
      expect(call.arguments.first, 'exec');
    });

    test('codex takes the system prompt inline, having no flag for it', () {
      final call = cliInvocation(
        CliAgentKind.codex,
        'What is the capital?',
        systemPrompt: 'Reply in one sentence.',
      );
      expect(
        call.arguments.last,
        'Reply in one sentence.\n\nWhat is the capital?',
      );
    });

    test('a model override reaches each CLI in its own spelling', () {
      expect(
        cliInvocation(CliAgentKind.claudeCode, 'x', model: 'sonnet').arguments,
        containsAllInOrder(['--model', 'sonnet']),
      );
      expect(
        cliInvocation(CliAgentKind.geminiCli, 'x', model: 'flash').arguments,
        containsAllInOrder(['-m', 'flash']),
      );
    });
  });

  group('parseVersion', () {
    test('finds a semantic version anywhere in the output', () {
      expect(parseVersion('claude 2.1.241 (Claude Code)'), '2.1.241');
      expect(parseVersion('codex-cli 0.9.0-alpha.1'), '0.9.0-alpha.1');
    });

    test('falls back to the first line rather than nothing', () {
      expect(parseVersion('experimental build\n'), 'experimental build');
      expect(parseVersion(''), isNull);
    });
  });

  group('CliAgent', () {
    test('has a stable id combining the CLI and where it lives', () {
      const agent = CliAgent(
        kind: CliAgentKind.claudeCode,
        environmentId: 'wsl:Ubuntu',
        environmentLabel: 'WSL - Ubuntu',
        path: '/home/you/.local/bin/claude',
      );
      expect(agent.id, 'claudeCode@wsl:Ubuntu');
      expect(agent.label, 'Claude Code · WSL - Ubuntu');
    });

    test('the same CLI in two environments is two agents', () {
      const native = CliAgent(
        kind: CliAgentKind.codex,
        environmentId: 'native',
        environmentLabel: 'windows',
        path: r'C:\codex.exe',
      );
      const wsl = CliAgent(
        kind: CliAgentKind.codex,
        environmentId: 'wsl:Ubuntu',
        environmentLabel: 'WSL - Ubuntu',
        path: '/home/you/.local/bin/codex',
      );
      expect(native.id, isNot(wsl.id));
    });
  });
}
