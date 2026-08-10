# ============================================================================
# statusline — toggle segments of the Claude Code statusline
# ============================================================================
# Companion to statusline-command.sh (same folder). Persists per-machine
# state as plain `CLAUDE_STATUSLINE_<SEG>=0|1` lines in the config file
# (default: ${XDG_CONFIG_HOME:-~/.config}/claude-statusline/config, override
# via $CLAUDE_STATUSLINE_CONFIG), edited in place. The statusline re-sources
# the config on every repaint, so flips apply live to running Claude Code
# sessions — no restart.
#
# Install:  source this file from ~/.zshrc
#
# Usage:    statusline                      # list all segments + state
#           statusline usage off            # hide the account-usage bars
#           statusline reset toggle         # flip the 5h reset countdown
#           statusline <seg> [on|off|toggle|status]
#
# Segments: usage reset profile model ctx git pr host   (cwd is always shown)
#           `profile` is the odd one out: OFF unless switched on, since it
#           needs the companion claude-profile tool to mean anything.
#
# Also exposed as the /sl slash command in Claude Code — see commands/sl.md.
#
# Precedence in statusline-command.sh: config value (this helper) wins, then
# process-env CLAUDE_STATUSLINE_<SEG> (settings.json "env", restart-bound),
# then shown.

statusline() {
  emulate -L zsh
  local cfg="${CLAUDE_STATUSLINE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/config}"
  local -a segs=(usage reset profile model ctx git pr host)
  local -A desc=(
    usage   "account-usage bars (spend / rate limits)"
    reset   "5h-session reset countdown (inside the usage segment)"
    profile "seat label, e.g. Personal (Max 5x) — needs claude-profile"
    model   "model name"
    ctx     "context-window %"
    git     "git branch + dirty marker"
    pr      "PR number/link"
    host    "hostname prefix (Linux hosts only)"
  )
  # Unset means shown. That includes `profile`: claude-usage renders the label
  # only when claude-profile is installed and claims the session's config dir,
  # so "on" is self-disabling rather than noisy — no flip needed to get it,
  # one flip to refuse it.
  local seg="${1:-status}" action="${2:-status}"

  # Current values, one subshell pass: source the config with every toggle
  # var pre-declared empty (function-scoped, nothing leaks), read them back.
  local -A cur
  local s n v
  while read -r s v; do cur[$s]="$v"; done <<< "$(
    for s in $segs; do typeset "CLAUDE_STATUSLINE_${(U)s}="; done
    [[ -f $cfg ]] && source "$cfg" 2>/dev/null
    for s in $segs; do
      n="CLAUDE_STATUSLINE_${(U)s}"
      print -r -- "$s ${${(P)n}:-1}"
    done
  )"

  if [[ $seg == status ]]; then
    for s in $segs; do
      printf '%-7s %-3s  %s\n' "$s" \
        "$( [[ ${cur[$s]} == 0 ]] && print off || print on )" "${desc[$s]}"
    done
    return 0
  fi
  if [[ -z ${desc[$seg]} ]]; then
    print -u2 "statusline: unknown segment '$seg' (segments: $segs)"
    print -u2 "usage: statusline [<segment>] [on|off|toggle|status]"
    return 1
  fi

  local new
  case "$action" in
    on)     new=1 ;;
    off)    new=0 ;;
    toggle) if [[ ${cur[$seg]} == 0 ]]; then new=1; else new=0; fi ;;
    status) print "statusline $seg: $( [[ ${cur[$seg]} == 0 ]] && print off || print on )"
            return 0 ;;
    *)      print -u2 "usage: statusline [<segment>] [on|off|toggle|status]"; return 1 ;;
  esac

  # Persist: replace the segment's line in the config, or insert it — grouped
  # under a single header comment so repeated toggles stay tidy.
  local var="CLAUDE_STATUSLINE_${(U)seg}"
  local hdr="# claude-statusline segment toggles (statusline <seg> on|off)"
  local -a lines
  [[ -f $cfg ]] && lines=("${(@f)$(<"$cfg")}")
  local i found=0
  for (( i = 1; i <= ${#lines}; i++ )); do
    if [[ ${lines[i]} == "$var="* ]]; then
      lines[i]="$var=$new"
      found=1
    fi
  done
  if (( ! found )); then
    local hi=${lines[(ie)$hdr]}   # (ie) = index of exact match, len+1 if absent
    if (( hi <= ${#lines} )); then
      lines=( "${(@)lines[1,hi]}" "$var=$new" "${(@)lines[hi+1,-1]}" )
    else
      (( ${#lines} )) && lines+=( "" )
      lines+=( "$hdr" "$var=$new" )
    fi
  fi
  mkdir -p "${cfg:h}"
  print -rl -- "${lines[@]}" > "$cfg"
  print "statusline $seg: $( [[ $new == 0 ]] && print off || print on )"
}
