# herdr-forks

A Claude Code plugin for [Herdr](https://herdr.dev). It opens forks of a Claude session in their own Herdr tab. A fork is a new agent that starts with a copy of the whole conversation so far.

It builds on [herdr-lock](https://github.com/aalvarezdeliveryhub/herdr-lock): `herdr-lock`'s `herdr-worker` opens the tab, so forks stay in the session's workspace and folder.

## What it does

| Part | What it does |
|---|---|
| `herdr-fork` command | Starts `claude --resume <this session> --fork-session` in a new tab of this workspace (through `herdr-worker`), then sends it the task. |
| Fork tab (SessionStart hook) | When you type `/fork` inside Herdr, Claude Code starts the fork as a background session. The hook opens a new tab in the same workspace that runs `claude attach <id>`, so you can see the fork and type to it there. |
| Guard (PreToolUse hook on the Agent tool) | Inside Herdr, blocks the built-in fork subagent (`subagent_type: "fork"`) and tells Claude to use `herdr-fork`. Other agent types are not changed. |
| Fork rule (SessionStart hook) | Inside Herdr, tells Claude to fork with `herdr-fork`. |

## Requirements

- Claude Code with plugin support, run inside a Herdr pane
- The herdr-lock plugin (`claude plugin install herdr-lock@herdr-lock`)
- `jq`

## Install (local checkout)

```bash
claude plugin marketplace add ~/Projects/hobby/herdr-forks
claude plugin install herdr-forks@herdr-forks
```

Start a new Claude session after you install it. Hooks load when a session starts.

## Use

Type `/fork` in a Claude session inside Herdr. A new tab named `fork <id>` opens and shows the fork. Type the fork's first prompt there.

Claude can also fork itself with the `herdr-fork` command:

```
herdr-fork [-a "claude args"] [-C subdir] <name> "<task>"
```

- `-a` replaces the default `--permission-mode auto`. `--resume` and `--fork-session` are always added.
- `-C` opens the fork in a folder inside this one, for example a git worktree in `.worktrees/<name>`.
- The fork writes its report to `/tmp/herd/<name>.md`.
- `herdr-worker list` and `herdr-worker close <name>` work for fork tabs too.
- Exit status is the same as `herdr-worker` (3 means the fork waits at a startup prompt, for example "trust this folder?").

## Tests

```bash
test/run-tests.sh
```

## License

MIT
