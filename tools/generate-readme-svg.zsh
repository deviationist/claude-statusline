#!/usr/bin/env zsh
# ---------------------------------------------------------------------------
# tools/generate-readme-svg.zsh — regenerate the README hero + segments SVGs.
#
# Renders the REAL status line into SVG terminal windows: builds a hermetic
# sandbox (fake $HOME, a throwaway git repo, seeded claude-usage caches — no
# network, no credentials, no touching your own config), pipes Claude Code's
# statusline JSON into statusline-command.sh **unmodified**, and converts the
# ANSI/SGR colours of what comes back into <tspan fill="…"> runs. The status
# line rows in the images are therefore genuine renderer output, not art.
# (Only the window chrome around them — title bar, the mocked-up Claude Code
# conversation and input box — is drawn.)
#
# Sibling of claude-usage's tools/generate-readme-svg.zsh, from which the
# ANSI→SVG core here is borrowed; keep the two roughly in sync.
#
# Usage:  zsh tools/generate-readme-svg.zsh
#           → assets/statusline-<hash>.svg + assets/segments-<hash>.svg,
#             older ones deleted, README <img> references rewritten (the
#             random hash busts GitHub's camo image cache). Commit all three.
#         zsh tools/generate-readme-svg.zsh HERO.svg SEGMENTS.svg
#           → fixed paths, README untouched.
#
# Requires the companion claude-usage repo (sibling clone, or point
# $CLAUDE_USAGE_SCRIPT at claude-usage.zsh) — the usage bars are its output.
# Regenerate whenever the segments, colours, or claude-usage renderers change.
# Countdown values ("3d20h") are seeded stable; the monthly reset date
# ("Sep 1") tracks the month you run it in — fine for a demo.
# ---------------------------------------------------------------------------
emulate -L zsh
setopt extended_glob

here=${0:a:h}
root=${here:h}

usage_script="${CLAUDE_USAGE_SCRIPT:-$root/../claude-usage/claude-usage.zsh}"
if [[ ! -f $usage_script ]]; then
  print -u2 "generate-readme-svg: claude-usage.zsh not found at $usage_script"
  print -u2 "  clone it as a sibling of this repo, or set \$CLAUDE_USAGE_SCRIPT"
  exit 1
fi
usage_script=${usage_script:a}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp/"                       # where claude-usage keeps its cache

# ---- hermetic sandbox ------------------------------------------------------
# Fake $HOME so the cwd segment shortens to a presentable "~/code/app", and so
# nothing reads (or writes) the operator's real dotfiles.
fakehome="$tmp/home"
repo="$fakehome/code/app"
mkdir -p "$repo"
git init -q "$repo"
git -C "$repo" symbolic-ref HEAD refs/heads/main      # branch without a commit
print -r -- '# app' > "$repo/README.md"               # → the dirty marker "*"

# Linux-only segments (the hostname prefix) need a Linux-shaped environment.
# The status line script itself runs unmodified; only `uname`/`hostname` are
# shimmed on PATH for the one row that demonstrates an SSH session.
mkdir -p "$tmp/bin"
print '#!/bin/sh\n[ "$1" = -s ] && { echo Linux; exit 0; }\nexec /usr/bin/uname "$@"' > "$tmp/bin/uname"
print '#!/bin/sh\necho xavi' > "$tmp/bin/hostname"
chmod +x "$tmp/bin/uname" "$tmp/bin/hostname"

# ---- seed demo accounts ----------------------------------------------------
# Same trick as claude-usage's generator: drop a cache file where claude-usage
# looks for one, so --no-block serves it without a fetch. Cache key is the
# config dir's basename, so "$tmp/max" ↔ claude-oauth-usage.max.json.
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null \
        || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S+00:00 }
now=$(date +%s)
wk=$(iso $(( now + 3*86400 + 20*3600 + 30*60 )))   # → "3d20h"
ss=$(iso $(( now + 1*3600 +  8*60 + 30 )))   # → "1h8m"

seed() { mkdir -p "$tmp/$1"; print -r -- "$2" > "$TMPDIR/claude-oauth-usage.$1.json" }

