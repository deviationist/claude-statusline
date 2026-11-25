#!/bin/sh
# ---------------------------------------------------------------------------
# claude-statusline test suite: hermetic, no network, no real config touched.
#
# Every run happens under a throwaway dir: a fake $HOME, a scratch git repo,
# a private memo dir per render, and a copy of this repo next to a stub
# claude-usage (so the installer never clones anything). Each command runs
# under `env -i`, so nothing from your own environment leaks in.
#
# Run: sh test/run.sh        Needs: bash, zsh, jq, git, curl (installer check)
# ---------------------------------------------------------------------------
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

ESC=$(printf '\033'); BEL=$(printf '\007')
pass=0 fail=0 n=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() {
  fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"
  [ $# -ge 2 ] && printf '       got:  %s\n' "$2"
  [ $# -ge 3 ] && printf '       want: %s\n' "$3"
  return 0
}
check()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()    { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "contains: $3" ;; esac; }
hasnot() { case "$2" in *"$3"*) bad "$1" "$2" "doesn't contain: $3" ;; *) ok "$1" ;; esac; }
exists() { if [ -e "$2" ] || [ -L "$2" ]; then ok "$1"; else bad "$1" "missing: $2"; fi; }
gone()   { if [ -e "$2" ] || [ -L "$2" ]; then bad "$1" "still there: $2"; else ok "$1"; fi; }
# Strip colours and OSC 8 hyperlinks, leaving the text a terminal shows.
plain() { printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g; s/${ESC}]8;;[^${BEL}]*${BEL}//g"; }
old() { touch -t 202001010000 "$@"; }   # older than a day, for the cleanup
section() { printf '\n# %s\n' "$1"; }

# A copy of this repo with a stub claude-usage next to it, like a real clone.
install_copy() {   # <parent dir> → prints the copy's path
  mkdir -p "$1/claude-statusline/commands" "$1/claude-usage"
  cp "$root/install.sh" "$root/statusline-command.sh" "$root/statusline.zsh" "$1/claude-statusline/"
  cp "$root/commands/sl.md" "$1/claude-statusline/commands/"
  printf 'claude-usage() { :; }\n' > "$1/claude-usage/claude-usage.zsh"
  printf '%s' "$1/claude-statusline"
}
SL=$(install_copy "$tmp/src")
H="$tmp/home"; mkdir -p "$H"

# ---- rendering -------------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" symbolic-ref HEAD refs/heads/main
SID=11111111-2222-3333-4444-555555555555

json() {   # [pr-json]
  printf '{"session_id":"%s","cwd":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":42}%s}' \
    "$SID" "$repo" "$repo" "${1:+,\"pr\":$1}"
}
render() {   # <json> [VAR=value …] → raw status line; $rc = exit status
  _j=$1; shift
  # A fresh memo dir per render (mktemp, since a counter wouldn't survive the
  # $(…) subshell this runs in), so no render reuses another's cached segments.
  out=$(printf '%s' "$_j" | env -i PATH="$PATH" HOME="$H" TMPDIR="$tmp/" \
        CLAUDE_STATUSLINE_CONFIG="$tmp/sl-config" \
        CLAUDE_STATUSLINE_MEMO_DIR="$(mktemp -d "$tmp/memo.XXXXXX")" \
        CLAUDE_STATUSLINE_HOST=0 CLAUDE_STATUSLINE_USAGE=0 \
        "$@" bash "$root/statusline-command.sh")
  rc=$?
  printf '%s' "$out"
  return 0
}
PR_URL='{"number":7,"url":"https://example.com/pull/7"}'
PR_NUM='{"number":7}'

section "rendering"
raw=$(render "$(json "$PR_URL")")
has "PR number follows the branch" "$(plain "$raw")" "[main] #7 | Opus 5.5 | ctx:42%"
has "PR number is an OSC 8 link" "$raw" "${ESC}]8;;https://example.com/pull/7${BEL}#7${ESC}]8;;${BEL}"
has "colour is reset before the PR number" "$raw" "${ESC}[0m ${ESC}]8;;"
render "$(json "$PR_URL")" >/dev/null; check "exits 0" "$rc" 0
has "PR without a URL is plain text" "$(plain "$(render "$(json "$PR_NUM")")")" "[main] #7 | Opus 5.5"
check "git off: PR follows the cwd" \
  "$(plain "$(render "$(json "$PR_NUM")" CLAUDE_STATUSLINE_GIT=0)")" "$repo #7 | Opus 5.5 | ctx:42%"
