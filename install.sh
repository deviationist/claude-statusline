#!/bin/sh
# ============================================================================
# install.sh — set up claude-statusline (+ claude-usage) for Claude Code
# ============================================================================
# Safe to re-run: every step checks first and skips what is already done.
# Nothing is overwritten without a backup, and a choice you already made
# (a segment toggle, a /sl command of your own) is left alone.
#
#   ./install.sh --dry-run     # show what would change, change nothing
#   ./install.sh               # recommended setup (below)
#   ./install.sh --minimal     # plain defaults: no budget/cache, 60 s repaint
#
# The recommended setup is what the author runs day to day:
#   - statusLine in settings.json, repainting every second (refreshInterval 1),
#     so the cache countdown ticks; cheap, because the slow segments are cached
#   - `budget` and `cache` segments on (both are off by default)
#   - the /sl slash command linked into the config dir
#   - claude-usage cloned next to this repo (for the usage bars)
#   - both shell helpers sourced from ~/.zshrc
#
# Options:
#   --config-dir DIR   Claude Code config dir to set up (repeatable). Default:
#                      every profile dir in claude-profile's config if that
#                      exists, else $CLAUDE_CONFIG_DIR, else ~/.claude
#   --minimal          plain defaults instead of the recommended setup
#   --no-usage         don't clone claude-usage (no usage bars)
#   --no-shell         don't touch ~/.zshrc
#   --dry-run          print the plan, change nothing
#   -h, --help         this help
#
# Requirements: zsh, jq, curl (+ git to clone claude-usage).
set -eu

REPO=$(cd "$(dirname "$0")" && pwd -P)
USAGE_DIR="$(dirname "$REPO")/claude-usage"
USAGE_URL="https://github.com/deviationist/claude-usage.git"

minimal=0 no_usage=0 no_shell=0 dry=0 dirs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir)   [ $# -ge 2 ] || { echo "install.sh: --config-dir needs a path" >&2; exit 2; }
                    dirs="$dirs$2
"; shift ;;
    --config-dir=*) dirs="$dirs${1#--config-dir=}
" ;;
    --minimal)  minimal=1 ;;
    --no-usage) no_usage=1 ;;
    --no-shell) no_shell=1 ;;
    --dry-run)  dry=1 ;;
    -h|--help)  sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ok      %s\n' "$*"; }
skip() { printf '  skip    %s\n' "$*"; }
todo() { if [ "$dry" = 1 ]; then printf '  would   %s\n' "$*"; else printf '  done    %s\n' "$*"; fi; }
warn() { printf '  \033[33mwarn\033[0m    %s\n' "$*"; }
# ~/… for display and for lines written into ~/.zshrc
tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
nl='
'
# The rc file plus the files it sources directly (one level deep), so helpers
# loaded through e.g. `source ~/.zsh/index.zsh` count as sourced too.
rc_files() {
  [ -f "$rc" ] || return 0
  printf '%s\n' "$rc"
  sed -nE 's/^[[:space:]]*(source|\.)[[:space:]]+//p' "$rc" | while IFS= read -r p; do
    case "$p" in
      \"*) p=${p#\"}; p=${p%%\"*} ;;
      \'*) p=${p#\'}; p=${p%%\'*} ;;
      *)   p=${p%%[[:space:]]*} ;;
    esac
    case "$p" in
      "~/"*)       p="$HOME/${p#"~/"}" ;;
      '$HOME/'*)   p="$HOME/${p#'$HOME/'}" ;;
      '${HOME}/'*) p="$HOME/${p#'${HOME}/'}" ;;
    esac
    [ "$p" != "$rc" ] && [ -f "$p" ] && printf '%s\n' "$p"
  done
  return 0
}
# Is FILE already sourced from the rc file, or from a file it sources? Matches
# the path as written absolute, as ~/… or as $HOME/…, and sets $found_in.
sourced() {
  t=$(tilde "$1"); h=$(printf '%s' "$t" | sed 's|^~|$HOME|')
  _files=$(rc_files)
  _ifs=$IFS; IFS=$nl
  for _f in $_files; do
    if grep -qF -e "$1" -e "$t" -e "$h" "$_f" 2>/dev/null; then
      IFS=$_ifs; found_in=$_f; return 0
    fi
  done
  IFS=$_ifs
  return 1
}
expand() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;; *) printf '%s' "$1" ;; esac; }

[ "$dry" = 1 ] && say "Dry run: nothing will be changed."

# --- requirements -----------------------------------------------------------
step "Requirements"
missing=""
for c in zsh jq curl; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else missing="$missing $c"; fi
done
if [ -n "$missing" ]; then
  say "  missing:$missing"
  say "  macOS: brew install$missing    Debian/Ubuntu: sudo apt install$missing"
  exit 1
fi

# --- config dirs ------------------------------------------------------------
if [ -z "$dirs" ]; then
  cp_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-profile/config.json"
  if [ -f "$cp_cfg" ] && jq -e '.profiles | length > 0' "$cp_cfg" >/dev/null 2>&1; then
    dirs=$(jq -r '.profiles[].dir' "$cp_cfg")
    dirs_from="claude-profile's profiles"
  else
    dirs="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    dirs_from="${CLAUDE_CONFIG_DIR:+\$CLAUDE_CONFIG_DIR}"
    dirs_from="${dirs_from:-the default}"
  fi
else
  dirs_from="--config-dir"
fi

if [ "$minimal" = 1 ]; then refresh=60; else refresh=1; fi
cmd="bash $REPO/statusline-command.sh"

# --- claude-usage -----------------------------------------------------------
step "claude-usage (usage bars)"
if [ "$no_usage" = 1 ]; then
  skip "--no-usage: the statusline works without it, minus the usage bars"