# Percentages picked to show all three fill colours (green <70, amber <90, red)
seed max '{"limits":[
  {"kind":"weekly_all","percent":34,"severity":"normal","resets_at":"'$wk'"},
  {"kind":"weekly_scoped","percent":76,"severity":"normal","resets_at":"'$wk'","scope":{"model":{"display_name":"Opus"}}},
  {"kind":"session","percent":49,"severity":"normal","resets_at":"'$ss'"}]}'
seed combo '{"spend":{"enabled":true,"used":{"amount_minor":1250,"exponent":2},
  "limit":{"amount_minor":4000,"exponent":2},"percent":31},
 "limits":[
  {"kind":"weekly_all","percent":53,"severity":"normal","resets_at":"'$wk'"},
  {"kind":"session","percent":93,"severity":"normal","resets_at":"'$ss'"}]}'
seed work '{"spend":{"enabled":true,"used":{"amount_minor":14250,"exponent":2},
  "limit":{"amount_minor":30000,"exponent":2},"percent":47.5}}'

# The seat label ("Personal (Max 5x)") normally comes from the claude-profile
# juggler. We don't want a hard dependency on a third repo just to draw a
# picture, so its answer is seeded straight into claude-usage's label sidecar
# — the same file a real lookup would have written. Re-seeded before every
# render because a --no-block read also kicks off a detached refresh that,
# with no juggler reachable, empties the sidecar behind us.
seed_label() { print -rn -- "$2" > "$TMPDIR/claude-oauth-usage.$1.json.label" }

# ---- render ----------------------------------------------------------------
# One status line row, straight out of statusline-command.sh.
#   render <account> <model> <ctx%> <pr#|-> [config lines…]
# Extra args become the per-machine config the `statusline` helper would have
# written (CLAUDE_STATUSLINE_MODEL=0 etc.), so the toggles shown in the
# gallery are the real thing.
render() {
  local acct=$1 model=$2 ctx=$3 pr=$4; shift 4
  local cfg="$tmp/statusline-config"
  print -rl -- "$@" > "$cfg"
  seed_label "$acct" "$LABEL"

  local pr_json='null'
  [[ $pr != - ]] && pr_json="{\"number\":$pr,\"url\":\"https://github.com/deviationist/claude-statusline/pull/$pr\"}"

  jq -nc --arg dir "$repo" --arg model "$model" --argjson ctx "$ctx" \
         --argjson pr "$pr_json" --arg tr "$tmp/$acct/projects/-code-app/session.jsonl" \
    '{workspace:{current_dir:$dir},model:{display_name:$model},
      context_window:{used_percentage:$ctx},transcript_path:$tr}
     + (if $pr == null then {} else {pr:$pr} end)' \
  | env -i PATH="$PATH_EXTRA$PATH" HOME="$fakehome" TERM=xterm-256color \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
        TMPDIR="$TMPDIR" \
        CLAUDE_STATUSLINE_CONFIG="$cfg" \
        CLAUDE_USAGE_SCRIPT="$usage_script" \
        CLAUDE_USAGE_CONFIG="$tmp/no-such-config" \
        CLAUDE_PROFILE_SCRIPT="$tmp/no-such-profile" \
        bash "$root/statusline-command.sh"
}
LABEL=''          # no seat label unless a variant asks for one
PATH_EXTRA=''     # no uname/hostname shim unless a variant asks for one

# ---- ANSI → SVG ------------------------------------------------------------
# Catppuccin Mocha chrome; ANSI 30–37/90–97 rendered with the iTerm2 "Default"
# profile palette (as claude-usage's generator does), so the colours match a
# common real terminal. 256/truecolor SGRs convert exactly.
BG='#1e1e2e'  BAR='#181825'  FG='#cdd6f4'  DIMC='#9399b2'  BOXC='#45475a'
DOT1='#f38ba8' DOT2='#f9e2af' DOT3='#a6e3a1'
FONT="'Cascadia Code','Fira Code',SFMono-Regular,Consolas,Menlo,monospace"
integer FS=13 LH=20 TH=30 PX=20 PY=14
# Breathing room on the right of the frame — the last glyph on a row may be
# drawn a touch wider than the cell it is pinned to (see xrun below).
integer SLACK=24

