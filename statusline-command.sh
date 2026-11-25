#!/bin/sh
# claude-statusline — Claude Code status line with server-side usage bars.
#
# Renders:  [host:]cwd [branch *] | model (effort) | ctx:N% | [cache:Nm] | [#PR] | usage bars
# e.g.      ~/code/app [main *] | Opus (high) | ctx:42% | 7d▕██░░░▏20% · 5h▕███░░▏49% Reset 1h8m
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
#   CLAUDE_STATUSLINE_USAGE / RESET / BUDGET / PROFILE / MODEL / EFFORT /
#   CTX / CACHE / GIT / PR / HOST
#                               = 0|1   (BUDGET and CACHE default to 0, the
#                                        rest to 1)
#   CLAUDE_STATUSLINE_BAR_WIDTH = cells per usage bar          (default 10)
#   CLAUDE_STATUSLINE_SEP       = separator between usage bars (default " · ")
#   CLAUDE_STATUSLINE_CACHE_STYLE / CACHE_FORMAT = how the cache countdown
#                                 reads (see SHOW_CACHE below)
#   CLAUDE_STATUSLINE_GIT_TTL   = seconds to reuse the git segment   (default 5)
#   CLAUDE_STATUSLINE_USAGE_TTL = seconds to reuse the usage segment (default 30)
#                                 0 recomputes on every repaint (see memo below)
# Config values win over same-named process-env vars (e.g. settings.json
# "env"); unset means shown. Re-sourced on every repaint, so toggles apply
# live to running sessions.
CONFIG="${CLAUDE_STATUSLINE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/config}"
[ -f "$CONFIG" ] && . "$CONFIG"

# flag SHOW_X CLAUDE_STATUSLINE_X: 0 when the config says 0, else 1. Sets the
# variable directly rather than echoing, so no subshell per flag.
flag() { eval "[ \"\${$2:-1}\" = 0 ] && $1=0 || $1=1"; }
flag SHOW_HOST   CLAUDE_STATUSLINE_HOST
flag SHOW_GIT    CLAUDE_STATUSLINE_GIT
flag SHOW_MODEL  CLAUDE_STATUSLINE_MODEL
flag SHOW_EFFORT CLAUDE_STATUSLINE_EFFORT
flag SHOW_CTX    CLAUDE_STATUSLINE_CTX
flag SHOW_PR     CLAUDE_STATUSLINE_PR
flag SHOW_USAGE  CLAUDE_STATUSLINE_USAGE
flag SHOW_RESET  CLAUDE_STATUSLINE_RESET
# Daily budget on the monthly $-cap ("$14.32/day": what's left of the cap ÷
# days left until it resets, today included). OPT-IN — the one segment that
# defaults OFF. Rendered by claude-usage inside the usage segment, and only
# where a $-cap renders (USD-budget seats, or Pro/Max/Ultra with usage
# credits), so turning it on is harmless on a %-only seat.
SHOW_BUDGET=0
[ "${CLAUDE_STATUSLINE_BUDGET:-0}" = "1" ] && SHOW_BUDGET=1
# Prompt-cache countdown ("cache:52m07s" or "cache:until 14:32", then
# "cache:cold 180k"). OPT-IN as well.
SHOW_CACHE=0
[ "${CLAUDE_STATUSLINE_CACHE:-0}" = "1" ] && SHOW_CACHE=1
# How it reads, while warm:
#   CLAUDE_STATUSLINE_CACHE_STYLE  = relative (default): time left, "52m07s"
#                                  | clock: when it goes cold, "until 14:32"
#   CLAUDE_STATUSLINE_CACHE_FORMAT = format for that style. relative takes
#                                    %m minutes, %M minutes 2-digit, %s seconds
#                                    2-digit, %t total seconds, %% a literal %
#                                    (default "%mm%ss"; "%mm" = minutes only,
#                                    "%M:%s" = "52:07"). clock takes a strftime
#                                    format (default "until %H:%M").
CACHE_STYLE="${CLAUDE_STATUSLINE_CACHE_STYLE:-relative}"
case "$CACHE_STYLE" in
  clock) CACHE_FORMAT="${CLAUDE_STATUSLINE_CACHE_FORMAT:-until %H:%M}" ;;
  *)     CACHE_STYLE=relative
         CACHE_FORMAT="${CLAUDE_STATUSLINE_CACHE_FORMAT:-%mm%ss}" ;;