elif [ -f "$USAGE_DIR/claude-usage.zsh" ]; then
  ok "found at $(tilde "$USAGE_DIR")"
elif [ -e "$USAGE_DIR" ]; then
  warn "$(tilde "$USAGE_DIR") exists but has no claude-usage.zsh; leaving it alone"
  no_usage=1
else
  command -v git >/dev/null 2>&1 || { say "  git is needed to clone claude-usage (or pass --no-usage)"; exit 1; }
  todo "clone $USAGE_URL → $(tilde "$USAGE_DIR")"
  [ "$dry" = 1 ] || git clone -q "$USAGE_URL" "$USAGE_DIR"
fi

# --- per config dir: settings.json + /sl ------------------------------------
old_ifs=$IFS; IFS=$nl
for d in $dirs; do
  IFS=$old_ifs
  d=$(expand "$d")
  step "Claude Code config dir $(tilde "$d")  (from $dirs_from)"
  f="$d/settings.json"

  # settings.json → statusLine
  if [ -f "$f" ] && ! jq -e . "$f" >/dev/null 2>&1; then
    warn "$(tilde "$f") isn't valid JSON; fix it and re-run (left unchanged)"
  elif [ -f "$f" ] && [ "$(jq -r '.statusLine.command // ""' "$f")" = "$cmd" ]; then
    ok "statusLine already points here (refreshInterval $(jq -r '.statusLine.refreshInterval // "unset"' "$f"); kept)"
  else
    prev=""
    [ -f "$f" ] && prev=$(jq -r '.statusLine.command // ""' "$f")
    [ -n "$prev" ] && warn "replacing the existing statusLine: $prev"
    todo "set statusLine in $(tilde "$f") (refreshInterval $refresh)"
    if [ "$dry" = 0 ]; then
      mkdir -p "$d"
      if [ -f "$f" ]; then
        bak="$f.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$f" "$bak"
        say "          backup: $(tilde "$bak")"
        src="$f"
      else
        src=/dev/null
      fi
      tmp=$(mktemp "${TMPDIR:-/tmp}/statusline-settings.XXXXXX")
      { [ "$src" = /dev/null ] && echo '{}' || cat "$src"; } \
        | jq --arg c "$cmd" --argjson r "$refresh" \
             '.statusLine = {type: "command", command: $c, refreshInterval: $r}' > "$tmp"
      cat "$tmp" > "$f"   # write through, so a symlinked settings.json stays a symlink
      rm -f "$tmp"
    fi
  fi

  # /sl slash command
  link="$d/commands/sl.md"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$REPO/commands/sl.md" ]; then
    ok "/sl already linked"
  elif [ -e "$link" ] || [ -L "$link" ]; then
    warn "$(tilde "$link") already exists and isn't ours; left alone"
  else
    todo "link /sl → $(tilde "$link")"
    [ "$dry" = 1 ] || { mkdir -p "$d/commands"; ln -s "$REPO/commands/sl.md" "$link"; }
  fi
done
IFS=$old_ifs

# --- segment toggles --------------------------------------------------------
step "Segments"
cfg="${CLAUDE_STATUSLINE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/config}"
if [ "$minimal" = 1 ]; then
  skip "--minimal: budget and cache stay off (switch on any time: statusline <seg> on)"
else
  for seg in budget cache; do
    var="CLAUDE_STATUSLINE_$(printf '%s' "$seg" | tr '[:lower:]' '[:upper:]')"
    if [ -f "$cfg" ] && grep -q "^$var=" "$cfg"; then
      ok "$seg already set in $(tilde "$cfg") ($(grep "^$var=" "$cfg" | tail -1 | cut -d= -f2); kept)"
    else
      todo "turn on $seg"
      [ "$dry" = 1 ] || zsh -fc "source '$REPO/statusline.zsh' && statusline $seg on" >/dev/null
    fi
  done
fi

# --- ~/.zshrc ---------------------------------------------------------------
step "Shell helpers (statusline, claude-usage commands)"
rc="${ZDOTDIR:-$HOME}/.zshrc"
if [ "$no_shell" = 1 ]; then
  skip "--no-shell; add these yourself:"
  say "          source \"$(tilde "$REPO")/statusline.zsh\""
  [ "$no_usage" = 1 ] || say "          source \"$(tilde "$USAGE_DIR")/claude-usage.zsh\""
else
  add=""
  if sourced "$REPO/statusline.zsh"; then
    ok "statusline.zsh already sourced in $(tilde "$found_in")"
  else
    add="${add}source \"$(tilde "$REPO" | sed 's|^~|$HOME|')/statusline.zsh\"
"
  fi
  if [ "$no_usage" = 0 ]; then
    if sourced "$USAGE_DIR/claude-usage.zsh"; then
      ok "claude-usage.zsh already sourced in $(tilde "$found_in")"
    else
      add="${add}source \"$(tilde "$USAGE_DIR" | sed 's|^~|$HOME|')/claude-usage.zsh\"
"
    fi
  fi
  if [ -n "$add" ]; then
    todo "append to $(tilde "$rc"):"
    printf '%s' "$add" | sed 's/^/            /'
    [ "$dry" = 1 ] || printf '\n# claude-statusline + claude-usage (added by install.sh)\n%s' "$add" >> "$rc"
  fi
fi

# --- done -------------------------------------------------------------------
step "Next"
if [ "$dry" = 1 ]; then
  say "  Re-run without --dry-run to apply."
else
  say "  - Restart open Claude Code sessions (settings.json is read at start)."
  say "  - Open a new shell for the \`statusline\` and \`claude-usage\` commands."
  say "  - The usage bars appear once the first fetch is cached (a few seconds)."
  say "  - Toggle segments with \`statusline <seg> on|off\` or /sl in Claude Code."
fi
