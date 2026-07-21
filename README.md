# claude-statusline

A status line for [Claude Code](https://claude.com/claude-code) with **account-usage bars straight from Anthropic's own server-side counter** — plus live-togglable segments, controlled from your shell or from inside Claude Code via a `/sl` slash command.

```
~/code/app [main *] | Opus | ctx:42% | #7 | 7d▕██░░░░░░░░▏20% · Opus▕██▊░░░░░░░▏27% · 5h▕████▉░░░░░▏49% Reset 1h8m
```

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

## Install

Requirements: `zsh`, `jq`, `curl`. (The statusline script itself is POSIX `sh`; zsh is used for the usage fetcher and the toggle helper.)

```sh
git clone https://github.com/deviationist/claude-statusline.git ~/code/claude-statusline
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
   source ~/code/claude-statusline/claude-usage.zsh   # claude-usage CLI
   source ~/code/claude-statusline/statusline.zsh     # statusline toggle helper
   ```

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

## `claude-usage` standalone

```
claude-usage                          # colour progress bars (default)
claude-usage --text-only              # plain one-liner: "7d 16% | Opus 25% | 5h 4% Reset 4h45m"
claude-usage --json                   # machine-readable summary for scripts
claude-usage --raw                    # full untouched endpoint response
claude-usage --fresh                  # blocking refresh, guaranteed current
claude-usage --no-block               # statusline mode: never blocks, silent on cold/broken state
claude-usage --dir PATH               # another account's Claude config dir
claude-usage --sep ' / '              # custom metric delimiter
claude-usage --show-reset=false       # drop the reset countdown
```

Account resolution: `--dir` > `$CLAUDE_USAGE_DIR` > `$CLAUDE_CONFIG_DIR` > `~/.claude`. The OAuth token is read from `<dir>/.credentials.json` or, on macOS, the Keychain entry Claude Code itself maintains (per-account namespaced; the freshest non-expired token wins).

Caching is per account under `$TMPDIR`: bare calls return instantly from cache and revalidate in the background after a 120s TTL (override via `CLAUDE_USAGE_TTL`); failed refreshes never destroy the last known value and back off for 60s so a constantly-repainting statusline can't hammer the endpoint.

## Caveats

- The usage endpoint (`api.anthropic.com/api/oauth/usage`) is **undocumented** and was reverse-engineered from Claude Code's own traffic. It may change or disappear without notice.
- Keep the TTL sane — hammering the endpoint gets rate-limited. The defaults are tuned for a statusline that repaints often.
- The tool only *reads* with the token Claude Code already stores locally; nothing is sent anywhere except the standard Anthropic API host.

## License

MIT — see [LICENSE](LICENSE).