esac
# Which subscription is this session burning? Rendered by claude-usage at the
# head of its own segment ("Personal (Pro) 7d▕…"), resolved from the
# companion claude-profile tool. Effectively AUTO: on by default, but
# claude-usage renders nothing unless claude-profile is installed AND claims
# the session's config dir — so this costs machines without the juggler
# nothing and needs no manual flip on machines with it. `statusline profile
# off` forces it off.
flag SHOW_PROFILE CLAUDE_STATUSLINE_PROFILE

USAGE_BAR_WIDTH="${CLAUDE_STATUSLINE_BAR_WIDTH:-10}"
USAGE_SEP="${CLAUDE_STATUSLINE_SEP:- · }"
GIT_TTL="${CLAUDE_STATUSLINE_GIT_TTL:-5}"
USAGE_TTL="${CLAUDE_STATUSLINE_USAGE_TTL:-30}"
# -----------------------------------------------------------------------------

input=$(cat)

# Every field in ONE jq pass, as shell assignments (@sh quotes them safely).
# A jq per field was ~5 ms each, a third of the whole render.
eval "$(printf '%s' "$input" | jq -r '
  @sh "cwd=\(.workspace.current_dir // .cwd // "")",
  @sh "model=\(.model.display_name // "")",
  @sh "effort=\(.effort.level // "")",
  @sh "used=\(.context_window.used_percentage // "")",
  @sh "pr_number=\(.pr.number // "")",
  @sh "pr_url=\(.pr.url // "")",
  @sh "transcript=\(.transcript_path // "")",
  @sh "session_id=\(.session_id // "")",
  (.prompt_cache // null | if . == null then "pc_present=0" else
    "pc_present=1",
    @sh "pc_seen=\(.caching_observed // false)",
    @sh "pc_warm=\(.warm // false)",
    @sh "pc_ttl=\(.ttl // "5m")",
    @sh "pc_exp=\(.expires_at // 0)",
    @sh "pc_recache=\(.recache_tokens_if_cold // 0)" end)
' 2>/dev/null)"
# Session effort level (low/medium/high/xhigh/max) is empty when the model
# doesn't support the effort parameter, in which case the segment is skipped.

now=$(date +%s)