# Terminal grid: every character is pinned to its own cell with a per-glyph x
# list, so a row occupies exactly (columns × cw) whichever font the renderer
# falls back to. That is what keeps the bars aligned and the frame honest
# everywhere: sizing the frame alone doesn't, because the bar glyphs ▕█░▏ are
# drawn wider than a cell in many fallback fonts, and the longest row then
# runs off the edge of the picture.
typeset -a XCOL
build_xcols() {
  local -F cw=7.85                        # ~monospace advance at 13px
  integer k; local v
  for (( k = 0; k <= 400; k++ )); do printf -v v '%.2f' $(( PX + k * cw )); XCOL[k+1]=$v; done
}
build_xcols
# x-attribute value for a run of <len> chars starting at column <col>
xrun() { print -rn -- "${(j: :)XCOL[$1+1,$1+$2]}" }

typeset -a ANSI_N ANSI_B
ANSI_N=('#000000' '#b43c2a' '#00c200' '#c7c400' '#0225c7' '#ca30c7' '#00c5c7' '#c7c7c7')
ANSI_B=('#686868' '#dd7975' '#58e790' '#ece100' '#6871ff' '#ff77ff' '#60fdff' '#ffffff')

xesc() { local s=$1; s=${s//\&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; print -rn -- "$s" }

# Visible length: strip CSI (…m) and OSC 8 hyperlink wrappers
vlen() {
  local s=$1
  s=${s//$'\e['[0-9;]#m/}
  s=${s//$'\e]'[^$'\a']#$'\a'/}
  print -rn -- ${#s}
}

# One ANSI line → tspan runs (default colour inherits from the <text>).
# Carries SGR state across the line: bold/dim + colour index, or an explicit
# 256/truecolor fill. OSC 8 hyperlinks (the PR segment) are unwrapped to their
# label text — an <img>-embedded SVG can't be clicked anyway.
render_ansi() {
  local s=$1 out="" pre tail params body p
  integer col=0
  local fill="" explicit="" cidx="" bold=0 dim=0
  local -a c
  recompute() {
    if [[ -n $explicit ]]; then fill=$explicit
    elif [[ -n $cidx ]]; then (( bold )) && fill=$ANSI_B[cidx+1] || fill=$ANSI_N[cidx+1]
    elif (( dim )); then fill=$DIMC
    else fill=""; fi
  }
  while [[ -n $s ]]; do
    pre=${s%%$'\e'*}
    if [[ -n $pre ]]; then
      out+="<tspan x=\"$(xrun col ${#pre})\"${fill:+ fill=\"$fill\"}>$(xesc "$pre")</tspan>"
      (( col += ${#pre} ))
    fi
    s=${s[$(( ${#pre} + 1 )),-1]}
    [[ -n $s ]] || break
    case ${s[2]} in
      '[')                                              # CSI … m (SGR)
        tail=${s#$'\e['}; params=${tail%%m*}
        s=${tail[$(( ${#params} + 2 )),-1]}
        c=(${(s:;:)params}); (( ${#c} )) || c=(0)
        integer i=1
        while (( i <= ${#c} )); do
          p=$c[i]
          case $p in
            0|'')  explicit=""; cidx=""; bold=0; dim=0 ;;
            1)     bold=1 ;;
            2)     dim=1 ;;
            22)    bold=0; dim=0 ;;
            39)    cidx=""; explicit="" ;;
            <30-37>) cidx=$(( p - 30 )); explicit="" ;;
            <90-97>) cidx=$(( p - 90 )); bold=1; explicit="" ;;
            38)
              if [[ $c[i+1] == 2 ]]; then
                explicit=$(printf '#%02x%02x%02x' $c[i+2] $c[i+3] $c[i+4]); (( i += 4 ))
              elif [[ $c[i+1] == 5 ]]; then
                explicit=$(xterm256 $c[i+2]); (( i += 2 ))
              fi
              cidx="" ;;
          esac
          (( i++ ))
        done
        recompute ;;
      ']')                                              # OSC (8 = hyperlink)
        tail=${s#$'\e]'}; body=${tail%%$'\a'*}
        s=${tail[$(( ${#body} + 2 )),-1]} ;;
      *) s=${s[3,-1]} ;;                                # unknown ESC x — drop
    esac
  done
  print -rn -- "$out"
}

xterm256() {
  integer n=$1 r g b i
  if (( n >= 232 )); then
    (( r = 8 + 10 * (n - 232) )); printf '#%02x%02x%02x' $r $r $r
  elif (( n >= 16 )); then
    (( i = n - 16 ))
    (( r = i / 36 )); (( g = (i % 36) / 6 )); (( b = i % 6 ))
    (( r = r ? 55 + 40 * r : 0 )); (( g = g ? 55 + 40 * g : 0 )); (( b = b ? 55 + 40 * b : 0 ))
    printf '#%02x%02x%02x' $r $g $b
  elif (( n >= 8 )); then print -rn -- $ANSI_B[n-7]
  else print -rn -- $ANSI_N[n+1]; fi
}

# ---- generic emitter -------------------------------------------------------
# emit_svg <lines-array-name> <out-file> [title]
# Each entry: TYPE|content — b=blank, c=dim, t=plain, a=ANSI, u=input row.
# $BOX_ROWS=(first last) draws Claude Code's input frame behind those rows
# (0-based); unset for none.
emit_svg() {
  local -a _lines=("${(@P)1}")
  local out=$2 title=${3:-claude-statusline} entry typ body
  integer maxcols=0 n
  for entry in "${_lines[@]}"; do
    typ=${entry%%\|*}; body=${entry#*\|}
    n=$(vlen "$body"); [[ $typ == u ]] && (( n += 2 ))
    (( n > maxcols )) && maxcols=$n
  done
  local -F cw=7.85                         # ~monospace advance at 13px
  integer W=$(( PX * 2 + maxcols * cw + 6 + SLACK ))
  integer H=$(( TH + PY + ${#_lines} * LH + PY ))
  {
    print -r -- "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$W\" height=\"$H\" viewBox=\"0 0 $W $H\" role=\"img\" aria-label=\"claude-statusline example output\">"
    print -r -- "  <rect width=\"$W\" height=\"$H\" rx=\"10\" fill=\"$BG\"/>"
    print -r -- "  <rect width=\"$W\" height=\"$TH\" rx=\"10\" fill=\"$BAR\"/>"
    print -r -- "  <rect y=\"$(( TH - 6 ))\" width=\"$W\" height=\"6\" fill=\"$BAR\"/>"
    print -r -- "  <circle cx=\"18\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT1\"/><circle cx=\"36\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT2\"/><circle cx=\"54\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT3\"/>"
    print -r -- "  <text x=\"$(( W / 2 ))\" y=\"$(( TH / 2 + 5 ))\" text-anchor=\"middle\" font-family=\"$FONT\" font-size=\"12\" fill=\"$DIMC\">$(xesc "$title")</text>"
    if (( ${#BOX_ROWS} == 2 )); then
      # Rows sit on their baseline, so the frame has to clear the ascenders
      # above the first row AND the descenders below the last one — otherwise
      # its bottom edge lands on top of whatever the next row draws.
      integer by=$(( TH + PY + BOX_ROWS[1] * LH - 4 ))
      integer bh=$(( (BOX_ROWS[2] - BOX_ROWS[1] + 1) * LH + 8 ))
      print -r -- "  <rect x=\"$(( PX - 10 ))\" y=\"$by\" width=\"$(( W - 2 * (PX - 10) ))\" height=\"$bh\" rx=\"6\" fill=\"none\" stroke=\"$BOXC\" stroke-width=\"1\"/>"
    fi
    integer i=0 y
    for entry in "${_lines[@]}"; do
      typ=${entry%%\|*}; body=${entry#*\|}
      y=$(( TH + PY + i * LH + FS ))
      case $typ in
        b) ;;
        c) print -r -- "  <text x=\"$PX\" y=\"$y\" font-family=\"$FONT\" font-size=\"$FS\" xml:space=\"preserve\" fill=\"$DIMC\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>" ;;
        t) print -r -- "  <text x=\"$PX\" y=\"$y\" font-family=\"$FONT\" font-size=\"$FS\" xml:space=\"preserve\" fill=\"$FG\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>" ;;
        u) print -r -- "  <text x=\"$PX\" y=\"$y\" font-family=\"$FONT\" font-size=\"$FS\" xml:space=\"preserve\" fill=\"$FG\"><tspan x=\"$XCOL[1]\" fill=\"$DIMC\">&gt;</tspan><tspan x=\"$(xrun 2 ${#body})\">$(xesc "$body")</tspan></text>" ;;
        a) print -r -- "  <text x=\"$PX\" y=\"$y\" font-family=\"$FONT\" font-size=\"$FS\" xml:space=\"preserve\" fill=\"$FG\">$(render_ansi "$body")</text>" ;;
      esac
      (( i++ ))
    done
    print -r -- "</svg>"
  } > "$out"
}

# ---- hero: the status line where you actually see it -----------------------
# A mocked-up Claude Code session (chrome, drawn) whose last row is the real
# status line (genuine output) — exactly where Claude Code paints it: under
# the input box.
LABEL='Personal (Max 5x)'
hero_status=$(render max "Opus 5" 42 7)
LABEL=''

hero_lines=(
  'c|> how much of my weekly limit is left?'
  'b|'
  't|⏺ Look down — the status line has it: 34% of the 7-day window, 76% of the'
  't|  Opus slice, and the 5h session at 49%, resetting in 1h8m. Those numbers'
  't|  are Anthropic'"'"'s own, for the whole account — not this box'"'"'s transcripts.'
  'b|'
  'u|'
  'b|'
  "a|$hero_status"
)
typeset -a BOX_ROWS=(6 6)

# ---- gallery: one row per plan shape / toggle combination ------------------
LABEL='Personal (Max 5x)'
g_profile=$(render max "Opus 5" 42 -)
LABEL=''
g_max=$(render   max   "Opus 5"   42 7)
g_work=$(render  work  "Sonnet 5" 12 -)
g_combo=$(render combo "Fable 5"  63 -)
g_slim=$(render  max   "Opus 5"   42 - \
  'CLAUDE_STATUSLINE_MODEL=0' 'CLAUDE_STATUSLINE_CTX=0' 'CLAUDE_STATUSLINE_BAR_WIDTH=5')
g_local=$(render max   "Opus 5"   42 7 'CLAUDE_STATUSLINE_USAGE=0')
PATH_EXTRA="$tmp/bin:"
g_host=$(render  max   "Opus 5"   42 7)
PATH_EXTRA=''

segments_lines=(
  'c|# every segment is togglable, live:  statusline <seg> on|off|toggle'
  'b|'
  'c|# Max / Pro seat — the 7d, per-model and 5h windows, each with its reset'
  "a|$g_max"
  'b|'
  'c|# USD-budget seat — monthly spend against the cap, and when it rolls over'
  "a|$g_work"
  'b|'
  'c|# Max seat + usage credits — the credit group leads, then the plan windows'
  "a|$g_combo"
  'b|'
  'c|# which subscription is this session burning?  (statusline profile on)'
  "a|$g_profile"
  'b|'
  'c|# on a remote box over SSH — hostname prefix, plus the PR the branch is on'
  "a|$g_host"
  'b|'
  'c|# pared back:  statusline model off · statusline ctx off · BAR_WIDTH=5'
  "a|$g_slim"
  'b|'
  'c|# statusline usage off — just the local bits'
  "a|$g_local"
)

# ---- write -----------------------------------------------------------------
if [[ -n ${1:-} ]]; then
  emit_svg hero_lines "$1" 'Claude Code'
  print "wrote $1"
  if [[ -n ${2:-} ]]; then
    BOX_ROWS=()
    emit_svg segments_lines "$2"
    print "wrote $2"
  fi
else
  mkdir -p "$root/assets"
  local old
  for old in "$root"/assets/statusline-*.svg(N) "$root"/assets/segments-*.svg(N); do rm -f "$old"; done
  local hash; hash=$(xxd -l3 -p /dev/urandom)
  emit_svg hero_lines "$root/assets/statusline-${hash}.svg" 'Claude Code'
  BOX_ROWS=()
  emit_svg segments_lines "$root/assets/segments-${hash}.svg"
  sed -i.bak \
    -e "s|assets/statusline-[^)\"]*\.svg|assets/statusline-${hash}.svg|" \
    -e "s|assets/segments-[^)\"]*\.svg|assets/segments-${hash}.svg|" \
    "$root/README.md" && rm -f "$root/README.md.bak"
  print "wrote assets/{statusline,segments}-${hash}.svg and updated README.md"
fi
