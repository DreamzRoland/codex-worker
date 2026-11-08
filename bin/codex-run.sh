#!/usr/bin/env bash
# codex-run.sh - run one OpenAI Codex task for the codex-worker subagent.
#
#   codex-run.sh new                      create a private run dir, print its path
#   codex-run.sh exec <run-dir> [opts]    run Codex on <run-dir>/prompt.txt, print a receipt
#   codex-run.sh receipt <run-dir>        print the receipt of a finished run
#
# exec options:
#   -d <dir>     working directory (required)
#   -s <mode>    workspace-write (default) | read-only   (danger-full-access is refused)
#   -n           allow network for sandboxed commands (workspace-write only; default off)
#   -w           run in a fresh git worktree + branch under the run dir (for parallel writes)
#   -m <model>   Codex model (default: ~/.codex/config.toml)
#   -e <effort>  none|minimal|low|medium|high|xhigh
#   -o <file>    JSON Schema for structured final output
#   -r <id>      resume an existing Codex thread (a UUID)
#   -G           do not append the standard guardrails
#
# Exit codes: 0 Codex succeeded, 64 usage error (the run dir stays usable),
# 66 run could not start (receipt written), 70 run died, 75 still running
# (receipt), 130 interrupted, otherwise Codex's own.
set -u
set -o pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# An installed launcher always uses the root recorded at install time, which is
# also what the guard checks against; CODEX_WORKER_RUNS only applies otherwise.
RUNS_ROOT=""
if [ -f "$SCRIPT_DIR/runs-root" ]; then IFS= read -r RUNS_ROOT < "$SCRIPT_DIR/runs-root" || [ -n "$RUNS_ROOT" ]
elif [ -n "${CODEX_WORKER_RUNS:-}" ]; then RUNS_ROOT=$CODEX_WORKER_RUNS
else RUNS_ROOT="$HOME/.cache/codex-worker/runs"; fi
# Drive-letter paths are absolute only on Windows.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ABS_RE='^(/|[A-Za-z]:/)' ;; *) ABS_RE='^/' ;; esac
[[ $RUNS_ROOT =~ $ABS_RE ]] || { printf "codex-run: the runs root must be an absolute path, got: '%s'\n" "${RUNS_ROOT//[[:cntrl:]]/?}" >&2; exit 64; }
# Per-user state shared by every runs root: the list of runs roots and the lock
# under which runs claim their folders (see claim). An installed launcher always
# uses the per-user default, so that all installations share one list and lock;
# CODEX_WORKER_STATE only moves it for a launcher run from a checkout (tests).
if [ -f "$SCRIPT_DIR/runs-root" ]; then STATE_DIR="$HOME/.cache/codex-worker"
else STATE_DIR=${CODEX_WORKER_STATE:-$HOME/.cache/codex-worker}; fi
[[ $STATE_DIR =~ $ABS_RE && $STATE_DIR != *$'\n'* ]] || { echo "codex-run: CODEX_WORKER_STATE must be an absolute path" >&2; exit 64; }
ROOT_MARKER=".codex-worker-runs"
RUN_ID_RE='^[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$'
UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._:-]*$'
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
PREVIEW_BYTES=1200
STDERR_BYTES=4000
MAX_LISTED=40
OUTPUTS="prompt.sent.txt events.jsonl stderr.txt answer.md exit meta.txt command.txt pid repo
  git-before.txt git-after.txt changed.txt receipt.txt branch worktree note.txt"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=true ;; *) WINDOWS=false ;; esac
TEMP_ENV=()   # VAR=folder: the temporary folders of a checked write run, as Codex gets them
CHECKED_ROOTS=()   # the writable folders of a checked write run: -d, then the temporary ones
CLAIM_W=() CLAIM_R=() CLAIM_FILE="" CLAIM_ERROR="" LOCK_PROBLEM="" CHILD_STARTED=false RUN_LOCK="" ROOT_CREATED=false   # see claim