# ---- memo: per-segment output cache ----------------------------------------
# Claude Code re-runs this whole script on every repaint (refreshInterval can
# be 1 s, for a ticking cache countdown), and has no cache of its own. So the
# expensive segments memoise their rendered output, nested like Russian
# dolls: Anthropic's API → claude-usage's own cache (~120 s) → the memo here
# → the line. Only the cheap, per-second parts (the countdown) are computed
# fresh on every paint.
#
#   memo NAME TTL EMPTY_TTL KEY cmd args…   → sets $memo_out
#
# Reuses the stored output while it's younger than TTL seconds (EMPTY_TTL
# when it was empty: e.g. usage not fetched yet, so retry soon) AND KEY still
# matches (the inputs it depends on: cwd, flags…); otherwise runs cmd and
# stores its first line. TTL 0 = always run. A hit costs no process at all:
# the timestamp lives inside the file and is read with the `read` builtin.
# Files are per session (session_id), a few hundred bytes each, in $TMPDIR
# (or $CLAUDE_STATUSLINE_MEMO_DIR).
memo_dir="${TMPDIR:-/tmp}"
memo_dir="${CLAUDE_STATUSLINE_MEMO_DIR:-${memo_dir%/}/claude-statusline-${USER:-${LOGNAME:-user}}}"
memo() {
  _mf="$memo_dir/${session_id:-nosession}.$1"; _mttl=$2; _mettl=$3; _mkey=$4
  shift 4
  if [ "$_mttl" -gt 0 ] 2>/dev/null && [ -f "$_mf" ]; then
    _mts=; _mk=; memo_out=
    { IFS= read -r _mts; IFS= read -r _mk; IFS= read -r memo_out; } < "$_mf"
    [ -z "$memo_out" ] && _mttl=$_mettl
    if [ "$_mk" = "$_mkey" ] && [ $(( now - ${_mts:-0} )) -lt "$_mttl" ] 2>/dev/null; then
      return 0
    fi
  fi
  memo_out=$("$@")
  memo_out=${memo_out%%"
"*}
  [ "$_mttl" -gt 0 ] 2>/dev/null || return 0
  mkdir -p "$memo_dir" 2>/dev/null
  printf '%s\n%s\n%s\n' "$now" "$_mkey" "$memo_out" > "$_mf.$$" 2>/dev/null \
    && mv -f "$_mf.$$" "$_mf" 2>/dev/null
}

# Cleanup: files are per session, so ended sessions leave theirs behind.
# At most once an hour (a stamp file, read with the builtin), delete memo
# files untouched for a day, including temp files a cancelled run left
# half-written. A live session just recomputes anything it loses.
# Only our own files, at the top level: $CLAUDE_STATUSLINE_MEMO_DIR may point
# at a folder other things use too. Always returns 0, because it runs last
# and its status becomes the script's exit status (two sessions pruning at
# once can make find fail on a file the other one already deleted).
memo_prune() {
  [ -d "$memo_dir" ] || return 0
  _pts=0
  [ -f "$memo_dir/.pruned" ] && IFS= read -r _pts < "$memo_dir/.pruned"
  [ $(( now - ${_pts:-0} )) -ge 3600 ] 2>/dev/null || return 0
  printf '%s\n' "$now" > "$memo_dir/.pruned" 2>/dev/null
  # Names are <session-id>.<segment>, or .<pid> on top while half-written.
  find "$memo_dir" -maxdepth 1 -type f \
    \( -name '????????-????-????-????-????????????.*' -o -name 'nosession.*' \) \
    \( -name '*.git' -o -name '*.host' -o -name '*.usage' \
       -o -name '*.git.[0-9]*' -o -name '*.host.[0-9]*' -o -name '*.usage.[0-9]*' \) \
    -mmin +1440 -delete 2>/dev/null
  return 0
}
# -----------------------------------------------------------------------------

# Shorten home directory to ~ (case pattern, no sed process)
case "$cwd" in
  "$HOME"|"$HOME"/*) short_cwd="~${cwd#"$HOME"}" ;;
  *)                 short_cwd=$cwd ;;
esac

# Hostname, Linux only: remote boxes are typically reached over SSH, where
# which host a session belongs to isn't otherwise visible. On a Mac you're
# usually local, so the segment is omitted as noise. Memoised for a day: the
# OS doesn't change mid-session.
host_seg() {
  [ "$(uname -s)" = "Linux" ] || return 0
  host=$(hostname -s 2>/dev/null || hostname)
  [ -n "$host" ] && printf "\033[1;32m%s\033[0m:" "$host"
}
host_info=""
if [ "$SHOW_HOST" = 1 ]; then
  memo host 86400 86400 "-" host_seg
  host_info=$memo_out
fi

# Git branch + dirty marker, from ONE `git status --porcelain=v2 --branch`
# (it reports the branch, the commit for a detached HEAD, and the changes).
# Skips optional locks for safety. Memoised for GIT_TTL seconds per cwd, so
# the marker can trail an edit by that much.
git_seg() {
  _head=; _oid=; _dirty=
  while IFS= read -r _l; do
    case "$_l" in
      "# branch.head "*) _head=${_l#"# branch.head "} ;;
      "# branch.oid "*)  _oid=${_l#"# branch.oid "} ;;
      "#"*)              ;;
      *)                 _dirty=1; break ;;
    esac
  done <<EOF
$(git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)
EOF
  # Detached HEAD: show the short SHA instead (first 7 chars).
  [ "$_head" = "(detached)" ] && _head=${_oid%"${_oid#???????}"}
  [ -n "$_head" ] || return 0
  if [ -n "$_dirty" ]; then
    printf " [\033[1;34m%s\033[0;31m *\033[0;32m]" "$_head"
  else
    printf " [\033[1;34m%s\033[0;32m]" "$_head"
  fi
}
git_branch=""
if [ "$SHOW_GIT" = 1 ]; then
  memo git "$GIT_TTL" "$GIT_TTL" "$cwd" git_seg
  git_branch=$memo_out
fi

# Context usage
ctx_info=""
if [ "$SHOW_CTX" = 1 ] && [ -n "$used" ]; then
  ctx_info=$(printf " | ctx:%s%%" "$(printf '%.0f' "$used")")
fi

# Prompt cache countdown: how long until the main conversation's cached
# prefix goes cold ("cache:52m07s"), and once it has, what the next turn will
# re-cache ("cache:cold 180k"). OPT-IN. Straight from Claude Code's own
# `prompt_cache` object (v2.1.251+), whose expires_at is the clock the cache
# TTL actually runs on, and every cache hit pushes it out again. Absent
# before the first API response, and silent when caching_observed is false
# (caching off, or a gateway that doesn't report cache tokens).
#
# Style and format come from CACHE_STYLE / CACHE_FORMAT (config section).
# A relative countdown only moves when Claude Code repaints: on activity,
# every refreshInterval seconds, and once more at expires_at. For ticking
# seconds set refreshInterval low (1–5); with a long one, use a minutes-only
# format or the clock style, which never goes stale.
# Colour: green, then amber and red as it nears expiry. Thresholds per TTL
# (1h: 10m / 3m; 5m: 2m / 1m).
cache_info=""
if [ "$SHOW_CACHE" = 1 ] && [ "$pc_present" = 1 ]; then
  if [ "$pc_seen" = "true" ]; then
    left=$(( ${pc_exp%.*} - now ))
    if [ "$pc_warm" = "true" ] && [ "$left" -gt 0 ]; then
      case "$pc_ttl" in
        1h) amber=600; red=180 ;;
        *)  amber=120; red=60 ;;
      esac
      if   [ "$left" -le "$red" ];   then col='0;31'
      elif [ "$left" -le "$amber" ]; then col='0;33'
      else                                col='0;32'
      fi
      if [ "$CACHE_STYLE" = clock ]; then
        # BSD/macOS date takes -r EPOCH; GNU reads -r as a file and fails
        # over to -d @EPOCH.
        txt=$(date -r "${pc_exp%.*}" +"$CACHE_FORMAT" 2>/dev/null \
           || date -d "@${pc_exp%.*}" +"$CACHE_FORMAT" 2>/dev/null)
      else
        # Expand the tokens in one left-to-right pass, so "%%" stays a
        # literal and a substituted value is never re-scanned.
        txt=$(awk -v f="$CACHE_FORMAT" -v t="$left" 'BEGIN {
          m = int(t / 60); s = t % 60; out = ""
          for (i = 1; i <= length(f); i++) {
            c = substr(f, i, 1)
            if (c != "%" || i == length(f)) { out = out c; continue }
            d = substr(f, ++i, 1)
            if      (d == "m") out = out m
            else if (d == "M") out = out sprintf("%02d", m)
            else if (d == "s") out = out sprintf("%02d", s)
            else if (d == "t") out = out t
            else if (d == "%") out = out "%"
            else               out = out "%" d
          }
          printf "%s", out }')
      fi
      cache_info=$(printf " | cache:\033[%sm%s\033[0m" "$col" "$txt")
    else
      # Cold. Add the re-cache cost when Claude Code knows it (null right
      # after a compaction, until the next request).
      cost=""
      pc_recache=${pc_recache%.*}
      if [ "${pc_recache:-0}" -gt 0 ] 2>/dev/null; then
        cost=$(awk -v n="$pc_recache" 'BEGIN {
          if (n >= 1000000) printf " %.1fM", n / 1000000
          else if (n >= 1000) printf " %dk", int(n / 1000 + 0.5)
          else printf " %d", n }')
      fi
      cache_info=$(printf " | cache:\033[0;36mcold%s\033[0m" "$cost")
    fi
  fi
fi

# Model info, with the reasoning effort in parentheses: "Opus 5.5 (medium)".
# With the model hidden, effort stands alone as "effort:medium".
model_info=""
if [ "$SHOW_MODEL" = 1 ] && [ -n "$model" ]; then
  model_info=" | $model"
  [ "$SHOW_EFFORT" = 1 ] && [ -n "$effort" ] && model_info="$model_info ($effort)"
elif [ "$SHOW_EFFORT" = 1 ] && [ -n "$effort" ]; then
  model_info=" | effort:$effort"
fi

# PR link (OSC 8 hyperlink if URL available, plain number otherwise).
# Rendered right after the branch with no separator, so the git items read
# as one group: "~/repo [main *] #7 | Opus …".
pr_info=""
if [ "$SHOW_PR" = 1 ] && [ -n "$pr_number" ]; then
  if [ -n "$pr_url" ]; then
    pr_info=$(printf " \033]8;;%s\a#%s\033]8;;\a" "$pr_url" "$pr_number")
  else
    pr_info=" #$pr_number"
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
# Which account? Prefer the explicit config dir, else derive it from the
# transcript path (<config_dir>/projects/...), else let the helper self-resolve.
config_dir="${CLAUDE_CONFIG_DIR:-}"
if [ -z "$config_dir" ] && [ -n "$transcript" ]; then
  case "$transcript" in */projects/*) config_dir=${transcript%%/projects/*} ;; esac
fi

# The 5h reset countdown is its own toggle, passed through as --show-reset.
show_reset=true
[ "$SHOW_RESET" = 0 ] && show_reset=false

# Same deal for the seat label — except it travels as an ENV var, not a
# flag. claude-usage defaults the label OFF (it's an opt-in bridge to a
# second tool); the statusline is the consumer that wants it on, so it asks
# for it here. Env rather than --show-profile so a statusline paired with an
# older claude-usage keeps working: an unknown env var is ignored, whereas
# an unknown flag would exit 1 and take the whole usage segment with it.
# (claude-usage's own config file still wins over this, by its documented
# flags > config > env precedence.)
show_profile=false
[ "$SHOW_PROFILE" = 1 ] && show_profile=true
# Daily budget: env for the same reason (older claude-usage ignores it).
show_budget=false
[ "$SHOW_BUDGET" = 1 ] && show_budget=true

usage_seg() {
  command -v zsh >/dev/null 2>&1 || return 0
  # claude-usage.zsh ships as its own repo (github.com/deviationist/claude-usage).
  # Locate it, in order: $CLAUDE_USAGE_SCRIPT override → a sibling clone next
  # to this repo (../claude-usage/) → same dir (legacy single-repo layout).
  # Not found: the usage segment is simply skipped.
  _us="${CLAUDE_USAGE_SCRIPT:-}"
  if [ -z "$_us" ]; then
    _sd=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    for _cand in "$_sd/../claude-usage/claude-usage.zsh" "$_sd/claude-usage.zsh"; do
      [ -f "$_cand" ] && { _us="$_cand"; break; }
    done
  fi
  [ -n "$_us" ] || return 0
  CLAUDE_USAGE_BAR_WIDTH="$USAGE_BAR_WIDTH" \
  CLAUDE_USAGE_SHOW_PROFILE="$show_profile" \
  CLAUDE_USAGE_SHOW_DAILY_BUDGET="$show_budget" zsh -c '
    source "$4" 2>/dev/null || exit 0
    args=( --pretty --sep "$2" --show-reset="$3" --no-block )
    [[ -n "$1" ]] && args=( --dir "$1" "${args[@]}" )
    claude-usage "${args[@]}" 2>/dev/null
  ' _ "$config_dir" "$USAGE_SEP" "$show_reset" "$_us"
}
# Memoised for USAGE_TTL seconds, keyed on everything that shapes the output.
# This sits on top of claude-usage's own cache, which --no-block only reads
# (refreshing it in the background), so the memo adds at most USAGE_TTL of
# lag. An empty result (cache not warm yet) is retried after 5 s.
usage_info=""
if [ "$SHOW_USAGE" = 1 ]; then
  memo usage "$USAGE_TTL" 5 \
    "$config_dir|$show_reset|$show_profile|$show_budget|$USAGE_BAR_WIDTH|$USAGE_SEP|${CLAUDE_USAGE_SCRIPT:-}" \
    usage_seg
  [ -n "$memo_out" ] && usage_info=" | $memo_out"
fi

printf "%s\033[33m%s\033[0m" "$host_info" "$short_cwd"
printf "%s\033[0m%s%s%s%s%s" "$git_branch" "$pr_info" "$model_info" "$ctx_info" "$cache_info" "$usage_info"

memo_prune
