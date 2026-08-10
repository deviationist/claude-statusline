# claude-statusline

A status line for [Claude Code](https://claude.com/claude-code) with **account-usage bars straight from Anthropic's own server-side counter** — plus live-togglable segments, controlled from your shell or from inside Claude Code via a `/sl` slash command.

```
╭─ Claude Code ────────────────────────────────────────────────────────── ~/code/app ─╮

   ❯ explain this repo
   ⏺ It's a status line for Claude Code with server-side usage bars…

   ──────────────────────────────────────────────────────────────────
   ~/code/app [main *] │ Opus │ ctx:42% │ #7 │ 7d▕██░░▏20% · 5h▕███░░▏49% Reset 1h8m
╰─────────────────────────────────────────────────────────────────────────────────────╯
```

(The status line is the last row; bars are green / amber / red by fill in a real
terminal.)

- **Usage bars show what Anthropic bills, not what ran locally.** The `claude-usage` component reads the same OAuth usage endpoint that claude.ai → Settings → Usage shows, covering *all* usage on the account (Claude Code on any machine + claude.ai) — unlike transcript-based tools that only see the current box. Works for both plan shapes: USD-budget seats render `$300.04/$300 ▕████▏100%`, Max/Pro seats render their 7d/model/5h rate-limit windows.
- **Never blocks your prompt.** The statusline only ever reads a cache; refreshes happen in a detached background process with stale-while-revalidate semantics, failure backoff, and lock-guarded fetches.
- **Every segment is togglable, live.** `statusline usage off` (or `/sl usage off` inside Claude Code) hides a segment on the next repaint — no restart, no settings edit.
- **`claude-usage` is also a standalone CLI**: colour bars, plain text, or JSON for scripts.

## Segments

| Segment | Shows | Toggle key |
|---|---|---|
| cwd | working directory (`~`-shortened) | always on |
| `host` | hostname prefix — Linux only (for SSH'd sessions) | `CLAUDE_STATUSLINE_HOST` |
| `git` | branch + red `*` dirty marker | `CLAUDE_STATUSLINE_GIT` |
| `model` | model display name | `CLAUDE_STATUSLINE_MODEL` |
| `ctx` | context-window used % | `CLAUDE_STATUSLINE_CTX` |
| `pr` | PR number (OSC 8 hyperlink when the terminal supports it) | `CLAUDE_STATUSLINE_PR` |
| `usage` | account spend / rate-limit bars | `CLAUDE_STATUSLINE_USAGE` |
| `reset` | 5h-session reset countdown (rendered inside `usage`) | `CLAUDE_STATUSLINE_RESET` |
| `profile` | seat label (`Personal (Max 5x)`) ahead of the bars — needs [claude-profile](https://github.com/deviationist/claude-profile) | `CLAUDE_STATUSLINE_PROFILE` |

### Which subscription am I burning? (`profile`)

With several Claude subscriptions on one machine, the bars alone don't say
*whose* they are. If the companion
[**claude-profile**](https://github.com/deviationist/claude-profile) juggler is
installed, the seat is named ahead of them:

```
~/code/app [main] | Opus 5 | ctx:12% | Personal (Max 5x) 7d▕██░░░░░░░░▏20% · 5h▕███░░░░░░░▏49% 1h8m
```

It is **on by default but self-disabling**: the statusline asks `claude-usage`
for a label, `claude-usage` asks `claude-profile` once — by the session's
config dir, not the cwd — and caches the answer. With no juggler installed, or
none that claims the dir, nothing is rendered and nothing is said. So there's
no flip to remember on a machine that has it, and no cost on one that doesn't.
`statusline profile off` refuses it outright.

The name and its casing come from claude-profile's own config (`display` /
`account_display`), not from here — and a profile holding a single
subscription renders as just `Personal`, without the parentheses.

## Install

Requirements: `zsh`, `jq`, `curl`. (The statusline script itself is POSIX `sh`; zsh is used for the toggle helper and the usage fetcher.)

The account-usage bars are provided by the companion
[**claude-usage**](https://github.com/deviationist/claude-usage) project. Clone
it as a **sibling** of this repo and the statusline finds it automatically; skip
it if you don't want the usage segment (everything else still works).

```sh
git clone https://github.com/deviationist/claude-statusline.git ~/code/claude-statusline
git clone https://github.com/deviationist/claude-usage.git       ~/code/claude-usage   # optional: usage bars
```

1. **Statusline** — in `~/.claude/settings.json`:

   ```json
   "statusLine": {
     "type": "command",
     "command": "bash /ABSOLUTE/PATH/TO/claude-statusline/statusline-command.sh"
   }
   ```

2. **Shell helpers** — in `~/.zshrc`:

   ```sh
   source ~/code/claude-statusline/statusline.zsh     # statusline toggle helper
   source ~/code/claude-usage/claude-usage.zsh        # claude-usage CLI (optional, from the sibling repo)
   ```

   The statusline locates `claude-usage.zsh` automatically when the
   `claude-usage` repo is cloned next to this one. If you keep it elsewhere,
   point `CLAUDE_USAGE_SCRIPT` at the file (e.g. in `settings.json`'s `"env"`).

3. **`/sl` slash command** (optional) — symlink it into Claude Code's commands dir:

   ```sh
   mkdir -p ~/.claude/commands
   ln -sf ~/code/claude-statusline/commands/sl.md ~/.claude/commands/sl.md
   ```

   (Named `/sl` because `/statusline` is a Claude Code built-in.)

## Toggling segments

```sh
statusline                  # list all segments with their current state
statusline usage off        # hide the account-usage bars
statusline reset toggle     # flip the 5h reset countdown
statusline model off        # hide the model name
```

Inside Claude Code: `/sl`, `/sl usage off`, `/sl reset toggle`, …

State is stored as plain `NAME=value` lines in `${XDG_CONFIG_HOME:-~/.config}/claude-statusline/config` (override the path with `$CLAUDE_STATUSLINE_CONFIG`). The statusline re-sources it on every repaint, so changes apply immediately to running sessions. The config can also set:

```sh
CLAUDE_STATUSLINE_BAR_WIDTH=10   # cells per usage bar
CLAUDE_STATUSLINE_SEP=" · "      # separator between usage bars
```

Anything the config doesn't set falls back to the same-named process environment variable (e.g. from `settings.json`'s `"env"` block — restart-bound), then defaults to shown.

## `claude-usage`

The usage bars are a separate, standalone tool with its own CLI (`--text-only`,
`--json`, `--raw`, `--dir`, per-account tokens, stale-while-revalidate caching)
— see the [**claude-usage**](https://github.com/deviationist/claude-usage) repo
for full docs. The statusline just calls it in `--no-block` mode.

## Caveats

- The usage endpoint (`api.anthropic.com/api/oauth/usage`) is **undocumented** and was reverse-engineered from Claude Code's own traffic. It may change or disappear without notice.
- Keep the TTL sane — hammering the endpoint gets rate-limited. The defaults are tuned for a statusline that repaints often.
- The tool only *reads* with the token Claude Code already stores locally; nothing is sent anywhere except the standard Anthropic API host.

## License

MIT — see [LICENSE](LICENSE).