has "no PR: model follows the branch" "$(plain "$(render "$(json)")")" "[main] | Opus 5.5"
check "pr off hides the number" \
  "$(plain "$(render "$(json "$PR_NUM")" CLAUDE_STATUSLINE_PR=0)")" "$repo [main] | Opus 5.5 | ctx:42%"
touch "$repo/untracked"
has "dirty tree gets a * marker" "$(plain "$(render "$(json)")")" "[main *]"
rm -f "$repo/untracked"
printf 'CLAUDE_STATUSLINE_MODEL=0\n' > "$tmp/sl-config"
hasnot "a toggle in the config file hides its segment" "$(plain "$(render "$(json)")")" "Opus"
rm -f "$tmp/sl-config"
hasnot "cache segment is off by default" "$(plain "$(render "$(json)")")" "cache:"

# ---- memo cleanup ------------------------------------------------------------
section "memo cleanup"
U=07d72ba7-45e1-4bcf-966f-7d446959dea6
d="$tmp/shared"; mkdir -p "$d/sub"
old "$d/$U.git" "$d/$U.host" "$d/$U.usage" "$d/$U.usage.4242" "$d/nosession.git" \
    "$d/unrelated.txt" "$d/notes.git.md" "$d/repo.git" "$d/$U.git.md" "$d/sub/$U.git"
touch "$d/fresh.txt" "$d/1898dd4b-c781-4655-b0a2-3f2298686490.usage"
render "$(json)" CLAUDE_STATUSLINE_MEMO_DIR="$d" >/dev/null
check "exits 0 after a cleanup" "$rc" 0
for f in "$U.git" "$U.host" "$U.usage" "$U.usage.4242" nosession.git; do
  gone "deletes a stale memo file: $f" "$d/$f"
done
for f in unrelated.txt notes.git.md repo.git "$U.git.md" "sub/$U.git" fresh.txt \
         1898dd4b-c781-4655-b0a2-3f2298686490.usage; do
  exists "keeps what isn't a stale memo file: $f" "$d/$f"
done
old "$d/$U.git"
render "$(json)" CLAUDE_STATUSLINE_MEMO_DIR="$d" >/dev/null
exists "runs at most once an hour" "$d/$U.git"
echo $(( $(date +%s) - 3601 )) > "$d/.pruned"
render "$(json)" CLAUDE_STATUSLINE_MEMO_DIR="$d" >/dev/null
gone "runs again once the hour has passed" "$d/$U.git"
echo 0 > "$d/.pruned"; old "$d/$U.host"; chmod 500 "$d"
render "$(json)" CLAUDE_STATUSLINE_MEMO_DIR="$d" >/dev/null
check "exits 0 when the cleanup can't delete" "$rc" 0
chmod 700 "$d"

# ---- installer -------------------------------------------------------------
section "installer"
newhome() { n=$((n + 1)); H="$tmp/home.$n"; mkdir -p "$H"; }
inst() {   # [args] → output; $rc = exit status. Runs the copy in $SL.
  out=$(env -i PATH="$PATH" HOME="$H" sh "$SL/install.sh" "$@" 2>&1)
  rc=$?
  plain "$out"
}
snapshot() {   # every file and link under $H, with its content checksum / target
  (cd "$H" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
    else printf '%s %s\n' "$f" "$(cksum < "$f")"; fi
  done)
}
cfg() { cat "$H/.config/claude-statusline/config" 2>/dev/null; }
setting() { jq -r "$1" "$H/.claude/settings.json"; }

newhome
mkdir -p "$H/.claude"
printf '{"model":"opus","statusLine":{"type":"command","command":"other.sh"}}\n' > "$H/.claude/settings.json"
printf 'export FOO=1\n' > "$H/.zshrc"
before=$(snapshot)
o=$(inst --dry-run)
check "dry run exits 0" "$rc" 0
check "dry run changes nothing" "$(snapshot)" "$before"
has "dry run says what it would do" "$o" "would   set statusLine"