# Control characters in a message (a path can carry terminal escapes) are shown as "?".
# A run that then does not start gives its claim and its run dir back.
die() {
  local m="codex-run: $*"
  printf '%s\n' "${m//[[:cntrl:]]/?}" >&2
  if ! $CHILD_STARTED; then
    [ -z "$CLAIM_FILE" ] || rm -f "$CLAIM_FILE"
    [ -z "$RUN_LOCK" ] || { rm -f "${RUN_LOCK%/.lock}/pid"; rmdir "$RUN_LOCK" 2>/dev/null; }
  fi
  exit 64
}
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
# Fails for a folder with a newline in its name: command substitution would drop
# one at the end and so name another folder (the dot keeps it visible here).
abspath() {
  local r
  r=$(cd "$1" 2>/dev/null && pwd -P && printf .) || return 1
  r=${r%.}; r=${r%$'\n'}
  [[ $r != *$'\n'* ]] || return 1
  printf '%s\n' "$r"
}
[ "$(uname -s)" = Darwin ] && CASELESS=true || CASELESS=$WINDOWS   # case-insensitive file systems
lower() { if $CASELESS; then printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; else printf '%s\n' "$1"; fi; }
# Removes an incomplete UTF-8 sequence left by byte-based truncation, and any
# other byte that is not UTF-8. perl first: macOS iconv -c keeps a sequence cut
# off at the end. Bytes, not Encode: some Encode versions drop the character
# after a bad byte too. Each match keeps a run of ASCII or one well-formed
# sequence, or drops one other byte (no repeated group: older perls cap those
# at 32766 rounds). Raw I/O, so a native Windows perl keeps line ends as is.
utf8_clean() {
  if command -v perl >/dev/null 2>&1; then
    perl -C0 -0777 -pe 'BEGIN { binmode STDIN; binmode STDOUT }
      s/([\x00-\x7f]+|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})|[\x80-\xff]/defined $1 ? $1 : ""/ge'
  elif command -v iconv >/dev/null 2>&1; then iconv -c -f UTF-8 -t UTF-8 2>/dev/null
  else cat; fi
}
# Escapes a path so it fits on one line and holds no terminal controls:
# backslash, newline and tab, and any other control character as \xHH.
esc() {
  local s=${1//\\/\\\\} i c
  s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  case $s in
    *[[:cntrl:]]*)
      for i in 1 2 3 4 5 6 7 8 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 127; do
        printf -v c "\\$(printf '%03o' "$i")"
        s=${s//"$c"/$(printf '\\x%02x' "$i")}
      done ;;
  esac
  # UTF-8 C1 controls (U+0080-U+009F), which some terminals obey as well.
  case $s in
    *$'\302'*)
      for ((i = 128; i < 160; i++)); do
        printf -v c "\302\\$(printf '%03o' "$i")"
        s=${s//"$c"/$(printf '\\xc2\\x%02x' "$i")}
      done ;;
  esac
  # Marks that reorder text (U+061C, U+200E/F, U+2028/9, U+202A-E, U+2066-9).
  case $s in
    *$'\342'*|*$'\330\234'*)
      local -a mk=($'\330\234' $'\342\200\216' $'\342\200\217' $'\342\200\250' $'\342\200\251' $'\342\200\252'
                   $'\342\200\253' $'\342\200\254' $'\342\200\255' $'\342\200\256' $'\342\201\246' $'\342\201\247'
                   $'\342\201\250' $'\342\201\251')
      local -a mx=('\xd8\x9c' '\xe2\x80\x8e' '\xe2\x80\x8f' '\xe2\x80\xa8' '\xe2\x80\xa9' '\xe2\x80\xaa'
                   '\xe2\x80\xab' '\xe2\x80\xac' '\xe2\x80\xad' '\xe2\x80\xae' '\xe2\x81\xa6' '\xe2\x81\xa7'
                   '\xe2\x81\xa8' '\xe2\x81\xa9')
      for ((i = 0; i < ${#mk[@]}; i++)); do c=${mx[i]}; s=${s//"${mk[i]}"/$c}; done ;;
  esac
  printf '%s\n' "$s"
}
# Drops terminal controls from text Codex wrote (answer, stderr) before it is
# shown in a receipt: C0 controls but newline and tab, DEL, UTF-8 C1 controls,
# and the marks that reorder text (U+061C, U+200E/F, U+2028/9, U+202A-E, U+2066-9).
ctl_clean() {
  local e2 x80 x81
  e2=$(printf '\342') x80=$(printf '\200') x81=$(printf '\201')
  LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C sed \
    -e "s/$(printf '\302')[$(printf '\200')-$(printf '\237')]//g" \
    -e "s/$(printf '\330\234')//g" \
    -e "s/${e2}${x80}[$(printf '\216\217\250\251\252\253\254\255\256')]//g" \
    -e "s/${e2}${x81}[$(printf '\246\247\250\251')]//g"
}

# Git against an untrusted repository, outside Codex's sandbox: no fsmonitor, no
# hooks, and attributes read from the empty tree so that no clean/smudge/process
# filter configured by the repository can run.
# Attributes can also come from .git/info/attributes, so every filter driver the
# repository's config defines is overridden with an empty command as well.
g() {
  # protocol.allow=never and GIT_NO_LAZY_FETCH stop implicit fetches (and so any
  # repository-configured transport program such as core.sshCommand); submodules
  # are never entered, so their own configuration is never consulted.
  local -a ov=(-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.quotepath=off -c core.attributesFile=/dev/null
    -c protocol.allow=never -c submodule.recurse=false -c diff.ignoreSubmodules=all -c status.submoduleSummary=false)
  local -a envs=()
  local key name var seen=$'\n' i=0 empty=$EMPTY_TREE
  if [ "${1:-}" = -C ]; then
    # Overrides go through GIT_CONFIG_KEY_n/VALUE_n rather than -c, because a
    # filter name may itself contain "=" (which -c would split on).
    while IFS= read -r -d '' key; do
      [[ $key == filter.*.* ]] || continue
      name=${key#filter.}; name=${name%.*}
      [[ $seen == *$'\n'"$name"$'\n'* ]] && continue
      seen+="$name"$'\n'
      for var in clean smudge process required; do
        envs+=("GIT_CONFIG_KEY_$i=filter.$name.$var")
        if [ "$var" = required ]; then envs+=("GIT_CONFIG_VALUE_$i=false"); else envs+=("GIT_CONFIG_VALUE_$i="); fi
        i=$((i + 1))
      done
    done < <(git -C "$2" config -z --name-only --get-regexp '^filter\.' 2>/dev/null)
    # The empty tree's id depends on the repository's hash (SHA-1 or SHA-256).
    empty=$(printf '' | git -C "$2" hash-object -t tree --stdin 2>/dev/null) || empty=$EMPTY_TREE
  fi
  # GIT_ALLOW_PROTOCOL names no real protocol, so every transport is refused even
  # if the repository sets protocol.<name>.allow=always (and on Git < 2.44, which
  # ignores GIT_NO_LAZY_FETCH).
  # GIT_OPTIONAL_LOCKS=0: status does not refresh or rewrite the index.
  env GIT_ATTR_SOURCE="$empty" GIT_ALLOW_PROTOCOL=none GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    GIT_CONFIG_COUNT="$i" \
    ${envs[@]+"${envs[@]}"} git "${ov[@]}" "$@"
}
git_safe() {   # GIT_ATTR_SOURCE needs git 2.42 or newer
  local v major minor
  v=$(git --version 2>/dev/null | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/') || return 1
  read -r major minor <<< "$v"
  [ "${major:-0}" -gt 2 ] || { [ "${major:-0}" -eq 2 ] && [ "${minor:-0}" -ge 42 ]; }
}

# Adapted from the guardrails of PeterSR/claude-code-codex-subagent (MIT); see
# THIRD_PARTY_NOTICES.md.
GUARDRAILS='
<guardrails>
- Keep changes tightly scoped to the task; only touch files it requires.
- Do not run formatters or linters across the whole repository.
- Do not invent APIs or guess missing repository facts; if a prerequisite is missing, stop and report it.
- If the sandbox turns out read-only and you cannot edit, output the complete unified diff instead.
- Verify the result before finishing.
- Begin your final message with a short summary: what you did, how you verified it, and any deliberate deviation from the task.
</guardrails>'

ensure_root() {
  ROOT_CREATED=false
  if [ ! -d "$RUNS_ROOT" ]; then
    mkdir -p "$RUNS_ROOT" || die "cannot create $RUNS_ROOT"
    chmod 700 "$RUNS_ROOT" 2>/dev/null
    ROOT_CREATED=true
  fi
  ROOT_ABS=$(abspath "$RUNS_ROOT") || die "cannot resolve $RUNS_ROOT"
  if ! $WINDOWS; then
    [ -O "$ROOT_ABS" ] || die "runs root is not owned by you: $ROOT_ABS"
    if [ -f "$ROOT_ABS/$ROOT_MARKER" ]; then chmod 700 "$ROOT_ABS"
    elif [ -n "$(find "$ROOT_ABS" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ]; then
      die "runs root is writable by other users: $ROOT_ABS"
    fi
  fi
  register_root   # gives a new runs root its marker
}

# Accepts only a run dir created by `new`: a real directory directly inside the
# runs root whose name has the run-id shape. Sets RUN to its physical path.
resolve_run() {
  local arg="${1:-}"
  [ -n "$arg" ] || die "needs a run dir"
  [ -d "$arg" ] && [ ! -L "$arg" ] || die "not a run directory: $arg"
  ensure_root
  RUN=$(abspath "$arg") || die "cannot resolve $arg"
  [ "$(dirname "$RUN")" = "$ROOT_ABS" ] || die "run dir must be inside $(winpath "$ROOT_ABS"): $arg"
  [[ $(basename "$RUN") =~ $RUN_ID_RE ]] || die "not a run directory created by 'new': $arg"
  if ! $WINDOWS; then
    [ -O "$RUN" ] || die "run dir is not owned by you: $arg"
    chmod 700 "$RUN"
  fi
}

# For write runs, refuses working directories that contain, or sit inside,
# codex-worker's own files, your Claude/Codex configuration, hidden folders in
# your home (.ssh, .config, ...) or places that start programs at login: Codex
# may write anywhere in -d. Read-only runs cannot write, so any folder is fine.
# With "gitdir" as $2, checks git directory $1, which -w writes outside the
# sandbox, against the same protected places (no temporary folders).
check_workdir() {
  local wd=$1 mode=${2:-} p pa h
  [ "$wd" != / ] || die "refusing a filesystem root as working directory: $wd"
  if $WINDOWS && [[ $wd =~ ^/[a-zA-Z]/?$ || $wd =~ ^//[^/]+/[^/]+/?$ ]]; then
    die "refusing a drive or network share root as working directory: $(winpath "$wd")"
  fi
  # Command substitution would drop a newline at the end of these names.
  [[ $HOME${CLAUDE_CONFIG_DIR-}${CODEX_HOME-} != *$'\n'* ]] \
    || die "HOME, CLAUDE_CONFIG_DIR or CODEX_HOME has a newline in it; use -s read-only"
  # Windows may keep the user folders away from $HOME (a different HOME, OneDrive
  # known-folder move, policies) without a link at the default place, so their
  # configured locations are asked from Windows itself. Without them a write run
  # could not be checked, so it is refused.
  local docs="" appdata="" localapp="" startup="" profile=""
  if $WINDOWS; then
    { IFS= read -r docs; IFS= read -r appdata; IFS= read -r localapp; IFS= read -r startup; IFS= read -r profile; } \
      < <(windows_folders)
    [ -n "$docs" ] && [ -n "$appdata" ] && [ -n "$localapp" ] && [ -n "$startup" ] && [ -n "$profile" ] \
      || die "cannot ask Windows where the user folders are (the system PowerShell failed), so a write run cannot be checked; use -s read-only"
  fi
  h=$(abspath "$HOME") && [ -n "$h" ] || die "cannot resolve the home folder $(winpath "$HOME"); use -s read-only"
  # Spelled as on disk and lowered only on Windows; refused as the folder
  # itself, anything inside it, and anything that contains it.
  local alias aliases
  local -a prot=()
  [ -n "$h" ] && prot=("$h"/.* "$h/AppData/Roaming" "$h/AppData/Local/Microsoft" "$h/Library/LaunchAgents"
                       "$h/Documents/PowerShell" "$h/Documents/WindowsPowerShell")
  # Documents/*PowerShell hold profiles that run at every PowerShell start. The
  # profile's hidden folders are listed where it physically lives (it may be a
  # junction), like $h, which abspath has already resolved.
  local pprof=""
  if $WINDOWS; then
    pprof=$(phys_path "$profile") && pprof=${pprof%%$'\n'*} && [ -n "$pprof" ] \
      || die "cannot resolve the profile folder $(winpath "$profile"); use -s read-only"
  fi
  $WINDOWS && prot+=(${pprof:+"$pprof"/.*} "$appdata" "$localapp/Microsoft" "$startup"
                     "$docs/PowerShell" "$docs/WindowsPowerShell")
  # Configuration that XDG programs (autostart entries included) and zsh read
  # where these variables say, rather than in the home folder.
  local x
  [[ ${XDG_CONFIG_HOME-}${XDG_DATA_HOME-}${XDG_CONFIG_DIRS-}${ZDOTDIR-} != *$'\n'* ]] \
    || die "an XDG or ZDOTDIR variable has a newline in it; use -s read-only"
  for x in "${XDG_CONFIG_HOME-}" "${XDG_DATA_HOME-}" "${ZDOTDIR-}"; do
    [[ $x =~ $ABS_RE ]] && prot+=("$x")
  done
  if ! $WINDOWS && [ -n "${XDG_CONFIG_DIRS-}" ]; then
    local -a xdirs=()
    IFS=: read -r -a xdirs <<< "$XDG_CONFIG_DIRS"
    for x in ${xdirs[@]+"${xdirs[@]}"}; do [[ $x == /* ]] && prot+=("$x"); done
  fi
  # On macOS all of ~/Library: login items, services and folder actions live there.
  [ "$(uname -s)" = Darwin ] && prot+=("$h/Library")
  add_linked_targets
  local out hops hop phys r lr what
  [[ $wd != *$'\n'* ]] || die "refusing a working directory with a newline in its name"
  # Codex may write to the temporary folders as well as to -d, so they get the
  # same checks: none of these writable roots may overlap a protected folder.
  local -a roots=("$(root_spelling "$wd")") root_vars=("") temp_hops=()
  if [ "$mode" != gitdir ]; then
    add_temp_roots
    check_nested_roots
  fi
  # Windows and macOS file systems are usually case-insensitive.
  { $WINDOWS || [ "$(uname -s)" = Darwin ]; } && shopt -s nocasematch
  for p in ${prot[@]+"${prot[@]}"}; do
    case $p in */.|*/..) continue ;; esac
    # A folder is also protected where it really lives, even before it exists,
    # and so is every link on the way there (links and junctions are followed):
    # a run that could replace one of them could move the folder. If that
    # cannot be worked out, the write run is refused rather than the folder
    # left unchecked; a link loop cannot be opened, so only its own path and
    # its links are protected. Direct entries of the physical home and profile
    # folders are already physical unless they are links (junctions test as
    # links in Git Bash), which keeps this cheap; deeper paths may sit below a
    # linked folder and are resolved.
    # A name with a newline cannot be checked (the lists here are line-based).
    if [[ $p == *$'\n'* ]]; then
      shopt -u nocasematch; die "a protected path has a newline in its name: $(esc "$p"); use -s read-only"
    fi
    local rest_h=${p#"$h"/} rest_p=""; out=""
    [ -n "$pprof" ] && rest_p=${p#"$pprof"/}
    if [ ! -L "$p" ] && { { [ "$rest_h" != "$p" ] && [[ $rest_h != */* ]]; } \
                         || { [ -n "$pprof" ] && [ "$rest_p" != "$p" ] && [[ $rest_p != */* ]]; }; }; then
      out=$p
    elif out=$(phys_path "$p"); then :
    elif [ $? = 2 ]; then :
    else shopt -u nocasematch; die "cannot resolve the protected path $(winpath "$p"); use -s read-only"
    fi
    # The folder, as given and where it lives, may neither hold nor be held by
    # the run; the places a run could change to move it may not be in the run.
    pa=${out%%$'\n'*} hops=""
    [ "$pa" = "$out" ] || hops=${out#*$'\n'}
    aliases=$p; [ -z "$pa" ] || [ "$pa" = "$p" ] || aliases+=$'\n'"$pa"
    for r in "${roots[@]}"; do
      while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        is_under "$alias" "$r" || is_under "$r" "$alias" || overlaps_id "$alias" "$r" || continue
        shopt -u nocasematch
        die "$(refusal "$r" "it overlaps the protected folder $(winpath "$p")")"
      done <<< "$aliases"
      while IFS= read -r hop; do
        [ -n "$hop" ] || continue
        is_under "$r" "$hop" || held_in "$hop" "$r" || continue
        shopt -u nocasematch
        die "$(refusal "$r" "it holds a place on the way to the protected folder $(winpath "$p")")"
      done <<< "$hops"
    done
  done
  shopt -u nocasematch
  # Home folders may hold the run; everything else may neither hold nor be held.
  # The places a run could change to move any of them may not be in the run either.
  local i; local -a lroots=()
  for ((i = 0; i < ${#roots[@]}; i++)); do lroots+=("$(lower "${roots[i]}")"); done
  local -a own=()
  while IFS= read -r p; do own+=("$p"); done < <(registered_roots)
  for p in "$HOME" ${profile:+"$profile"} "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${CODEX_HOME:-$HOME/.codex}" \
           "$ROOT_ABS" ${own[@]+"${own[@]}"} "$STATE_DIR" "$SCRIPT_DIR"; do
    if out=$(phys_path "$p"); then :
    elif [ $? = 2 ]; then :   # a link loop
    else die "cannot resolve $(winpath "$p"); use -s read-only"
    fi
    phys=${out%%$'\n'*} hops=""
    [ "$phys" = "$out" ] || hops=${out#*$'\n'}
    [ -n "$phys" ] || { $WINDOWS && phys=$(posix_spelling "$p"); } || phys=$p
    phys=$(root_spelling "$phys")
    pa=$(lower "$phys")
    for ((i = 0; i < ${#roots[@]}; i++)); do
      r=${roots[i]} lr=${lroots[i]}
      if is_under "$lr" "$pa" || held_in "$phys" "$r" \
         || { [ "$p" != "$HOME" ] && [ "$p" != "$profile" ] \
              && { is_under "$pa" "$lr" || { [ -e "$phys" ] && holds_id "$phys" "$r"; }; }; }; then
        what=$(winpath "$p")
        [ "$p" = "$ROOT_ABS" ] || [[ " ${own[*]-} " != *" $p "* ]] \
          || what="the runs root $what (on the list $(winpath "$STATE_DIR/runs-roots"), which keeps it protected even when it is gone; if it is no longer used, purge it with install.sh --uninstall --purge or remove its line there)"
        die "$(refusal "$r" "it overlaps $what")"
      fi
      while IFS= read -r hop; do
        [ -n "$hop" ] || continue
        is_under "$lr" "$(lower "$hop")" || held_in "$hop" "$r" || continue
        die "$(refusal "$r" "it holds a place on the way to $(winpath "$p")")"
      done <<< "$hops"
    done
  done
  [ "$mode" = gitdir ] || CHECKED_ROOTS=("${roots[@]}")
}

# A refusal of writable root $1 (-d, or a temporary folder) because of $2, with
# what can be done about it.
refusal() {
  local i
  if [ "${mode-}" = gitdir ]; then
    printf 'refusing -w: git would write branches and worktree records into %s: %s; leave out -w' "$(winpath "$1")" "$2"
    return
  fi
  if [ "$1" = "${roots[0]}" ]; then
    printf 'refusing working directory %s: %s; choose another working directory, or use -s read-only' "$(winpath "$1")" "$2"
    return
  fi
  printf 'refusing a write run: Codex may also write to the temporary folder %s, and %s; ' "$(winpath "$1")" "$2"
  for ((i = 1; i < ${#roots[@]}; i++)); do
    if [ "${roots[i]}" = "$1" ] && [ -n "${root_vars[i]}" ]; then
      printf 'point %s at another folder, or use -s read-only' "${root_vars[i]}"; return
    fi
  done
  printf 'keep it out of that folder, or use -s read-only'
}

# One spelling for writable roots: on Windows a Git Bash mount (/tmp) is spelled
# as the drive path it stands for (/c/...), whose parents are the real ones
# (cygpath -u would turn that path back into the mount).
root_spelling() {
  local m d
  if $WINDOWS && m=$(cygpath -m -- "$1") && [ -n "$m" ]; then
    case $m in
      [A-Za-z]:*) d=$(printf '%s' "${m%%:*}" | tr '[:upper:]' '[:lower:]'); m="/$d${m#?:}" ;;
    esac
    [ "$m" = / ] || m=${m%/}
    printf '%s\n' "$m"
  else printf '%s\n' "$1"; fi
}

# For check_workdir: adds to its roots the temporary folders Codex's
# workspace-write sandbox may write to (/tmp, /var/tmp, $TMPDIR; also TEMP and
# TMP on Windows, and the per-user one on macOS), where they physically live,
# each once (by identity). A folder named by a variable must be one that can be
# entered, and Codex gets it by that physical path (TEMP_ENV): a link on the way
# could otherwise be changed during the run, and a relative name would be read
# from -d. The fixed folders are skipped only where nothing exists; Codex gets
# them by name, so the places on their way are kept in temp_hops for
# check_nested_roots.
add_temp_roots() {
  local t v n
  local -a vs=(TMPDIR)
  if $WINDOWS; then
    vs+=(TEMP TMP)
    # Windows reads environment names in any case: a "Temp" would be another
    # temporary folder, unseen here. Without TEMP and TMP it uses the profile.
    while IFS= read -r n; do
      case $n in
        TEMP|TMP|TMPDIR) ;;
        [Tt][Ee][Mm][Pp]|[Tt][Mm][Pp]|[Tt][Mm][Pp][Dd][Ii][Rr])
          die "the environment has $n besides the usual spelling of that temporary folder variable; unset it, or use -s read-only" ;;
      esac
    done < <(compgen -e)
    [ -n "${TEMP-}${TMP-}" ] || die "TEMP and TMP are not set, so Windows would use your profile as temporary folder; set them, or use -s read-only"
  fi
  for t in /tmp /var/tmp /private/tmp /private/var/tmp; do add_temp_root "$t" ""; done
  # macOS: the per-user temporary folder, also when TMPDIR names another one.
  [ "$(uname -s)" = Darwin ] && add_temp_root "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" ""
  for v in "${vs[@]}"; do add_temp_root "${!v-}" "$v"; done
}

# For add_temp_roots: adds folder $1, named by variable $2 (empty for a fixed one).
add_temp_root() {
  local t=$1 v=$2 a x out hops
  [ -n "$t" ] || return 0
  [[ $t != *$'\n'* ]] || die "a temporary folder has a newline in its name; use -s read-only"
  if [ -z "$v" ] && [ ! -e "$t" ] && [ ! -L "$t" ]; then return 0; fi
  # The folder must also open (abspath enters it): on Windows -x says nothing.
  out=$(phys_path "$t") && a=${out%%$'\n'*} && [ -n "$a" ] && [ -d "$a" ] && [ -x "$a" ] && abspath "$a" >/dev/null \
    || die "${v:-the temporary folder} $(winpath "$t") is not a folder that can be entered, so a write run cannot be checked; ${v:+point $v at one, or }use -s read-only"
  if [ -n "$v" ]; then
    if $WINDOWS; then TEMP_ENV+=("$v=$(cygpath -w -- "$a")"); else TEMP_ENV+=("$v=$a"); fi
  else
    hops=""; [ "$a" = "$out" ] || hops=${out#*$'\n'}
    while IFS= read -r x; do [ -z "$x" ] || temp_hops+=("$x"$'\n'"$t"); done <<< "$hops"
  fi
  a=$(root_spelling "$a")
  for x in "${roots[@]}"; do
    [ "$x" != "$a" ] && ! [ "$x" -ef "$a" ] || return 0
  done
  roots+=("$a"); root_vars+=("$v")
}

# A writable root inside another one could be replaced, by a link for example,
# while Codex runs, and Codex may look its roots up again by path: it would then
# write wherever the link leads. So no root may lie inside another, and no place
# on the way to a temporary folder that Codex gets by name may lie in a root.
check_nested_roots() {
  local i j a b hop
  local -a low=()
  for ((i = 0; i < ${#roots[@]}; i++)); do low+=("$(lower "${roots[i]}")"); done
  for ((i = 0; i < ${#roots[@]}; i++)); do
    for ((j = 0; j < ${#roots[@]}; j++)); do
      [ "$i" != "$j" ] || continue
      a=${roots[i]} b=${roots[j]}
      is_under "${low[i]}" "${low[j]}" || holds_id "$a" "$b" || continue
      if [ "$j" = 0 ]; then
        die "$(refusal "$a" "the working directory $(winpath "$b") lies inside it, so the run could replace the working directory while Codex runs")"
      fi
      die "$(refusal "$b" "it lies inside the writable folder $(winpath "$a"), so the run could replace it while Codex runs")"
    done
    for hop in ${temp_hops[@]+"${temp_hops[@]}"}; do
      a=${hop%%$'\n'*}
      is_under "${low[i]}" "$(lower "$a")" || held_in "$a" "${roots[i]}" || continue
      die "$(refusal "${roots[i]}" "it holds $(winpath "$a"), a place on the way to the temporary folder ${hop#*$'\n'}, which the run could change while Codex runs")"
    done
  done
}

# --- claims: runs at the same time --------------------------------------------
# A write run may replace anything in its writable folders, so another run's
# writable folder must not lie strictly inside one of them (the run could swap
# it for a link while Codex looks it up again by path), and no folder another
# run's unsandboxed git reads or writes ("reserved": its working directory, the
# repository's top level and its git directories) may overlap one of them.
# Every run, read-only ones too, records its folders in a "claim" file in its
# run dir before any git runs, and keeps it until its whole Codex process group
# has ended. The claims of every runs root on the per-user list
# STATE_DIR/runs-roots are compared under one lock in STATE_DIR.

# Takes the claims lock: an exclusive flock(2) on STATE_DIR/claims.flock, held
# through file descriptor 9 of this shell, so the system releases it whenever
# the launcher ends, also when it is killed. perl takes it (flock(1) where perl
# is missing), waiting at most 30 s.
claims_lock() {
  local rc=1
  LOCK_PROBLEM=""
  exec 9>>"$STATE_DIR/claims.flock" || { LOCK_PROBLEM="cannot open $(winpath "$STATE_DIR/claims.flock")"; return 1; }
  if command -v perl >/dev/null 2>&1; then
    # Exit 3 is the 30 s timeout; anything else is a lock that cannot be had at
    # all: 2 for a perl that does not share this shell's descriptors (a native
    # Windows perl ahead of Git's own on PATH), 4 for a failing flock(2).
    perl -e 'use Fcntl ":flock"; open(my $f, ">&=", 9) or exit 2;
             $SIG{ALRM} = sub { exit 3 }; alarm 30; flock($f, LOCK_EX) or exit 4; exit 0' && return 0
    rc=$?
    [ "$rc" = 3 ] || LOCK_PROBLEM="perl could not lock $(winpath "$STATE_DIR/claims.flock") (exit $rc$([ "$rc" = 2 ] && printf "; is it Git's own perl?"))"
  elif command -v flock >/dev/null 2>&1; then
    flock -E 3 -w 30 -x 9 && return 0
    rc=$?
    [ "$rc" = 3 ] || LOCK_PROBLEM="flock could not lock $(winpath "$STATE_DIR/claims.flock") (exit $rc)"
  else
    LOCK_PROBLEM="neither perl nor flock is installed, so runs cannot be kept apart"
  fi
  exec 9>&-
  return 1
}
claims_unlock() { exec 9>&-; }
claims_lock_error() {
  if [ -n "$LOCK_PROBLEM" ]; then printf '%s' "$LOCK_PROBLEM"
  else printf 'another codex-run held the lock %s for 30 s; try again shortly' "$(winpath "$STATE_DIR/claims.flock")"; fi
}

# True while the run of claim file $1 may still write or run git: it has no
# exit code yet (the launcher stops what is left of Codex before writing one)
# and a process of its Codex process group is alive, or its launcher is alive,
# or that launcher died while starting Codex before its group was recorded
# (within 60 s; once a group is recorded, that group alone tells).
claim_live() {
  local line pid="" start="" now grouped=false
  [ ! -e "${1%/claim}/exit" ] || return 1
  {
    while IFS= read -r line; do
      case $line in
        "pid "*) pid=${line#pid } ;;
        "starting "*) start=${line#starting } ;;
        "pgid "*) grouped=true
                  [[ ${line#pgid } =~ ^[0-9]+$ ]] && kill -0 -- "-${line#pgid }" 2>/dev/null && return 0 ;;
      esac
    done < "$1"
  } 2>/dev/null
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && return 0
  ! $grouped && [[ $start =~ ^[0-9]+$ ]] && now=$(date +%s) && [ $((now - start)) -lt 60 ]
}

# True if path $1 is folder $2 or lies inside it, by spelling or by identity.
within() { is_under "$(lower "$2")" "$(lower "$1")" || { [ -d "$2" ] && held_in "$1" "$2"; }; }
same_place() { [ "$1" = "$2" ] || [ "$1" -ef "$2" ]; }

# Prints why this run's claim (CLAIM_W, CLAIM_R) clashes with folder $2 of kind
# $1 (w: writable, r: reserved) of another live run; false if it does not.
claim_clash() {
  local kind=$1 q=$2 x
  for x in ${CLAIM_W[@]+"${CLAIM_W[@]}"}; do
    if [ "$kind" = w ]; then
      same_place "$x" "$q" && continue
      within "$x" "$q" || within "$q" "$x" || continue
      printf 'the writable folders %s and %s lie inside one another' "$(winpath "$x")" "$(winpath "$q")"; return 0
    fi
    within "$q" "$x" || within "$x" "$q" || continue
    printf "the writable folder %s overlaps %s, which that run's git uses" "$(winpath "$x")" "$(winpath "$q")"; return 0
  done
  [ "$kind" = w ] || return 1
  for x in ${CLAIM_R[@]+"${CLAIM_R[@]}"}; do
    within "$x" "$q" || within "$q" "$x" || continue
    printf "its writable folder %s overlaps %s, which this run's git uses" "$(winpath "$q")" "$(winpath "$x")"; return 0
  done
  return 1
}

# Checks CLAIM_W and CLAIM_R against every live claim and records them in run
# dir $1. Fails with the reason in CLAIM_ERROR. Claim lines are "w <path>",
# "r <path>", "pid", "starting" and "pgid"; paths are read back whole.
claim() {
  local run=$1 rr f line kind q why
  CLAIM_ERROR=""
  claims_lock || { CLAIM_ERROR=$(claims_lock_error); return 1; }
  while IFS= read -r rr; do
    for f in "$rr"/*/claim; do
      [ -f "$f" ] && ! [ "$f" -ef "$run/claim" ] || continue
      claim_live "$f" || continue
      while IFS= read -r line; do
        kind=${line%% *} q=${line#* }
        case $kind in w|r) ;; *) continue ;; esac
        why=$(claim_clash "$kind" "$q") || continue
        CLAIM_ERROR="$why, and the run $(basename "${f%/claim}") is still running"
        break 3
      done < "$f"
    done
  done < <(registered_roots)
  # Runs roots registered since this run's folders were checked: none may lie
  # in (or be) a writable folder, and a writable folder may lie in one only as
  # this run's own worktree.
  if [ -z "$CLAIM_ERROR" ]; then
    while IFS= read -r rr; do
      for q in ${CLAIM_W[@]+"${CLAIM_W[@]}"}; do
        if within "$rr" "$q"; then
          CLAIM_ERROR="the runs root $(winpath "$rr") lies in its writable folder $(winpath "$q")"; break 2
        fi
        if within "$q" "$rr" && ! within "$q" "$run"; then
          CLAIM_ERROR="its writable folder $(winpath "$q") lies in the runs root $(winpath "$rr")"; break 2
        fi
      done
    done < <(registered_roots)
  fi
  if [ -z "$CLAIM_ERROR" ]; then
    { printf 'pid %s\n' "$$"
      for q in ${CLAIM_W[@]+"${CLAIM_W[@]}"}; do printf 'w %s\n' "$q"; done
      for q in ${CLAIM_R[@]+"${CLAIM_R[@]}"}; do printf 'r %s\n' "$q"; done
    } >| "$run/claim.new" && mv -f "$run/claim.new" "$run/claim" || CLAIM_ERROR="cannot record the claim in $(winpath "$run")"
    [ -n "$CLAIM_ERROR" ] || CLAIM_FILE="$run/claim"
  fi
  claims_unlock
  [ -z "$CLAIM_ERROR" ]
}

# True if every folder of the claim is still where it was checked: a folder
# replaced (by a link, say) before the claim was in place would now be elsewhere.
claim_unchanged() {
  local r a
  for r in ${CLAIM_W[@]+"${CLAIM_W[@]}"} ${CLAIM_R[@]+"${CLAIM_R[@]}"}; do
    a=$(abspath "$r") && [ "$(root_spelling "$a")" = "$r" ] || return 1
  done
}

# Adds this runs root to the per-user list of runs roots and gives it its
# marker. Every listed root is protected for write runs, whether it still exists
# or not, and the claims kept in it are checked by every run. It is checked under
# the claims lock each time, and refused where it and a running write run's
# writable folder overlap (that run's own worktree aside): that run could then
# change the claims, prompts and receipts kept there, or forge its marker.
register_root() {
  local list="$STATE_DIR/runs-roots" rr f line q err=""
  if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" 2>/dev/null || die "cannot create $(winpath "$STATE_DIR")"
  fi
  claims_lock || die "cannot take the runs root $(winpath "$ROOT_ABS") into use: $(claims_lock_error)"
  while IFS= read -r rr; do
    for f in "$rr"/*/claim; do
      [ -f "$f" ] && claim_live "$f" || continue
      while IFS= read -r line; do
        [ "${line%% *}" = w ] || continue
        q=${line#* }
        within "$q" "${f%/claim}" && continue
        within "$ROOT_ABS" "$q" || within "$q" "$ROOT_ABS" || continue
        err="it and the folder $(winpath "$q") of the running write run $(basename "${f%/claim}") overlap"
        break 3
      done < "$f"
    done
  done < <(registered_roots)
  if [ -z "$err" ] && [ ! -e "$ROOT_ABS/$ROOT_MARKER" ]; then
    : > "$ROOT_ABS/$ROOT_MARKER" || err="cannot write $(winpath "$ROOT_ABS")"
  fi
  if [ -z "$err" ] && ! { [ -f "$list" ] && grep -qxF -- "$ROOT_ABS" "$list"; }; then
    printf '%s\n' "$ROOT_ABS" >> "$list" || err="cannot write $(winpath "$list")"
  fi
  claims_unlock
  [ -z "$err" ] || { $ROOT_CREATED && rmdir "$ROOT_ABS" 2>/dev/null; die "refusing the runs root $(winpath "$ROOT_ABS"): $err"; }
}
# The runs roots on the per-user list (this one while there is none yet), also
# those that are gone or lost their marker: a run could make one again.
registered_roots() {
  local r
  [ -f "$STATE_DIR/runs-roots" ] || { printf '%s\n' "$ROOT_ABS"; return 0; }
  while IFS= read -r r; do [ -n "$r" ] && printf '%s\n' "$r"; done < "$STATE_DIR/runs-roots"
}

# --- links inside protected folders --------------------------------------------
# For check_workdir: adds to prot the links found inside the protected
# configuration folders (all the way down, $XDG_CONFIG_DIRS included) and in
# the other hidden folders of the home (three levels down), as what they lead
# to is used as configuration too; each such link is resolved in full later.
# Folders are walked where they physically live (a folder may be a link
# itself), and a folder a link leads to is walked too, as deep as the folder the
# link was found in (all the way down for the configuration folders), unless a
# walk already covers it; at most MAX_LINKED of them, more refuses the run.
# Links that stay inside their own folder (relative, no "..") need no more, and
# links into the large folders that are protected but not walked (AppData,
# ~/Library) are not followed further. Entries that test as links but have no
# target (Windows sockets) lead nowhere.
MAX_LINKED=64
add_linked_targets() {
  local -a full=() shallow=() seen_full=() seen_shallow=() nf=() ns=() big=()
  local d y pd out linked=0 gnu=false is_seed
  find / -maxdepth 0 -printf '' >/dev/null 2>&1 && gnu=true
  big=("$h/AppData/Roaming" "$h/AppData/Local/Microsoft" ${appdata:+"$appdata"} ${localapp:+"$localapp/Microsoft"})
  [ "$(uname -s)" = Darwin ] && big+=("$h/Library")
  local -a seeds=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${CODEX_HOME:-$HOME/.codex}" "$h/.ssh" "$h/.gnupg"
                  "$h/.config" "$h/Library/LaunchAgents" ${startup:+"$startup"}
                  ${docs:+"$docs/PowerShell" "$docs/WindowsPowerShell"} "${XDG_CONFIG_HOME-}" "${ZDOTDIR-}")
  if ! $WINDOWS && [ -n "${XDG_CONFIG_DIRS-}" ]; then
    local -a xdirs=(); IFS=: read -r -a xdirs <<< "$XDG_CONFIG_DIRS"; seeds+=(${xdirs[@]+"${xdirs[@]}"})
  fi
  for d in "${seeds[@]}" "${XDG_DATA_HOME-}" "$h"/.* ${pprof:+"$pprof"/.*}; do
    case $d in ""|*/.|*/..) continue ;; esac
    [[ $d =~ $ABS_RE ]] && [ -d "$d" ] || continue
    [[ $d != *$'\n'* ]] || die "a protected folder has a newline in its name: $(esc "$d"); use -s read-only"
    # Direct entries of the physical home and profile are physical unless links.
    if [ ! -L "$d" ] && { [ "${d%/*}" = "$h" ] || [ "${d%/*}" = "$pprof" ]; }; then pd=$d
    else out=$(phys_path "$d") && pd=${out%%$'\n'*} && [ -n "$pd" ] && [ -d "$pd" ] || continue; fi
    [ "$pd" != / ] && ! is_under "$pd" "$h" || continue   # a link to the root or above the home
    is_seed=false; for y in "${seeds[@]}"; do [ "$y" != "$d" ] || is_seed=true; done
    if $is_seed; then queue_scan "" "$pd" || true; else queue_scan 3 "$pd" || true; fi
  done
  full=(${nf[@]+"${nf[@]}"}) shallow=(${ns[@]+"${ns[@]}"})
  while [ ${#full[@]} -gt 0 ] || [ ${#shallow[@]} -gt 0 ]; do
    nf=() ns=()
    for d in ${full[@]+"${full[@]}"}; do scan_links "" "$d"; done
    [ ${#shallow[@]} -eq 0 ] || scan_links 3 "${shallow[@]}"
    full=(${nf[@]+"${nf[@]}"}) shallow=(${ns[@]+"${ns[@]}"})
  done
}
# For add_linked_targets: queues physical folder $2 for a walk $1 levels deep
# (all the way if empty), unless a walk already covers it. False if covered.
queue_scan() {
  local n=$1 pd=$2 s r=0
  $CASELESS && shopt -s nocasematch
  for s in ${seen_full[@]+"${seen_full[@]}"}; do is_under "$s" "$pd" && { r=1; break; }; done
  if [ "$r" = 0 ] && [ -n "$n" ]; then
    for s in ${seen_shallow[@]+"${seen_shallow[@]}"}; do [[ $s == "$pd" ]] && { r=1; break; }; done
  fi
  shopt -u nocasematch
  [ "$r" = 0 ] || return 1
  if [ -n "$n" ]; then seen_shallow+=("$pd"); ns+=("$pd"); else seen_full+=("$pd"); nf+=("$pd"); fi
}
# For add_linked_targets: walks folders $2... ($1 levels down, or all the way).
# A folder walked all the way must be readable throughout (its name is given if
# not); in the shallow walks, folders that cannot be read are passed over.
scan_links() {
  local n=$1 l t pd out status="" err="$STATE_DIR/scan.$$.err"
  shift
  while IFS= read -r -d '' l; do
    case $l in rc=*) status=${l#rc=}; break ;; esac
    if $gnu; then IFS= read -r -d '' t || t=""; else t=$(readlink -- "$l" 2>/dev/null) || t=""; fi
    [ -n "$t" ] || continue
    [[ $l != *$'\n'* && $t != *$'\n'* ]] \
      || { rm -f "$err"; die "a protected folder holds a link with a newline in its name or target, which cannot be checked; use -s read-only"; }
    [[ ! $t =~ $ABS_RE && $t != *\\* && "/$t/" != */../* ]] && continue
    [[ $t =~ $ABS_RE && "$t/" != */../* ]] && in_big "$t" && continue
    pd=""
    if [ -d "$l" ]; then
      out=$(phys_path "$l") && pd=${out%%$'\n'*} || pd=""
      # A link to the filesystem root or to a folder holding the link opens a
      # whole tree rather than naming configuration (Wine's dosdevices/z:, say):
      # it is not followed (it lies in a protected folder already).
      if [ -n "$pd" ] && { [ "$pd" = / ] || is_under "$pd" "$l"; }; then continue; fi
    fi
    prot+=("$l")
    # Only links of the configuration folders lead to more walks, and none into
    # the large folders, however the link spells its way there.
    [ -z "$n" ] && [ -n "$pd" ] && [ -d "$pd" ] || continue
    in_big "$pd" && continue
    queue_scan "" "$pd" || continue
    linked=$((linked + 1))
    [ "$linked" -le "$MAX_LINKED" ] || { rm -f "$err"; die "more than $MAX_LINKED linked folders in the protected configuration; use -s read-only"; }
  done < <(
    if $gnu; then find "$@" -mindepth 1 ${n:+-maxdepth "$n"} -type l -printf '%p\0%l\0' 2>"$err"
    else find "$@" -mindepth 1 ${n:+-maxdepth "$n"} -type l -print0 2>"$err"; fi
    printf 'rc=%s\0' "$?")
  if [ "$status" != 0 ] && [ -z "$n" ]; then
    out=$(head -n 1 "$err" 2>/dev/null); rm -f "$err"
    die "cannot search $(winpath "$1") for links (${out:-find failed}); use -s read-only"
  fi
  rm -f "$err"
}
# For scan_links: true if absolute path $1 lies in one of the large protected
# folders that are not walked.
in_big() {
  local p r=1
  $CASELESS && shopt -s nocasematch
  for p in ${big[@]+"${big[@]}"}; do is_under "$p" "$1" && { r=0; break; }; done
  shopt -u nocasematch
  return "$r"
}

# Prints where absolute path $1 physically lives, also when it does not exist
# yet, followed by one line per place on the way that a run could change to
# move the path: each link met, and each folder (or missing name) that a later
# ".." leaves, since replacing it by a link changes where ".." leads. These
# places may not lie in a write run; the path itself may not overlap it.
# The path is walked one name at a time; links (also in parent folders) are
# followed by their target text, so a dangling link, or one to a file, still
# counts, and missing parts are kept below the deepest existing folder. A folder
# that cannot be searched could hide links, so the path is then unresolved.
# Returns 2 on a link loop, or a chain longer than any system follows (64; Linux
# stops at 40, macOS at 32, Windows at 63): the first line is then empty, as
# the path cannot be opened and only those places matter. Returns 1 if the path
# cannot be resolved otherwise: also for names with a newline, which neither
# this walk nor its output can hold. Windows drive paths (C:/...) and UNC paths
# (//server/share/...) are accepted.
phys_path() {
  # The names still to walk are todo[i..]. bash 3.2 can join the elements of
  # "${a[@]}" into one word in some expansions (inside ${...+...}, slices, or
  # with IFS changed), so IFS is changed only for the reads, and arrays are
  # walked by index and never sliced.
  local p=$1 cur="" top="" base="" comp t key s hops="" n=0 missing=false mdepth=0 r i=0 j rest
  local -a todo=() tt=() seen=() next=()
  [[ $p != *$'\n'* ]] || return 1
  if $WINDOWS && [[ $p != /* || $p == *\\* ]]; then p=$(posix_spelling "$p") || return 1; fi
  case $p in /*) ;; *) p="$PWD/$p" ;; esac
  unc_root "$p" || return 1
  IFS=/ read -r -a todo <<< "$p"
  while [ "$i" -lt ${#todo[@]} ]; do
    comp=${todo[i]}; i=$((i + 1))
    case $comp in
      ""|.) continue ;;
      ..) [ "$cur" != "$top" ] || continue   # ".." of a root is the root
          hops+=$'\n'"$cur"
          if $WINDOWS && [ -z "$top" ]; then
            # In Windows spelling: a Git Bash mount such as /tmp has another
            # parent there, and a drive root is its own parent.
            r=$(cygpath -m -- "$cur") || return 1
            [[ $r =~ ^[A-Za-z]:/?$ ]] || r=${r%/*}
            [[ $r =~ ^[A-Za-z]:$ ]] && r="$r/"
            cur=$(cygpath -u -- "$r") || return 1; cur=${cur%/}
          else
            cur=${cur%/*}
          fi
          # Back from the missing part into the existing one, whose names (and
          # links) are looked at again from here on.
          if $missing; then mdepth=$((mdepth - 1)); [ "$mdepth" -gt 0 ] || missing=false; fi
          continue ;;
    esac
    if $missing; then cur="$cur/$comp"; mdepth=$((mdepth + 1)); continue; fi
    if [ -d "${cur:-/}" ] && [ ! -x "${cur:-/}" ]; then return 1; fi
    if [ -L "$cur/$comp" ]; then
      # The walk is deterministic, so meeting the same link with the same names
      # still to resolve is a loop (found early); one that keeps growing ends at
      # the limit, past which no system opens the path either.
      rest=""; for ((j = i; j < ${#todo[@]}; j++)); do rest+="/${todo[j]}"; done
      key="$cur/$comp/$rest"
      for ((s = 0; s < ${#seen[@]}; s++)); do
        [ "${seen[s]}" != "$key" ] || { printf '\n%s\n' "${hops#$'\n'}"; return 2; }
      done
      n=$((n + 1)); [ "$n" -le 64 ] || { printf '\n%s\n' "${hops#$'\n'}"; return 2; }
      seen+=("$key")
      r=$(cd -P -- "${cur:-/}" 2>/dev/null && pwd -P) || r=${cur:-/}
      hops+=$'\n'"${r%/}/$comp"
      # The dot keeps a newline at the end of the target from being dropped.
      t=$(readlink -- "$cur/$comp" && printf .) || return 1
      t=${t%.}; t=${t%$'\n'}
      [ -n "$t" ] && [[ $t != *$'\n'* ]] || return 1
      if $WINDOWS && [[ $t =~ ^[A-Za-z]: || $t == *\\* ]]; then t=$(posix_spelling "$t") || return 1; fi
      case $t in /*) unc_root "$t" || return 1; t=$p ;; esac
      # The link's names come before those still to walk.
      tt=(); IFS=/ read -r -a tt <<< "$t"
      next=()
      for ((j = 0; j < ${#tt[@]}; j++)); do next[${#next[@]}]=${tt[j]}; done
      for ((j = i; j < ${#todo[@]}; j++)); do next[${#next[@]}]=${todo[j]}; done
      todo=(); for ((j = 0; j < ${#next[@]}; j++)); do todo[j]=${next[j]}; done
      i=0
      continue
    fi
    [ -e "$cur/$comp" ] || { missing=true; mdepth=1; base=${cur:-/}; }
    cur="$cur/$comp"
  done
  # The existing part holds no links, so it is physical; the OS only spells it.
  $missing || base=${cur:-/}
  if [ -d "$base" ] && r=$(cd -P -- "$base" 2>/dev/null && pwd -P); then
    cur="${r%/}${cur#"${base%/}"}"
  fi
  printf '%s%s\n' "${cur:-/}" "$hops"
}

# Windows: spells a native path (C:\x, C:/x, \\server\share\x, a\b) as Git Bash
# does. Backslashes are turned first: cygpath reads "\\server" as a folder of
# the current drive.
posix_spelling() {
  local p=${1//\\//}
  if [[ $p =~ ^[A-Za-z]: ]]; then cygpath -u -- "$p"; else printf '%s\n' "$p"; fi
}

# For phys_path, with its locals: starts the walk of absolute path $1 at its
# root. On Windows "//server/share" is a root of its own (one slash less would
# be another path); the rest of the path is left in p. Fails on "//server"
# without a share.
unc_root() {
  p=$1 cur="" top=""
  $WINDOWS || return 0
  case $1 in ///*|/[!/]*|/) return 0 ;; esac
  [[ $1 =~ ^//([^/]+)/([^/]+)(/.*)?$ ]] || return 1
  top="//${BASH_REMATCH[1]}/${BASH_REMATCH[2]}" cur=$top p=${BASH_REMATCH[3]}
}

# True if path $2 is $1 or lies below it; $1 may be the filesystem root.
is_under() { [[ $2 == "$1" ]] || [ "$1" = / ] || [[ $2 == "$1"/* ]]; }

# Spelling comparisons miss case differences outside ASCII (NTFS and APFS fold
# them, tr and nocasematch need not) and Unicode normalization, and pwd -P keeps
# the spelling it was given. So folders are also compared by identity (-ef).
# True if existing folder $1 is $2 or one of the folders $2 lies in.
# On Windows a Git Bash mount (/tmp, /usr) is walked up in Windows spelling, as
# its parents there are not those of the mount (the Git folder is "/").
holds_id() {
  local d=$2
  if $WINDOWS && [[ $d != /[A-Za-z] && $d != /[A-Za-z]/* && $d != //* && $d != [A-Za-z]:/* ]]; then
    d=$(cygpath -m -- "$d") || return 1
  fi
  while [ -n "$d" ]; do
    [ "$1" -ef "$d" ] && return 0
    case $d in / | [A-Za-z]:/) return 1 ;; esac
    d=${d%/*}
    case $d in "") d=/ ;; [A-Za-z]:) d="$d/" ;; esac
  done
  return 1
}
# True if path $1 is the existing folder $2 or lies inside it, by identity. A
# link at $1 counts where it is, not where it points; missing parts of $1 are
# judged by its deepest existing parent.
held_in() {
  local a=$1
  [ -e "$a" ] && [ ! -L "$a" ] && [ "$a" -ef "$2" ] && return 0
  a=${a%/*}
  while [ -n "$a" ] && [ ! -d "$a" ]; do a=${a%/*}; done
  holds_id "$2" "${a:-/}"
}
# True if path $1 and existing folder $2 are the same or one holds the other.
overlaps_id() { held_in "$1" "$2" || { [ -e "$1" ] && holds_id "$1" "$2"; }; }

# Prints a path from `git -C $1 rev-parse ${@:2}` (empty only with -e first)
# without losing a newline at its end, which command substitution would drop,
# naming another folder; fails for a path with a newline in it.
git_path() {
  local r d=$1 empty=false; shift
  [ "$1" = -e ] && { empty=true; shift; }
  r=$(g -C "$d" rev-parse "$@" 2>/dev/null && printf .) || return 1
  r=${r%.}; r=${r%$'\n'}
  { $empty || [ -n "$r" ]; } && [[ $r != *$'\n'* ]] || return 1
  printf '%s\n' "$r"
}

# Checks the repository with top level $1 before git runs on it: neither its
# common git dir nor its per-worktree git dir (which need not sit inside the
# common one) may hold links. Prints the per-worktree git dir and the physical
# top level (core.worktree may move it) if all is well, so a later call can
# tell whether either changed.
git_meta_check() {
  local gd common links top
  gd=$(git_path "$1" --absolute-git-dir) && gd=$(abspath "$gd") || return 1
  top=$(git_path "$1" --show-toplevel) && top=$(abspath "$top") || return 1
  common=$(git_path "$1" --path-format=absolute --git-common-dir) && common=$(abspath "$common") || return 1
  links=$(git_dir_links "$common") && [ -z "$links" ] || return 1
  if [ "$gd" != "$common" ]; then links=$(git_dir_links "$gd") && [ -z "$links" ] || return 1; fi
  printf '%s\n%s\n' "$gd" "$top"
}

# Prints the links (or junctions) inside git directory $1, except under hooks/,
# which git never writes. Each top-level entry is searched on its own, so no
# path is ever used as a find pattern. Returns 1 if something cannot be read.
git_dir_links() {
  local e rc=0
  [ -r "$1" ] && [ -x "$1" ] || return 1
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "$e" = "$1/hooks" ] && continue
    find "$e" -type l -print 2>/dev/null || rc=1
  done
  return "$rc"
}

# Prints, one per line, the configured Windows Documents, Roaming and Local
# AppData, Startup and user profile folders (DoNotVerify: also when a folder
# does not exist yet). Prints nothing if the system PowerShell, called by
# absolute path without profiles and with a time limit, cannot answer.
windows_folders() {
  local ps out f
  ps="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32/WindowsPowerShell/v1.0/powershell.exe"
  [ -f "$ps" ] || return 0
  local -a limit=()
  command -v timeout >/dev/null 2>&1 && limit=(timeout 30)
  out=$(${limit[@]+"${limit[@]}"} "$ps" -NoProfile -NonInteractive -Command '[Console]::OutputEncoding = [Text.Encoding]::UTF8
    foreach ($f in "MyDocuments", "ApplicationData", "LocalApplicationData", "Startup", "UserProfile") {
      [Environment]::GetFolderPath($f, [Environment+SpecialFolderOption]::DoNotVerify) }' < /dev/null 2>/dev/null) || return 0
  out=$(printf '%s\n' "$out" | tr -d '\r')
  [ "$(printf '%s\n' "$out" | grep -c .)" = 5 ] || return 0
  while IFS= read -r f; do cygpath -u "$f" || return 0; done <<< "$out"
}

cmd_new() {
  local id i
  ensure_root
  for i in 1 2 3 4 5 6 7 8 9 10; do
    id="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    if mkdir "$ROOT_ABS/$id" 2>/dev/null; then winpath "$ROOT_ABS/$id"; return 0; fi
  done
  die "cannot create a run directory in $ROOT_ABS"
}

# Writes "<xy> <blob-hash> <escaped path>" for every dirty or untracked path to
# $2, sorted. Content hashes catch a second edit to an already-dirty file; -z and
# the escaping keep unusual file names intact.
# True if a parent directory of path $2 inside $1 is a link (or NTFS junction).
# Builtin tests only: snapshot calls this for every changed path.
via_link() {
  local rest=$2 pre=""
  while [[ $rest == */* ]]; do
    pre+=${rest%%/*}; rest=${rest#*/}
    [ -L "$1/$pre" ] && return 0
    pre+=/
  done
  return 1
}
snapshot() {
  local root=$1 out=$2 entry p h i n=0
  local -a xs ps
  g -C "$root" status --porcelain=v1 -z -uall --no-renames --ignore-submodules=all > "$out.raw" || return 1
  while IFS= read -r -d '' entry; do
    xs[n]=${entry:0:2}; ps[n]=${entry:3}; n=$((n + 1))
  done < "$out.raw"
  : > "$out.batch"
  for ((i = 0; i < n; i++)); do
    p=${ps[i]}
    # --stdin-paths is line based and unquotes a leading '"'; hash those one by one.
    via_link "$root" "$p" && continue
    [ -f "$root/$p" ] && [ ! -L "$root/$p" ] && [[ $p != \"* && $p != *$'\n'* ]] && printf '%s\n' "$p" >> "$out.batch"
  done
  (cd "$root" && g hash-object --no-filters --stdin-paths < "$out.batch") > "$out.hashes" || return 1
  exec 3< "$out.hashes"
  for ((i = 0; i < n; i++)); do
    p=${ps[i]}
    # A symbolic link is identified by its target string; the file it points to
    # (possibly outside the repository, or huge) is never read, nor is anything
    # reached through a linked parent directory.
    if via_link "$root" "$p"; then h=via-link
    elif [ -L "$root/$p" ]; then h=L$( (cd "$root" && readlink -- "$p" | g hash-object --stdin) ) || h=unknown
    elif [ ! -f "$root/$p" ]; then h=deleted
    elif [[ $p != \"* && $p != *$'\n'* ]]; then IFS= read -r h <&3 || h=unknown
    else h=$(cd "$root" && g hash-object --no-filters -- "$p") || h=unknown; fi
    printf '%s %s %s\n' "${xs[i]}" "$h" "$(esc "$p")"
  done | LC_ALL=C sort > "$out"
  local rc=$?
  exec 3<&-
  rm -f "$out.raw" "$out.batch" "$out.hashes"
  return $rc
}

cmd_exec() {
  resolve_run "${1:-}"; shift
  local run=$RUN f

  local wd="" sandbox="workspace-write" network=false worktree=false model="" effort="" schema="" resume="" guard=true
  local OPTIND=1 opt
  while getopts ":d:s:nwm:e:o:r:G" opt; do
    case $opt in
      d) wd=$OPTARG ;; s) sandbox=$OPTARG ;; n) network=true ;; w) worktree=true ;;
      m) model=$OPTARG ;; e) effort=$OPTARG ;; o) schema=$OPTARG ;; r) resume=$OPTARG ;;
      G) guard=false ;;
      :) die "-$OPTARG needs a value" ;; *) die "unknown option -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [ $# -eq 0 ] || die "unexpected argument: $1"

  case $sandbox in read-only|workspace-write) ;; *) die "sandbox must be read-only or workspace-write, got: $sandbox" ;; esac
  case $effort in ""|none|minimal|low|medium|high|xhigh) ;; *) die "invalid effort: $effort" ;; esac
  [[ -z $model || $model =~ $MODEL_RE ]] || die "invalid model name: $model"
  [[ -z $resume || $resume =~ $UUID_RE ]] || die "invalid thread id (expected a UUID): $resume"
  $network && [ "$sandbox" != workspace-write ] && die "-n only applies to workspace-write"
  [ -n "$wd" ] || die "-d <workdir> is required"
  # Checked before abspath, whose command substitution drops trailing newlines.
  [[ $wd != *$'\n'* ]] || die "refusing a working directory with a newline in its name"
  local wd_arg=$wd
  wd=$(abspath "$wd") || die "workdir does not exist: $wd_arg"
  # The runs root is among the protected folders, so a run dir in a temporary
  # folder (which Codex may write to, while the launcher writes the receipt
  # there afterwards, outside the sandbox) refuses the write run too.
  [ "$sandbox" = workspace-write ] && check_workdir "$wd"
  if [ -n "$schema" ]; then
    [ -f "$schema" ] || die "schema not found: $schema"
    schema="$(abspath "$(dirname "$schema")")/$(basename "$schema")"
  fi
  command -v codex >/dev/null 2>&1 || die "codex CLI not on PATH (npm install -g @openai/codex)"
  [ -f "$run/prompt.txt" ] && [ ! -L "$run/prompt.txt" ] || die "exec: $run/prompt.txt not found (write the prompt first)"
  ! $worktree || [ -z "$resume" ] || die "-w cannot be combined with -r"

  # The run dir is taken from here on; until Codex starts, a usage error gives
  # it back as it was (see die).
  mkdir "$run/.lock" 2>/dev/null || die "exec: run dir already used: $(winpath "$run")"
  RUN_LOCK="$run/.lock"
  for f in $OUTPUTS claim; do
    [ -e "$run/$f" ] || [ -L "$run/$f" ] && die "exec: run dir already contains $f"
  done
  # The launcher's pid from the start: a launcher killed before Codex starts
  # leaves a run that `receipt` reports as dead, not one that seems to run.
  echo $$ > "$run/pid"
  # Every run claims its folders before git first looks at the repository (the
  # launcher's git runs outside the sandbox, for read-only runs too), and checks
  # them again once the claim keeps other runs out.
  if [ "$sandbox" = workspace-write ]; then
    CLAIM_R=("${CHECKED_ROOTS[0]}")
    if ! $worktree; then CLAIM_W=("${CHECKED_ROOTS[@]}")
    elif [ ${#CHECKED_ROOTS[@]} -gt 1 ]; then CLAIM_W=("${CHECKED_ROOTS[@]:1}")   # not in ${...+...}: see phys_path
    else CLAIM_W=(); fi
  else
    CLAIM_R=("$(root_spelling "$wd")") CLAIM_W=()
  fi
  claim "$run" || die "refusing to start: $CLAIM_ERROR; wait for that run, or choose another folder"
  claim_unchanged || die "a folder changed while it was being checked; try again"

  local root="" safe=true gcommon="" gx
  git_safe || safe=false
  root=$(git_path "$wd" --show-toplevel) || root=""
  # core.worktree can make the top level another checkout with its own git dir;
  # later calls rediscover the repository from $root, so it must be the same one.
  local redirected=false gd_wd gd_root
  if [ -n "$root" ]; then
    gd_wd=$(git_path "$wd" --absolute-git-dir) && gd_wd=$(abspath "$gd_wd") || gd_wd=""
    gd_root=$(git_path "$root" --absolute-git-dir) && gd_root=$(abspath "$gd_root") || gd_root=""
    [ -n "$gd_wd" ] && [ "$gd_wd" = "$gd_root" ] || redirected=true
    gcommon=$(git_path "$root" --path-format=absolute --git-common-dir) && gcommon=$(abspath "$gcommon") || gcommon=""
    # The top level and the git directories, which git uses outside the
    # sandbox, join the claim.
    for gx in "$root" "$gd_wd" "$gd_root" "$gcommon"; do [ -z "$gx" ] || CLAIM_R+=("$(root_spelling "$gx")"); done
    claim "$run" || die "refusing to start: $CLAIM_ERROR; wait for that run, or choose another folder"
    claim_unchanged || die "a folder changed while it was being checked; try again"
  fi
  if $worktree; then
    $redirected && die "-w refused: the repository's top level (core.worktree) belongs to a different git directory"
    [ -n "$root" ] || die "-w needs a git repository"
    $safe || die "-w needs git 2.42 or newer (to keep repository filters from running)"
    # -w writes branches and worktree records there, outside the sandbox.
    check_workdir "$gd_root" gitdir
    [ -z "$gcommon" ] || same_place "$gcommon" "$gd_root" || check_workdir "$gcommon" gitdir
  fi

  set -o noclobber

  if [ -n "$root" ] && ! $safe; then
    echo "change report disabled: git 2.42 or newer is needed to keep repository filters from running" >> "$run/note.txt"
    root=""
  elif [ -n "$root" ] && $redirected; then
    echo "change report disabled: the repository's top level (core.worktree) belongs to a different git directory" >> "$run/note.txt"
    root=""
  fi

  # Git follows links when it writes: snapshots may refresh index files (a
  # split index's shared file), and -w writes refs, reflogs, reftable, config,
  # packed-refs and the registration. So the git directory must hold no links
  # (or junctions) outside hooks/, which git never writes (hooks are disabled).
  if [ -n "$root" ] && ! git_meta_check "$root" > /dev/null; then
    echo "the git directory of $(winpath "$root") contains links or unreadable entries" >> "$run/note.txt"
    $worktree && { echo "refusing -w" >> "$run/note.txt"; fail_run "$run" 66; }
    echo "change report disabled" >> "$run/note.txt"
    root=""
  fi

  if $worktree; then
    local prefix branch
    prefix=$(git_path "$wd" -e --show-prefix) || {
      echo "cannot read the working directory's place in the repository" >> "$run/note.txt"; fail_run "$run" 66; }
    branch="codex/$(basename "$run")"
    printf '%s\n' "$root" > "$run/repo"
    # Create the worktree without checking files out, then populate it from inside:
    # the filter scan in g() then also sees configuration that only applies on
    # the new branch (includeIf "onbranch:codex/...").
    # --no-track: no branch.* configuration is written.
    if ! { g -C "$root" worktree add -q --no-checkout --no-track -b "$branch" "$run/worktree" HEAD \
           && g -C "$run/worktree" --work-tree="$(abspath "$run/worktree")" reset -q --hard HEAD; } > "$run/worktree.log" 2>&1; then
      echo "git worktree add failed: $(head -c 2000 "$run/worktree.log")" >> "$run/note.txt"
      fail_run "$run" 66
    fi
    printf '%s\n' "$branch" > "$run/branch"
    [ -n "$(g -C "$root" status --porcelain --ignore-submodules=all 2>/dev/null)" ] \
      && echo "worktree starts from HEAD; uncommitted changes in the main checkout are not included" >> "$run/note.txt"
    root=$(abspath "$run/worktree")
    # The checked-out prefix could be a symlink: resolve it and keep it inside the worktree.
    wd=$(abspath "$root${prefix:+/${prefix%/}}") || wd=""
    if [ -z "$wd" ] || { [ "$wd" != "$root" ] && [[ $wd != "$root"/* ]]; }; then
      echo "the working directory escapes the new worktree" >> "$run/note.txt"
      fail_run "$run" 66
    fi
  fi

  local prompt="$run/prompt.txt"
  if $guard; then
    { cat "$run/prompt.txt"; printf '%s\n' "$GUARDRAILS"; } > "$run/prompt.sent.txt"
    prompt="$run/prompt.sent.txt"
  fi

  # Pin the whole sandbox policy on the command line so a user, project or
  # CODEX_HOME config cannot widen it (extra writable roots, approval prompts).
  local args=(exec)
  if [ -n "$resume" ]; then
    args+=(resume -c "sandbox_mode=$sandbox")
  else
    # "." is the folder the launcher has just entered and checked (below); a
    # path would be looked up again by Codex, after a link could replace it.
    args+=(-s "$sandbox" -C .)
  fi
  args+=(-c 'approval_policy="never"')
  if [ "$sandbox" = workspace-write ]; then
    args+=(-c "sandbox_workspace_write.network_access=$network" -c 'sandbox_workspace_write.writable_roots=[]')
  fi
  [ -n "$model" ] && args+=(-m "$model")
  [ -n "$effort" ] && args+=(-c "model_reasoning_effort=$effort")
  [ -n "$schema" ] && args+=(--output-schema "$(winpath "$schema")")
  args+=(--json --skip-git-repo-check -o "$(winpath "$run/answer.md")")
  [ -n "$resume" ] && args+=("$resume")
  args+=(-)

  {
    echo "sandbox=$sandbox network=$network worktree=$worktree"
    echo "model=${model:-<config default>} effort=${effort:-<config default>}"
    echo "workdir=$(winpath "$wd")"
    echo "resume=${resume:-}"
  } > "$run/meta.txt"
  printf '%q ' codex "${args[@]}" > "$run/command.txt"

  local head_before="" snap=true gd_before=""
  if [ -n "$root" ]; then
    gd_before=$(git_meta_check "$root") || snap=false
    snapshot "$root" "$run/git-before.txt" || snap=false
    head_before=$(g -C "$root" rev-parse HEAD 2>/dev/null)
  fi

  # Codex runs as a child we wait for, so a signal is handled immediately and the
  # whole Codex process tree is stopped instead of left running. The trap is in
  # place before the child starts; the receipt is written before `exit`, so a
  # caller that sees `exit` always finds the final receipt.
  # The folder was checked by its physical path, and some time has passed (git,
  # the Windows folder query): if a folder on that path was replaced since, by a
  # link for example, the checked folder is no longer the one Codex would get.
  if [ "$(abspath "$wd")" != "$wd" ]; then
    echo "the working directory changed after it was checked" >> "$run/note.txt"
    fail_run "$run" 66
  fi
  if $worktree && [ "$sandbox" = workspace-write ]; then
    CLAIM_W+=("$(root_spelling "$wd")")
    claim "$run" || { echo "refusing to start: $CLAIM_ERROR" >> "$run/note.txt"; fail_run "$run" 66; }
  fi
  claim_unchanged || { echo "a folder changed after it was checked" >> "$run/note.txt"; fail_run "$run" 66; }
  local child=""
  trap '[ -n "$child" ] && kill_tree "$child"; wait "$child" 2>/dev/null; write_receipt "$run" 130; echo 130 >| "$run/exit"; exit 130' INT TERM HUP
  # Codex runs in a process group of its own, recorded in the claim before it
  # starts, so the claim holds as long as anything of that group runs (also
  # after the launcher is killed); what is left when Codex ends is stopped.
  printf 'starting %s\n' "$(date +%s)" >> "$CLAIM_FILE"
  CHILD_STARTED=true
  set -m
  ( cd -P -- "$wd" && [ "$(pwd -P)" = "$wd" ] \
      || { echo "the working directory changed after it was checked" >> "$run/note.txt"; exit 66; }
    printf 'pgid %s\n' "${BASHPID:-$(sh -c 'echo "$PPID"')}" >> "$CLAIM_FILE" || exit 66
    [ ${#TEMP_ENV[@]} -eq 0 ] || export "${TEMP_ENV[@]}"
    exec 9>&-   # never the claims lock
    exec codex "${args[@]}" < "$prompt" > "$run/events.jsonl" 2> "$run/stderr.txt" ) &
  child=$!
  set +m
  printf 'pgid %s\n' "$child" >> "$CLAIM_FILE"   # its group, recorded by both sides
  wait "$child"
  local code=$?
  if kill -0 -- "-$child" 2>/dev/null; then
    kill_tree "$child"
    echo "processes Codex left running were stopped" >> "$run/note.txt"
  fi
  trap - INT TERM HUP

  # Codex may have changed the repository (its .git file, config, links in the
  # git dir), so it is checked again before git runs on it once more.
  if [ -n "$root" ] && $snap && [ "$(git_meta_check "$root")" != "$gd_before" ]; then
    echo "the repository's git directory changed or gained links during the run; no change report" >> "$run/note.txt"
    snap=false
  fi
  if [ -n "$root" ] && $snap && snapshot "$root" "$run/git-after.txt"; then
    {
      # Lines are "<xy> <hash> <path>"; xy may start with a space, so strip by
      # position. comm indents its second column with a tab; paths are escaped,
      # so the only tab is that indent.
      LC_ALL=C comm -3 "$run/git-before.txt" "$run/git-after.txt" | tr -d '\t' | sed -E 's/^.. [^ ]+ //'
      local head_after entry; head_after=$(g -C "$root" rev-parse HEAD 2>/dev/null)
      if [ -n "$head_before" ] && [ "$head_before" != "$head_after" ]; then
        g -C "$root" diff -z --no-renames --name-only "$head_before" "$head_after" \
          | while IFS= read -r -d '' entry; do esc "$entry"; done
      fi
    } | LC_ALL=C sort -u > "$run/changed.txt"
  elif [ -n "$root" ]; then
    echo "git snapshot failed" >> "$run/note.txt"
  fi

  write_receipt "$run" "$code"
  echo "$code" >| "$run/exit"
  cat "$run/receipt.txt"
  return "$code"
}

fail_run() {   # finish a locked run that could not start: receipt first, then exit
  write_receipt "$1" "$2"
  echo "$2" >| "$1/exit"
  cat "$1/receipt.txt"
  exit "$2"
}

children() {   # direct child pids of $1 (pgrep, or ps where procps is missing)
  if command -v pgrep >/dev/null 2>&1; then pgrep -P "$1" 2>/dev/null
  else ps -A -o pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'; fi
}

descendants() {   # all descendant pids of $1, deepest first
  local c
  for c in $(children "$1"); do descendants "$c"; echo "$c"; done
}

kill_tree() {   # TERM the process tree of $1; KILL whatever is left after 10 s
  local pid=$1 i tree wpid
  tree=$(descendants "$pid")
  if $WINDOWS; then   # Codex runs as native Windows processes MSYS signals do not reach
    wpid=$(cat "/proc/$pid/winpid" 2>/dev/null)
    [ -n "$wpid" ] && taskkill //F //T //PID "$wpid" >/dev/null 2>&1
  fi
  # shellcheck disable=SC2086  # one pid per word
  [ -n "$tree" ] && kill -TERM $tree 2>/dev/null
  kill -TERM -- "-$pid" 2>/dev/null   # its process group, with what left the tree
  kill -TERM "$pid" 2>/dev/null
  # Wait until the child and every descendant captured above are gone; a
  # descendant that ignores TERM is not spared just because its parent exited.
  local alive p
  for i in $(seq 1 20); do
    alive=""
    for p in "$pid" $tree; do kill -0 "$p" 2>/dev/null && alive=1; done
    kill -0 -- "-$pid" 2>/dev/null && alive=1
    [ -z "$alive" ] && return 0
    sleep 0.5
  done
  # shellcheck disable=SC2086
  [ -n "$tree" ] && kill -KILL $tree 2>/dev/null
  kill -KILL -- "-$pid" 2>/dev/null
  kill -KILL "$pid" 2>/dev/null
}

preview() {   # first $2 bytes of $1, without a broken trailing UTF-8 character
  head -c "$2" "$1" | utf8_clean | ctl_clean
}

write_receipt() {
  local run=$1 code=${2:-} thread bytes=0 n
  [ -n "$code" ] || code=$(cat "$run/exit" 2>/dev/null || echo "?")
  thread=$(grep -oE '"thread_id" *: *"[A-Za-z0-9._:-]+"' "$run/events.jsonl" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  [ -z "$thread" ] && [ -f "$run/meta.txt" ] && thread=$(sed -n 's/^resume=//p' "$run/meta.txt")
  [ -f "$run/answer.md" ] && bytes=$(wc -c < "$run/answer.md" | tr -d ' ')
  {
    case $code in
      66) echo "Codex did not start (exit 66)." ;;
      130) echo "Run interrupted (exit 130)." ;;
      *) echo "Codex finished, exit $code." ;;
    esac
    echo
    echo "Answer:  $(winpath "$run/answer.md") ($bytes bytes)"
    echo "Thread:  ${thread:-unknown}"
    echo "Run dir: $(winpath "$run")"
    if [ -f "$run/branch" ]; then
      echo "Branch:  $(cat "$run/branch")  (uncommitted edits are in the worktree $(winpath "$run/worktree"))"
    fi
    if [ -f "$run/changed.txt" ]; then
      n=$(grep -c . "$run/changed.txt")
      if [ "$n" -eq 0 ]; then echo "Changed: nothing (Git-visible files)"
      else
        echo "Changed: $n path(s) (Git-visible files)"
        head -n "$MAX_LISTED" "$run/changed.txt" | sed 's/^/           /'
        [ "$n" -gt "$MAX_LISTED" ] && echo "           ... and $((n - MAX_LISTED)) more"
      fi
    else
      echo "Changed: unknown (not tracked)"
    fi
    [ -f "$run/note.txt" ] && sed 's/^/Note:    /' "$run/note.txt"
    if [ "$code" != 0 ]; then
      echo; echo "--- stderr (tail, at most $STDERR_BYTES bytes) ---"
      tail -n 20 "$run/stderr.txt" 2>/dev/null | tail -c "$STDERR_BYTES" | utf8_clean | ctl_clean; echo
    fi
    if [ "$bytes" -gt 0 ]; then
      echo
      if [ "$bytes" -gt "$PREVIEW_BYTES" ]; then
        echo "--- answer, first $PREVIEW_BYTES of $bytes bytes ---"
        preview "$run/answer.md" "$PREVIEW_BYTES"; echo; echo "[...truncated; read the Answer file for the rest]"
      else
        echo "--- answer ---"; ctl_clean < "$run/answer.md"; echo
      fi
    fi
  } | utf8_clean | ctl_clean >| "$run/receipt.txt"
}

cmd_receipt() {
  resolve_run "${1:-}"
  if [ ! -f "$RUN/exit" ]; then
    local pid=""
    [ -f "$RUN/pid" ] && read -r pid < "$RUN/pid"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      if [ -f "$RUN/claim" ] && claim_live "$RUN/claim"; then
        echo "LAUNCHER DIED, CODEX MAY STILL RUN: the launcher (pid $pid) is gone, but Codex's processes may not be (or it was starting under a minute ago); no receipt will be written: $(winpath "$RUN")"
        return 75
      fi
      echo "RUN DIED: the launcher (pid $pid) is gone and no exit code was recorded: $(winpath "$RUN")"
      return 70
    fi
    echo "STILL RUNNING: $(winpath "$RUN")"; return 75
  fi
  [ -f "$RUN/receipt.txt" ] || write_receipt "$RUN"
  cat "$RUN/receipt.txt"
}

case "${1:-}" in
  new) cmd_new ;;
  exec) shift; cmd_exec "$@" ;;
  receipt) shift; cmd_receipt "$@" ;;
  *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
