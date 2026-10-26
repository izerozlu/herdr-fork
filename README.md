# herdr-fork

A Claude Code plugin for [Herdr](https://herdr.dev). It opens forks of a Claude session in their own Herdr tab. A fork is a new agent that starts with a copy of the whole conversation so far.

The plugin stands alone. Its tab handling was inspired by [herdr-lock](https://github.com/aalvarezdeliveryhub/herdr-lock), but herdr-lock is not needed.

## What it does

| Part | What it does |
|---|---|
| `herdr-fork` command | Starts `claude --resume <this session> --fork-session` in a new tab of this workspace, then sends it the task. |
| Fork pane (SessionStart hook) | When you type `/fork` inside Herdr, Claude Code starts the fork as a background session. The hook opens a new pane next to the session (or a tab or workspace, see below) and runs `claude attach <id>` in it, so you can see the fork and type to it there. |
| Guard (PreToolUse hook on the Agent tool) | Inside Herdr, blocks the built-in fork subagent (`subagent_type: "fork"`) and tells Claude to use `herdr-fork`. Other agent types are not changed. |
| Fork rule (SessionStart hook) | Inside Herdr, tells Claude to fork with `herdr-fork`. |

## Requirements

- Claude Code with plugin support, run inside a Herdr pane
- `jq`

## Install (local checkout)

```bash
claude plugin marketplace add ~/Projects/hobby/herdr-fork
claude plugin install herdr-fork@herdr-fork
```

Start a new Claude session after you install it. Hooks load when a session starts.

## Use

Type `/fork` in a Claude session inside Herdr. A new pane opens to the right and shows the fork. Type the fork's first prompt there.

To change where the fork opens, set the plugin's **Fork destination** option (`/plugin` → herdr-fork → configure). The environment variable `HERDR_FORK_LAYOUT` wins over the option, if you set it (for example in the `env` block of `~/.claude/settings.json`).

| Value | Where the fork opens |
|---|---|
| `right` (default) | New pane to the right of the session |
| `left` | New pane to the left of the session |
| `down` | New pane below the session |
| `up` | New pane above the session |
| `tab` | New tab in the same workspace |
| `workspace` | New workspace |

When Herdr closes the fork's pane, the plugin stops the fork session. Set the **When the fork pane closes** option (or `HERDR_FORK_ON_CLOSE`) to change this:

| Value | What happens when the pane closes |
|---|---|
| `stop` (default) | `claude stop <id>`. The conversation is kept; `claude attach <id>` opens it again. |
| `remove` | `claude stop <id>`, then `claude rm <id>`. `rm` does not discard unpushed worktree commits. |
| `keep` | Nothing. The fork keeps running in the background. |

Leaving the attach view (← or Ctrl+Z) does not stop the fork. Only closing the pane does.

Claude can also fork itself with the `herdr-fork` command:

```
herdr-fork [-a "claude args"] [-C subdir] <name> "<task>"
herdr-fork list
herdr-fork close <name>
```

- `-a` replaces the default `--permission-mode auto`. `--resume` and `--fork-session` are always added.
- `-C` opens the fork in a folder inside this one, for example a git worktree in `.worktrees/<name>`. A folder outside this one is refused.
- The fork writes its report to `/tmp/herd/<name>.md`.
- The name must be unique across all Herdr agents.
- `herdr-fork list` shows the other agents in this workspace. `herdr-fork close <name>` closes a fork's tab.
- Exit status: 0 ok, 1 Herdr error, 2 refused, 3 the fork waits at a startup prompt (for example "trust this folder?") and has not got its task yet.

## Tests

```bash
test/run-tests.sh
```

## License

MIT