o=$(inst)
check "install exits 0" "$rc" 0
check "statusLine points at the script" "$(setting .statusLine.command)" "bash $SL/statusline-command.sh"
check "refreshInterval 1 by default" "$(setting .statusLine.refreshInterval)" 1
check "other settings are kept" "$(setting .model)" opus
has "a replaced statusLine is reported" "$o" "replacing the existing statusLine: other.sh"
backups=$(ls "$H/.claude/" | grep -c '^settings\.json\.bak\.')
check "settings.json is backed up" "$backups" 1
check "/sl is linked" "$(readlink "$H/.claude/commands/sl.md")" "$SL/commands/sl.md"
has "budget is switched on" "$(cfg)" "CLAUDE_STATUSLINE_BUDGET=1"
has "cache is switched on" "$(cfg)" "CLAUDE_STATUSLINE_CACHE=1"
has "statusline.zsh is sourced from .zshrc" "$(cat "$H/.zshrc")" "source \"$SL/statusline.zsh\""
has "claude-usage.zsh is sourced from .zshrc" "$(cat "$H/.zshrc")" "source \"$tmp/src/claude-usage/claude-usage.zsh\""
has "existing .zshrc lines are kept" "$(cat "$H/.zshrc")" "export FOO=1"

before=$(snapshot)
inst >/dev/null
check "re-running changes nothing" "$(snapshot)" "$before"

newhome
mkdir -p "$H/.config/claude-statusline"
printf 'CLAUDE_STATUSLINE_CACHE=0\n' > "$H/.config/claude-statusline/config"
inst --no-shell >/dev/null
has "a segment the user switched off stays off" "$(cfg)" "CLAUDE_STATUSLINE_CACHE=0"
has "the other preset segment is still switched on" "$(cfg)" "CLAUDE_STATUSLINE_BUDGET=1"
gone "--no-shell leaves .zshrc alone" "$H/.zshrc"

newhome
inst --minimal --no-shell >/dev/null
check "--minimal: refreshInterval 60" "$(setting .statusLine.refreshInterval)" 60
check "--minimal: no segment toggles written" "$(cfg)" ""

newhome
mkdir -p "$H/.config/claude-profile"
printf '{"profiles":{"work":{"dir":"~/.claude"},"personal":{"dir":"~/My Claude"}}}\n' \
  > "$H/.config/claude-profile/config.json"
inst --no-shell >/dev/null
check "sets up every claude-profile dir" "$(setting .statusLine.refreshInterval)" 1
check "including one with a space in its path" \
  "$(jq -r .statusLine.refreshInterval "$H/My Claude/settings.json")" 1

newhome
inst --no-shell --config-dir "$H/custom" >/dev/null
exists "--config-dir picks the dir" "$H/custom/settings.json"
gone "--config-dir replaces the default" "$H/.claude"

newhome
mkdir -p "$H/.claude/commands"
printf '{oops\n' > "$H/.claude/settings.json"
printf 'my own /sl\n' > "$H/.claude/commands/sl.md"
o=$(inst --no-shell)
check "invalid settings.json: still exits 0" "$rc" 0
check "invalid settings.json is left alone" "$(cat "$H/.claude/settings.json")" "{oops"
has "invalid settings.json is reported" "$o" "isn't valid JSON"
check "a /sl of the user's own is left alone" "$(cat "$H/.claude/commands/sl.md")" "my own /sl"

# The author's layout: ~/.zshrc sources ~/.zsh/index.zsh, which sources both
# helpers, with the repos under ~/.zsh.
newhome
SL2=$(install_copy "$H/.zsh")
printf 'source ~/.zsh/index.zsh\n' > "$H/.zshrc"
printf 'source ~/.zsh/claude-usage/claude-usage.zsh\nsource "$HOME/.zsh/claude-statusline/statusline.zsh"\n' \
  > "$H/.zsh/index.zsh"
before=$(cat "$H/.zshrc")
o=$(env -i PATH="$PATH" HOME="$H" sh "$SL2/install.sh" 2>&1)
o=$(plain "$o")
check "helpers sourced through another file: .zshrc untouched" "$(cat "$H/.zshrc")" "$before"
has "…and the installer says where it found them" "$o" "statusline.zsh already sourced in ~/.zsh/index.zsh"
has "…for claude-usage too" "$o" "claude-usage.zsh already sourced in ~/.zsh/index.zsh"

newhome
inst --bogus >/dev/null
check "an unknown option exits 2" "$rc" 2

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
