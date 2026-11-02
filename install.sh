#!/usr/bin/env bash
# install.sh - install (or remove) the codex-worker subagent for Claude Code.
#
#   ./install.sh [--model <id>] [--bash-exe <path>] [--force]
#   ./install.sh --uninstall [--purge] [--force]
#
#   --model <id>       Claude model for the thin dispatcher (default: claude-haiku-5-5)
#   --bash-exe <path>  Windows only: Git Bash used from the PowerShell tool (auto-detected)
#   --force            replace a codex-worker.md this installer did not create (backed up first)
#   --uninstall        remove the agent and the installed scripts
#   --purge            with --uninstall, also delete codex-worker run directories
#
# Honours CLAUDE_CONFIG_DIR (default ~/.claude) and CODEX_WORKER_RUNS.
set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CONFIG_DIR/codex-worker"
AGENT="$CONFIG_DIR/agents/codex-worker.md"
RUNS="${CODEX_WORKER_RUNS:-$HOME/.cache/codex-worker/runs}"
MARKER="<!-- installed-by: codex-worker -->"
ROOT_MARKER=".codex-worker-runs"
FILES="codex-run.sh codex-guard.mjs codex-guard.json findings.schema.json runs-root"

model="claude-haiku-5-5" bash_exe="" force=false uninstall=false purge=false

