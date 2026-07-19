---
description: Toggle Claude Code statusline segments (usage, reset, model, ctx, git, pr, host)
argument-hint: "[segment] [on|off|toggle] — no args lists all segments"
allowed-tools: Bash(zsh:*)
---

## Result

!`zsh -ic 'statusline $ARGUMENTS' 2>&1 | grep -v '^$'`

## Task

The command above already applied the change (state lives in the
claude-statusline config file; the statusline picks it up on its next repaint —
no restart). Relay the result to the user concisely. If it shows a usage error,
explain: segments are `usage`, `reset`, `model`, `ctx`, `git`, `pr`, `host`;
actions are `on`, `off`, `toggle`; `/sl` alone lists every segment with its
current state. If it says `command not found: statusline`, the claude-statusline
repo's `statusline.zsh` isn't sourced from the user's `~/.zshrc` yet — point
them to the install steps in the repo README.
