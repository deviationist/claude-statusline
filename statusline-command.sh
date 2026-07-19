#!/bin/sh
# claude-statusline — Claude Code status line with server-side usage bars.
#
# Renders:  [host:]cwd [branch *] | model | ctx:N% | [#PR] | usage bars
# e.g.      ~/code/app [main *] | Opus | ctx:42% | 7d▕██░░░▏20% · 5h▕███░░▏49% Reset 1h8m
#
# Wire into Claude Code via ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "bash /path/to/claude-statusline/statusline-command.sh"
#   }
#
# Every segment except cwd can be toggled per machine — interactively via the
# `statusline` helper (statusline.zsh; also the /sl slash command inside
# Claude Code), or by hand in the config file below.

# ---- config -----------------------------------------------------------------
# Per-machine config: plain POSIX "NAME=value" lines, sourced by sh and zsh
# alike. Created/edited by the `statusline` helper — no need to touch by hand.
#   CLAUDE_STATUSLINE_USAGE / RESET / MODEL / CTX / GIT / PR / HOST = 0|1
#   CLAUDE_STATUSLINE_BAR_WIDTH = cells per usage bar          (default 10)
#   CLAUDE_STATUSLINE_SEP       = separator between usage bars (default " · ")
# Config values win over same-named process-env vars (e.g. settings.json
# "env"); unset means shown. Re-sourced on every repaint, so toggles apply
# live to running sessions.
CONFIG="${CLAUDE_STATUSLINE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/config}"
[ -f "$CONFIG" ] && . "$CONFIG"

norm() { if [ "$1" = "0" ]; then echo 0; else echo 1; fi; }
SHOW_HOST=$(norm "${CLAUDE_STATUSLINE_HOST:-1}")
SHOW_GIT=$(norm "${CLAUDE_STATUSLINE_GIT:-1}")
SHOW_MODEL=$(norm "${CLAUDE_STATUSLINE_MODEL:-1}")
SHOW_CTX=$(norm "${CLAUDE_STATUSLINE_CTX:-1}")
SHOW_PR=$(norm "${CLAUDE_STATUSLINE_PR:-1}")
SHOW_USAGE=$(norm "${CLAUDE_STATUSLINE_USAGE:-1}")
SHOW_RESET=$(norm "${CLAUDE_STATUSLINE_RESET:-1}")

USAGE_BAR_WIDTH="${CLAUDE_STATUSLINE_BAR_WIDTH:-10}"
USAGE_SEP="${CLAUDE_STATUSLINE_SEP:- · }"
# -----------------------------------------------------------------------------

# claude-usage.zsh lives next to this script, wherever the repo is cloned.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
model=$(echo "$input" | jq -r '.model.display_name // ""')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
pr_number=$(echo "$input" | jq -r '.pr.number // ""')
pr_url=$(echo "$input" | jq -r '.pr.url // ""')
transcript=$(echo "$input" | jq -r '.transcript_path // empty')

# Shorten home directory to ~
short_cwd=$(echo "$cwd" | sed "s|^$HOME|~|")

# Hostname, Linux only: remote boxes are typically reached over SSH, where
# which host a session belongs to isn't otherwise visible. On a Mac you're
# usually local, so the segment is omitted as noise.
host_info=""
if [ "$SHOW_HOST" = 1 ] && [ "$(uname -s)" = "Linux" ]; then
  host=$(hostname -s 2>/dev/null || hostname)
  if [ -n "$host" ]; then
    host_info=$(printf "\033[1;32m%s\033[0m:" "$host")
  fi
fi

# Git branch (skip optional locks for safety)
git_branch=""
if [ "$SHOW_GIT" = 1 ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Try symbolic ref first, fall back to short SHA for detached HEAD
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
    if [ -n "$dirty" ]; then
      git_branch=$(printf " [\033[1;34m%s\033[0;31m *\033[0;32m]" "$branch")
    else
      git_branch=$(printf " [\033[1;34m%s\033[0;32m]" "$branch")
    fi
  fi
fi

# Context usage
ctx_info=""
if [ "$SHOW_CTX" = 1 ] && [ -n "$used" ]; then
  ctx_info=$(printf " | ctx:%s%%" "$(printf '%.0f' "$used")")
fi

# Model info
model_info=""
if [ "$SHOW_MODEL" = 1 ] && [ -n "$model" ]; then
  model_info=" | $model"
fi

# PR link (OSC 8 hyperlink if URL available, plain number otherwise)
pr_info=""
if [ "$SHOW_PR" = 1 ] && [ -n "$pr_number" ]; then
  if [ -n "$pr_url" ]; then
    pr_info=$(printf " | \033]8;;%s\a#%s\033]8;;\a" "$pr_url" "$pr_number")
  else
    pr_info=" | #$pr_number"
  fi
fi

# Account usage: spend/limits for the seat this session belongs to, rendered
# by claude-usage --pretty (same bars/colours as running `claude-usage` in a
# shell — single implementation for data AND presentation). Works for both
# plan shapes:
#   - USD-budget seats:  "$300.04/$300 ▕████▏100%"
#   - Max/Pro seats:     "7d▕██░░░▏17% · Opus▕██░░░▏20% · 5h▕█░░░░▏14% Reset 4h45m"
# Non-blocking: --no-block reads the claude-usage cache only, never hits the
# network on the statusline thread (the helper refreshes in the background on
# its own TTL).
usage_info=""
if [ "$SHOW_USAGE" = 1 ] && command -v zsh >/dev/null 2>&1; then
  # Which account? Prefer the explicit config dir, else derive it from the
  # transcript path (<config_dir>/projects/...), else let the helper self-resolve.
  config_dir="${CLAUDE_CONFIG_DIR:-}"
  if [ -z "$config_dir" ] && [ -n "$transcript" ]; then
    config_dir=$(printf '%s' "$transcript" | sed 's#/projects/.*##')
  fi

  # The 5h reset countdown is its own toggle, passed through as --show-reset.
  show_reset=true
  [ "$SHOW_RESET" = 0 ] && show_reset=false

  usage_out=$(CLAUDE_USAGE_BAR_WIDTH="$USAGE_BAR_WIDTH" zsh -c '
    source "$4/claude-usage.zsh" 2>/dev/null || exit 0
    if [ -n "$1" ]; then
      claude-usage --dir "$1" --pretty --sep "$2" --show-reset="$3" --no-block 2>/dev/null
    else
      claude-usage --pretty --sep "$2" --show-reset="$3" --no-block 2>/dev/null
    fi
  ' _ "$config_dir" "$USAGE_SEP" "$show_reset" "$SCRIPT_DIR")

  [ -n "$usage_out" ] && usage_info=" | $usage_out"
fi

printf "%s\033[33m%s\033[0m" "$host_info" "$short_cwd"
printf "%s\033[0m%s%s%s%s" "$git_branch" "$model_info" "$ctx_info" "$pr_info" "$usage_info"