die() { echo "install: $*" >&2; exit 1; }
ok() { echo "  ok    $*"; }
warn() { echo "  warn  $*"; }
is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
owns_agent() { [ -f "$AGENT" ] && grep -qF "$MARKER" "$AGENT"; }
# Paths end up inside a shell command and the agent's instructions; refuse the
# characters that would need escaping there instead of trying to escape them.
safe_path() {
  case $1 in
    *[\"\'\$\`\\%!]*|*$'\n'*|*$'\r'*) die "unsupported character in path: $1 (avoid quotes, \$ \` % ! and backslashes)" ;;
  esac
}

while [ $# -gt 0 ]; do
  case $1 in
    --model) [ $# -ge 2 ] || die "--model needs a value"; model=$2; shift 2 ;;
    --bash-exe) [ $# -ge 2 ] || die "--bash-exe needs a value"; bash_exe=$2; shift 2 ;;
    --force) force=true; shift ;;
    --uninstall) uninstall=true; shift ;;
    --purge) purge=true; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ $model =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid model id: $model"
is_abs() {   # drive-letter paths are absolute only on Windows
  case $1 in /*) return 0 ;; [A-Za-z]:/*) is_windows ;; *) return 1 ;; esac
}
is_abs "$RUNS" || die "CODEX_WORKER_RUNS must be an absolute path: $RUNS"

# Removes only directories the launcher created (marker file + run-id names).
# A run's worktree is unregistered through the repository path the launcher
# recorded outside the worktree; Codex-writable content (the worktree's .git
# file) is never trusted. The worktree may hold links or NTFS junctions, and
# `git worktree remove` follows junctions while rm does not, so the run dir is
# emptied with rm, then only the matching registration is deleted. The `repo`
# file goes last so an interrupted purge can be retried. Returns 1 if anything
# was left behind; the root marker is then kept. Never deletes the root itself
# unless it is empty.
purge_runs() {
  # An inaccessible root (or ancestor) would hide the marker and look empty, so
  # it fails instead of counting as absent; the recorded runs root is then kept.
  # A runs root that is gone, or has no marker, is still taken off the per-user
  # list, where it would keep folders protected (spelled as the launcher would).
  local parent
  if [ ! -d "$RUNS" ]; then
    if gone "$RUNS"; then
      parent=$(cd "$(dirname "$RUNS")" 2>/dev/null && pwd -P) || parent=""
      unlist_root "$RUNS" && { [ -z "$parent" ] || unlist_root "${parent%/}/$(basename "$RUNS")"; }
      return
    fi
    warn "cannot reach $RUNS; fix access and purge again"; return 1
  fi
  [ -r "$RUNS" ] && [ -x "$RUNS" ] || { warn "cannot list $RUNS; fix access and purge again"; return 1; }
  if [ ! -f "$RUNS/$ROOT_MARKER" ]; then
    warn "$RUNS has no $ROOT_MARKER marker; not deleting anything there"
    unlist_root "$(cd "$RUNS" && pwd -P)"
    return
  fi
  local d n=0 failed=0 repo real_d pid pgid pg
  for d in "$RUNS"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [[ $(basename "$d") =~ ^[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ ]] || continue
    [ -r "$d" ] && [ -x "$d" ] || { warn "cannot read $d; fix access and purge again"; failed=1; continue; }
    read_state "$d/pid" && pid=$REPLY && read_state "$d/repo" && repo=$REPLY \
      || { warn "cannot read the state files in $d; fix access and purge again"; failed=1; continue; }
    # A run still in progress could change its worktree while it is removed.
    if [ ! -f "$d/exit" ] && [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      warn "$d is still running (pid $pid); not removing it"; failed=1; continue
    fi
    # Codex runs in a process group of its own, which can outlive the launcher.
    # Before it writes the pid file a run has a claim with the launcher's pid.
    pid=$(sed -n 's/^pid //p' "$d/claim" 2>/dev/null | head -n 1)
    if [ ! -f "$d/exit" ] && [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      warn "$d is still starting (pid $pid); not removing it"; failed=1; continue
    fi
    pgid=""
    for pg in $(sed -n 's/^pgid //p' "$d/claim" 2>/dev/null); do
      [[ $pg =~ ^[0-9]+$ ]] && kill -0 -- "-$pg" 2>/dev/null && pgid=$pg
    done
    if [ -n "$pgid" ]; then
      warn "$d still has Codex processes running (process group $pgid); not removing it"; failed=1; continue
    fi
    real_d=$(cd "$d" && pwd -P) || { warn "cannot enter $d"; failed=1; continue; }
    if ! clear_dir_except "$d" repo; then
      warn "could not fully remove $d; run --purge again once nothing uses it"; failed=1; continue
    fi
    if [ -n "$repo" ]; then
      if [ -d "$repo" ]; then unregister_worktree "$repo" "$real_d/worktree" || { failed=1; continue; }
      elif ! gone "$repo"; then warn "cannot reach repository $repo; fix access and purge again"; failed=1; continue
      fi
    fi
    if ! { rm -f "$d/repo" && rmdir "$d"; }; then warn "could not remove $d"; failed=1; continue; fi
    n=$((n + 1))
  done
  local runs_phys=""
  runs_phys=$(cd "$RUNS" 2>/dev/null && pwd -P)
  [ "$failed" = 0 ] && rm -f "$RUNS/$ROOT_MARKER"
  rmdir "$RUNS" 2>/dev/null
  # A runs root on the per-user list stays protected for write runs; once it is
  # purged it leaves the list, under the launchers' lock.
  if [ "$failed" = 0 ] && [ -n "$runs_phys" ]; then unlist_root "$runs_phys" || failed=1; fi
  ok "removed $n run director$( [ $n = 1 ] && echo y || echo ies ) (codex/* branches in your repos are kept)"
  return "$failed"
}

# Removes runs root $1 (as the launcher spells it) from the per-user list of runs
# roots, under the lock the launchers take for it.
unlist_root() {
  local state="$HOME/.cache/codex-worker"
  [ -f "$state/runs-roots" ] || return 0
  grep -qxF -- "$1" "$state/runs-roots" || return 0
  command -v perl >/dev/null 2>&1 || { warn "perl is missing; remove $1 from $state/runs-roots yourself"; return 1; }
  perl -e 'use Fcntl ":flock"; my ($lock, $list, $root) = @ARGV;
    open(my $l, ">>", $lock) or exit 1; flock($l, LOCK_EX) or exit 1;
    open(my $in, "<", $list) or exit 1; my @keep = grep { $_ ne "$root\n" } <$in>; close $in;
    open(my $out, ">", "$list.new") or exit 1; print $out @keep; close $out or exit 1;
    rename("$list.new", $list) or exit 1' "$state/claims.flock" "$state/runs-roots" "$1" \
    || { warn "could not remove $1 from $state/runs-roots"; return 1; }
}

# Reads the first line of a run's state file $1 into REPLY ("" if there is no
# such file). Returns 1 if it exists but is not a plain, readable file.
read_state() {
  REPLY=""
  [ -e "$1" ] || [ -L "$1" ] || return 0
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 1
  IFS= read -r REPLY < "$1" || [ -n "$REPLY" ] || [ ! -s "$1" ]
}

# True if there is no directory at path $1 any more, as opposed to one hidden
# behind a directory without search permission: something that is not a
# directory is gone, and otherwise the deepest existing ancestor must be a
# searchable directory (or not a directory at all).
gone() {
  local p=$1 below=false t n=0
  while [ "$n" -lt 40 ]; do
    if [ -e "$p" ]; then
      if $below; then [ ! -d "$p" ] || [ -x "$p" ]; else [ ! -d "$p" ]; fi
      return
    fi
    # A link that cannot be followed may lead behind an unsearchable directory,
    # so the walk continues where it points (the path itself or an ancestor).
    if [ -L "$p" ]; then
      t=$(readlink -- "$p") || return 1
      case $t in /*) ;; *) t="${p%/*}/$t" ;; esac
      p=$t; n=$((n + 1)); continue
    fi
    below=true; p=$(dirname "$p")
  done
  return 1
}

# Deletes every entry of directory $1 except the one named $2, without following
# links. Codex may have left directories without write or search permission, so
# a failed rm makes the entry's tree accessible and tries once more: `chmod -R`
# does not follow links met during the traversal (GNU and BSD), and a link given
# as the entry itself is never passed to it.
clear_dir_except() {
  local e rc=0
  [ -r "$1" ] && [ -x "$1" ] || return 1   # a directory that cannot be listed would look empty
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "$e" = "$1/$2" ] && continue
    rm -rf "$e" 2>/dev/null && continue
    [ -L "$e" ] || chmod -R u+rwx "$e" 2>/dev/null
    rm -rf "$e" || rc=1
  done
  return "$rc"
}

# Deletes the registration of the worktree at $2 (a physical path) from
# repository $1: only real, non-link admin dirs physically inside
# <common>/worktrees whose gitdir file names it. The gitdir file goes last, so a
# partly removed registration is still found on a retry. Returns 1 if the
# repository could not be read or a matching registration could not be removed.
unregister_worktree() {
  local want common wts a admin line
  want=$(norm_path "$2/.git")
  # The dot keeps a newline at the end of the path, which would name another folder.
  common=$(git -c core.fsmonitor=false -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null && printf .) \
    && common=${common%.} && common=${common%$'\n'} && [ -n "$common" ] && [[ $common != *$'\n'* ]] || {
    warn "could not read repository $1 (git 2.31+ needed, or it is unusable); fix it and purge again, or delete the run dir and run there: git worktree prune"
    return 1
  }
  unreadable() { warn "cannot read $1 (a worktree registration); fix access and purge again"; }
  gone "$common/worktrees" && return 0
  # A link is not ours to clean up; a junction need not test as -L on every
  # system, so physical paths are compared too.
  [ -d "$common/worktrees" ] && [ ! -L "$common/worktrees" ] || return 0
  [ -r "$common/worktrees" ] && [ -x "$common/worktrees" ] || { unreadable "$common/worktrees"; return 1; }
  wts=$(cd "$common/worktrees" && pwd -P) || { unreadable "$common/worktrees"; return 1; }
  [ "$wts" = "$(cd "$common" && pwd -P)/worktrees" ] || return 0
  for admin in "$wts"/*; do
    [ -d "$admin" ] && [ ! -L "$admin" ] || continue
    [ -r "$admin" ] && [ -x "$admin" ] || { unreadable "$admin"; return 1; }
    [ "$(cd "$admin" && pwd -P)" = "$admin" ] || continue
    a="$admin/gitdir"
    [ -f "$a" ] && [ ! -L "$a" ] || continue
    [ -r "$a" ] || { unreadable "$a"; return 1; }
    line=""; IFS= read -r line < "$a" || [ -n "$line" ] || continue
    # worktree.useRelativePaths; git counts the ".." in Windows spelling, where
    # a Git Bash mount such as /tmp has another parent.
    is_abs "$line" || line="$(winpath "$admin")/$line"
    [ "$(norm_path "$(lexical "$line")")" = "$want" ] || continue
    if ! { clear_dir_except "$admin" gitdir && rm -f "$a" && rmdir "$admin"; }; then
      warn "could not remove the worktree registration $admin"; return 1
    fi
  done
  return 0
}

# Resolves . and .. in a path without touching the disk.
lexical() {
  local part lead="" out=() parts=()
  case $1 in /*) lead=/ ;; esac
  IFS=/ read -ra parts <<< "$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case $part in
      ''|.) ;;
      ..) [ ${#out[@]} = 0 ] || unset "out[$((${#out[@]} - 1))]" ;;
      *) out[${#out[@]}]=$part ;;
    esac
  done
  local IFS=/
  printf '%s%s\n' "$lead" ${out[@]+"${out[*]}"}
}

norm_path() {   # comparable form of a path: forward slashes, lower case on Windows
  local p; p=$(winpath "$1")
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ] && [[ $p != [A-Za-z]:/ ]]; do p=${p%/}; done   # no trailing slash
  if is_windows; then printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]'; else printf '%s\n' "$p"; fi
}

# Refuses to act through symbolic links on the files and folders this installer
# owns. A symlinked config dir itself (dotfile managers) is fine.
no_links() {
  local f
  for f in "$DEST" "$(dirname "$AGENT")" "$AGENT" "$RUNS"; do
    [ -L "$f" ] && die "refusing to work through a symbolic link: $f"
  done
  return 0
}

do_uninstall() {
  # Purge the root this installation actually used, unless one is given explicitly.
  local recorded=""
  if [ -f "$DEST/runs-root" ] && [ ! -L "$DEST/runs-root" ]; then
    IFS= read -r recorded < "$DEST/runs-root" || [ -n "$recorded" ]
  fi
  if [ -n "$recorded" ] && ! is_abs "$recorded"; then
    warn "$DEST/runs-root does not hold an absolute path; ignoring it"
    recorded=""   # nothing usable to keep
  fi
  [ -z "${CODEX_WORKER_RUNS:-}" ] && [ -n "$recorded" ] && RUNS=$recorded
  no_links
  if [ -e "$AGENT" ]; then
    if owns_agent || $force; then rm -f "$AGENT" && ok "removed $AGENT"
    else die "$AGENT was not created by this installer; re-run with --force to remove it"; fi
  fi
  local f
  for f in $FILES; do
    [ "$f" = runs-root ] && $purge && continue   # kept until the purge succeeds, so it can be retried
    [ -f "$DEST/$f" ] && rm -f "$DEST/$f"
  done
  local rc=0
  if $purge; then
    if ! purge_runs; then
      warn "some run data is left; kept $DEST/runs-root so --uninstall --purge can be run again"; rc=1
    elif [ -n "$recorded" ] && [ "$(norm_path "$recorded")" != "$(norm_path "$RUNS")" ]; then
      warn "kept $DEST/runs-root: the recorded runs root $recorded was not purged (run --uninstall --purge without CODEX_WORKER_RUNS)"
    else
      rm -f "$DEST/runs-root"
    fi
  fi
  rmdir "$DEST" 2>/dev/null && ok "removed $DEST"
  echo "Done. Restart Claude Code so the agent list is reloaded."
  return "$rc"
}

check_prereqs() {
  echo "Prerequisites:"
  command -v node >/dev/null 2>&1 || die "node not found (needed for the guard hook)"
  node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' \
    || die "Node.js 18 or newer is required (found $(node --version))"
  ok "node $(node --version)"
  command -v git >/dev/null 2>&1 || die "git not found"; ok "$(git --version)"
  if command -v codex >/dev/null 2>&1; then
    ok "$(codex --version 2>/dev/null | head -1)"
    if codex login status >/dev/null 2>&1; then ok "codex is logged in"
    else warn "codex is not logged in; run: codex login"; fi
  else
    warn "codex CLI not found; install it with: npm install -g @openai/codex"
  fi
  if command -v claude >/dev/null 2>&1; then ok "$(claude --version 2>/dev/null | head -1)"
  else warn "claude not on PATH (fine if you only use the desktop app)"; fi
}

resolve_bash_exe() {
  is_windows || { bash_exe=""; return 0; }
  if [ -z "$bash_exe" ]; then
    # Git Bash's own root; bin/bash.exe is the launcher that sets up PATH correctly.
    # Plain `bash` in PowerShell usually resolves to WSL, so it is never used.
    bash_exe="$(cygpath -m /)/bin/bash.exe"
  fi
  bash_exe=$(winpath "$bash_exe"); bash_exe=${bash_exe//\/\//\/}
  [ -f "$bash_exe" ] || die "Git Bash not found at $bash_exe; pass --bash-exe <path to Git\\bin\\bash.exe>"
  ok "Git Bash for the PowerShell tool: $bash_exe"
}

# Runs the installed guard on a synthetic hook event; prints its exit code.
guard_probe() {
  printf '%s' "$1" | node "$DEST/codex-guard.mjs" "$DEST/codex-guard.json" >/dev/null 2>&1
  echo $?
}

# Warns when folder $1 ($2 in the message) is in a temporary folder: the launcher
# refuses every write run then, as Codex may write there (read-only runs work).
# The same folders as the launcher's are compared by identity with $1 (from its
# deepest existing folder, where it physically lives) and each folder above it,
# walked in Windows spelling, as Git Bash mounts such as /tmp have other parents.
warn_temp() {
  local t d x
  local -a ts=(/tmp /var/tmp /private/tmp /private/var/tmp "${TMPDIR-}")
  is_windows && ts+=("${TEMP-}" "${TMP-}")
  [ "$(uname -s)" = Darwin ] && ts+=("$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)")
  d=$1
  while [ ! -d "$d" ] && [[ $d == */* ]]; do d=${d%/*}; done
  d=$(cd "${d:-/}" 2>/dev/null && pwd -P) || return 0
  d=$(winpath "$d")
  for t in "${ts[@]}"; do
    [ -n "$t" ] && [ -d "$t" ] || continue
    x=$d
    while :; do
      if [ "$t" -ef "$x" ]; then
        warn "$2 ($1) is in the temporary folder $t, which Codex may write to: write runs will be refused (read-only runs work). Install with CODEX_WORKER_RUNS and CLAUDE_CONFIG_DIR elsewhere to allow them."
        return 0
      fi
      case $x in / | [A-Za-z]:/ | [A-Za-z]:) break ;; esac
      [[ $x == */* ]] || break
      x=${x%/*}
      case $x in "" | /) x=/ ;; [A-Za-z]:) x="$x/" ;; esac
    done
  done
}

do_install() {
  check_prereqs
  resolve_bash_exe
  local launcher guard config schema runs_w
  launcher=$(winpath "$DEST/codex-run.sh"); guard=$(winpath "$DEST/codex-guard.mjs")
  config=$(winpath "$DEST/codex-guard.json"); schema=$(winpath "$DEST/findings.schema.json")
  # The launcher prints physical paths (pwd -P), so the guard must compare against
  # the physical runs root too (e.g. /var -> /private/var on macOS).
  if [ ! -d "$RUNS" ]; then mkdir -p "$RUNS" && chmod 700 "$RUNS" || die "cannot create $RUNS"; fi
  runs_w=$(winpath "$(cd "$RUNS" && pwd -P)") || die "cannot resolve $RUNS"
  for p in "$launcher" "$guard" "$config" "$schema" "$runs_w" "$(winpath "$AGENT")" ${bash_exe:+"$bash_exe"}; do
    safe_path "$p"
  done
  warn_temp "$RUNS" "the runs root"
  warn_temp "$DEST" "the Claude configuration"
  echo

  # Never write through links: every target is a real file in a real directory,
  # replaced by renaming an exclusively created temporary sibling over it.
  no_links
  local f bak
  if [ -e "$AGENT" ] && ! owns_agent; then
    $force || die "$AGENT exists and was not created by this installer; re-run with --force to back it up and replace it"
    bak=$(mktemp "$AGENT.bak.XXXXXX") && cp -p "$AGENT" "$bak" || die "could not back up $AGENT; nothing was changed"
    warn "backed up the existing agent to $bak"
  fi
  mkdir -p "$DEST" "$(dirname "$AGENT")" || die "cannot create $DEST"
  for f in $FILES; do [ -L "$DEST/$f" ] && die "refusing to overwrite a symbolic link: $DEST/$f"; done
  # mktemp creates each temporary file exclusively, so nothing can be pre-planted there.
  put() {
    local t; t=$(mktemp "$DEST/.$2.XXXXXX") || die "cannot create a temporary file in $DEST"
    cp "$1" "$t" && chmod 644 "$t" && mv -f "$t" "$DEST/$2" || { rm -f "$t"; die "installing $2 failed"; }
  }
  put "$HERE/bin/codex-run.sh" codex-run.sh
  put "$HERE/hooks/codex-guard.mjs" codex-guard.mjs
  put "$HERE/schemas/findings.schema.json" findings.schema.json
  chmod +x "$DEST/codex-run.sh" "$DEST/codex-guard.mjs"

  local t
  t=$(mktemp "$DEST/.codex-guard.json.XXXXXX") || die "cannot create a temporary file in $DEST"
  V_LAUNCHER="$launcher" V_BASH="$bash_exe" V_RUNS="$runs_w" V_SCHEMA="$schema" OUT="$t" \
  node -e '
    const e = process.env;
    const cfg = { launcher: e.V_LAUNCHER, bashExe: e.V_BASH || null, runsRoot: e.V_RUNS, schema: e.V_SCHEMA };
    require("fs").writeFileSync(e.OUT, JSON.stringify(cfg, null, 2) + "\n");
  ' && mv -f "$t" "$DEST/codex-guard.json" || { rm -f "$t"; die "writing the guard configuration failed"; }
  # The installed launcher reads this file, so it always agrees with the guard.
  t=$(mktemp "$DEST/.runs-root.XXXXXX") || die "cannot create a temporary file in $DEST"
  { printf '%s\n' "$runs_w" > "$t" && mv -f "$t" "$DEST/runs-root"; } || { rm -f "$t"; die "writing $DEST/runs-root failed"; }
  ok "installed scripts into $DEST"

  local ps_line tmp
  if [ -n "$bash_exe" ]; then
    ps_line="- **PowerShell tool:** \`& \"$bash_exe\" \"$launcher\"\` (always this exact Git Bash path; plain \`bash\` in PowerShell is usually WSL)"
  else
    ps_line="- **PowerShell tool:** not used on this platform; use the Bash tool."
  fi
  tmp=$(mktemp "$(dirname "$AGENT")/.codex-worker.XXXXXX") || die "cannot create a temporary file next to $AGENT"
  TMPL="$HERE/agent/codex-worker.md.tmpl" OUT="$tmp" MARK="$MARKER" \
  V_MODEL="$model" V_GUARD_COMMAND_JSON="$(GUARD="$guard" CFG="$config" node -e 'process.stdout.write(JSON.stringify(`node "${process.env.GUARD}" "${process.env.CFG}"`))')" \
  V_LAUNCHER="$launcher" V_POWERSHELL_LINE="$ps_line" V_SCHEMA="$schema" \
  V_RUNS_EXAMPLE="$runs_w/20260101-120000-123-456" \
  node -e '
    const fs = require("fs");
    let body = fs.readFileSync(process.env.TMPL, "utf8");
    for (const key of ["MODEL", "GUARD_COMMAND_JSON", "LAUNCHER", "POWERSHELL_LINE", "SCHEMA", "RUNS_EXAMPLE"]) {
      body = body.split("{{" + key + "}}").join(process.env["V_" + key]);
    }
    const left = body.match(/\{\{[A-Z_]+\}\}/);
    if (left) { console.error("unrendered placeholder " + left[0]); process.exit(1); }
    fs.writeFileSync(process.env.OUT, body.trimEnd() + "\n\n" + process.env.MARK + "\n");
  ' || { rm -f "$tmp"; die "rendering the agent failed"; }
  mv -f "$tmp" "$AGENT" || { rm -f "$tmp"; die "cannot write $AGENT"; }
  ok "installed agent $AGENT (dispatcher model: $model)"

  echo
  echo "Self-check:"
  bash -n "$DEST/codex-run.sh" || die "launcher has a syntax error"; ok "launcher syntax"
  node --check "$DEST/codex-guard.mjs" || die "guard has a syntax error"; ok "guard syntax"
  local probe_run ev
  probe_run=$(CODEX_WORKER_RUNS="" bash "$DEST/codex-run.sh" new) || die "launcher self-test failed: 'new' did not work"
  probe_fail() { rmdir "$probe_run" 2>/dev/null; die "$1"; }
  [ "$(dirname "$probe_run")" = "$runs_w" ] || probe_fail "launcher and guard disagree on the runs root"
  ev=$(L="$launcher" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:`"${process.env.L}" new`}}))')
  [ "$(guard_probe "$ev")" = 0 ] || probe_fail "guard self-test failed: the launcher itself was blocked"
  [ "$(guard_probe '{"tool_name":"Bash","tool_input":{"command":"codex exec -s danger-full-access x"}}')" = 2 ] \
    || probe_fail "guard self-test failed: a direct codex call was not blocked"
  ev=$(P="$probe_run/prompt.txt" node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.env.P}}))')
  [ "$(guard_probe "$ev")" = 0 ] || probe_fail "guard self-test failed: writing prompt.txt was blocked"
  rmdir "$probe_run"
  ev=$(L="$launcher" R="$probe_run" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:`"${process.env.L}" exec "${process.env.R}" -d "x”; whoami; “y"`}}))')
  [ "$(guard_probe "$ev")" = 2 ] || die "guard self-test failed: a smart-quote injection was not blocked"
  [ "$(guard_probe '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.sh"}}')" = 2 ] \
    || die "guard self-test failed: an arbitrary write was not blocked"
  [ "$(guard_probe 'not json')" = 2 ] || die "guard self-test failed: malformed input was not blocked"
  ok "guard allows the launcher and blocks everything else"

  echo
  echo "Done. Start a NEW Claude Code session (agents are loaded at startup), then ask e.g.:"
  echo "  \"Use codex-worker to review src/ in <repo>, read only.\""
}

if $uninstall; then do_uninstall; else do_install; fi
