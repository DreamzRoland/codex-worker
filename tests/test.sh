#!/usr/bin/env bash
# tests/test.sh - offline test suite for codex-worker.
#
# Uses a stub `codex` on PATH and a temporary CLAUDE_CONFIG_DIR, so it needs no
# network, no OpenAI account and never touches your real ~/.claude. Every script
# is run with the same bash that runs this file, so `/bin/bash tests/test.sh`
# on macOS exercises bash 3.2.
#
#   bash tests/test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$BASH"
RUNNER="$ROOT/bin/codex-run.sh"
GUARD="$ROOT/hooks/codex-guard.mjs"
# Codex may write to the temporary folders, so write runs refuse any protected
# folder there (the runs root, the Claude configuration, a home): the tests live
# in a folder in the home instead, with one in the system temp folder for the
# cases that need it. A failed mktemp must not leave a name the cleanup removes.
TMP=$(mktemp -d "${CODEX_WORKER_TEST_DIR:-$HOME}/codex-worker-test.XXXXXX") && TMP=$(cd "$TMP" && pwd -P) && [ -n "$TMP" ] \
  || { echo "cannot create a test folder in ${CODEX_WORKER_TEST_DIR:-$HOME} (set CODEX_WORKER_TEST_DIR to a writable folder outside the temporary folders)" >&2; exit 2; }
SYS_TMP=$(mktemp -d) && SYS_TMP=$(cd "$SYS_TMP" && pwd -P) && [ -n "$SYS_TMP" ] \
  || { rm -rf "$TMP"; echo "cannot create a temporary folder" >&2; exit 2; }
trap 'chmod -R u+rwx "$TMP" "$SYS_TMP" 2>/dev/null; rm -rf "$TMP" "$SYS_TMP"' EXIT
# Windows exports TMP, which the launcher counts as a temporary folder.
export -n TMP
RUNS="$TMP/runs"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=true ;; *) WINDOWS=false ;; esac
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
# Minor version of git 2.x; any later major version counts as new enough.
GIT_MINOR=$(git --version | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/' | awk '{ print ($1 > 2) ? 999 : $2 }')

export CODEX_WORKER_RUNS="$RUNS"
export CODEX_WORKER_STATE="$TMP/state"
export CLAUDE_CONFIG_DIR="$TMP/claude"
export CODEX_HOME="$TMP/codex-home"
export STUB_ARGS="$TMP/args.txt"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
UUID=01a195e3-567d-7ee3-a95d-30a2901a57c5

pass=0 fail=0 skip=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "condition: $2"; fi; }
skipped() { skip=$((skip + 1)); echo "  skip  $1"; }
has_arg() { grep -qxF -- "$1" "$STUB_ARGS"; }
arg_after() { grep -A1 -xF -- "$1" "$STUB_ARGS" | sed -n 2p; }

# --- stub codex --------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.0.0-stub"; exit 0 ;;
  login) exit 0 ;;
esac
printf '%s\n' "$@" > "$STUB_ARGS"
printf '%s\n' "${LC_ALL-unset}" > "$STUB_ARGS.lc_all"
printf '%s\n' "${TMPDIR-unset}" > "$STUB_ARGS.tmpdir"
printf '%s\n' "${TEMP-unset}" > "$STUB_ARGS.temp"
out="" cd_dir="" prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out=$a
  [ "$prev" = "-C" ] && cd_dir=$a
  prev=$a
done
cat > /dev/null
[ -n "$cd_dir" ] && cd "$cd_dir"
pwd -P > "$STUB_ARGS.cwd"
echo '{"type":"thread.started","thread_id":"stub-thread-1"}'
[ -n "${STUB_TOUCH:-}" ] && echo "edited by stub" >> "$STUB_TOUCH"
[ -n "${STUB_LINK:-}" ] && ln -s /nonexistent "$STUB_LINK"
if [ -n "${STUB_COMMIT:-}" ]; then
  echo committed > "$STUB_COMMIT" && git add -- "$STUB_COMMIT" && git commit -qm stub
fi
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ -n "${STUB_BIG_STDERR:-}" ] && head -c 200000 /dev/zero | tr '\0' x >&2
[ -n "${STUB_UTF8_STDERR:-}" ] && { printf 'x'; for i in $(seq 1 3000); do printf '中'; done; echo; } >&2
[ -n "$out" ] && printf '%s\n' "${STUB_ANSWER:-STUB ANSWER}" > "$out"
[ "${STUB_EXIT:-0}" != 0 ] && echo "stub failure" >&2
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"

new_repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir" && git -C "$dir" init -q && git -C "$dir" config core.autocrlf false
  echo original > "$dir/tracked.txt"
  git -C "$dir" add . && git -C "$dir" commit -qm init
  printf '%s\n' "$dir"
}

new_run() {
  local run; run=$("$SH" "$RUNNER" new) && echo "the task" > "$run/prompt.txt"
  printf '%s\n' "$run"
}

# Runs `exec` on a fresh run dir; sets RUN and CODE.
run_exec() {
  RUN=$(new_run)
  "$SH" "$RUNNER" exec "$RUN" "$@" >/dev/null 2>&1
  # shellcheck disable=SC2034  # read inside check strings
  CODE=$?
}

echo "Launcher: argument validation"
REPO=$(new_repo repo)
for bad_args in "-s danger-full-access -d $REPO" "-d $TMP/nope" "-e turbo -d $REPO" \
                "-n -s read-only -d $REPO" "-m bad;name -d $REPO" "-m --yolo -d $REPO" \
                "-r --yolo -d $REPO" "-r not-a-uuid -d $REPO" "" "-s read-only" \
                "-d $REPO stray -s read-only"; do
  # shellcheck disable=SC2086  # deliberate word splitting of the option list
  run_exec $bad_args
  check "rejects [${bad_args:-no options}]" '[ "$CODE" = 64 ]'
done
for protected in "$TMP" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$RUNS" "$HOME" /; do
  run_exec -d "$protected"
  check "refuses working directory $protected" '[ "$CODE" = 64 ]'
done
# A run dir in a temporary folder could be swapped for a link by Codex before the
# launcher writes the receipt there: write runs are refused, read-only runs not.
TRUN=$(CODEX_WORKER_RUNS="$SYS_TMP/runs" "$SH" "$RUNNER" new) && echo task > "$TRUN/prompt.txt"
CODEX_WORKER_RUNS="$SYS_TMP/runs" "$SH" "$RUNNER" exec "$TRUN" -d "$REPO" >/dev/null 2>"$TMP/tmp-runs.err"; TCODE=$?
check "refuses a write run whose run dir is in a temporary folder" '[ "$TCODE" = 64 ] && grep -q "temporary folder" "$TMP/tmp-runs.err"'
# The temporary folders get the same checks as -d: no protected folder there.
mkdir -p "$SYS_TMP/claude"
RUN=$(new_run); CLAUDE_CONFIG_DIR="$SYS_TMP/claude" "$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>"$TMP/tmp-cfg.err"; TCODE=$?
check "refuses a write run while the Claude configuration is in a temporary folder" '[ "$TCODE" = 64 ] && grep -q "temporary folder" "$TMP/tmp-cfg.err"'
TRUN=$(CODEX_WORKER_RUNS="$SYS_TMP/runs" "$SH" "$RUNNER" new) && echo task > "$TRUN/prompt.txt"
CODEX_WORKER_RUNS="$SYS_TMP/runs" "$SH" "$RUNNER" exec "$TRUN" -d "$REPO" -s read-only >/dev/null 2>&1; TCODE=$?
check "read-only runs may keep their run dir in a temporary folder" '[ "$TCODE" = 0 ]'
# That runs root is now on the per-user list, whose roots every write run
# protects (with or without their marker) until they leave the list.
unlist() { local p; p=$(cd "$1" 2>/dev/null && pwd -P) || p=$1; grep -vxF -- "$p" "$CODEX_WORKER_STATE/runs-roots" > "$TMP/roots.new"; mv "$TMP/roots.new" "$CODEX_WORKER_STATE/runs-roots"; }
unlist "$SYS_TMP/runs"
# Codex gets the temporary folders by their physical paths (a link on the way
# could be changed during the run), and no writable root may lie inside another,
# as the run could replace the inner one while Codex runs.
same_place() { if $WINDOWS; then [ "$(cygpath -u -- "$(cygpath -m -- "$1")")" = "$(cygpath -u -- "$(cygpath -m -- "$2")")" ]; else [ "$1" = "$2" ]; fi; }
tmp_exec() { RUN=$(new_run); env "$@" "$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>"$TMP/tmpdir.err"; CODE=$?; }
mkdir -p "$TMP/tdir" "$TMP/tdir-real" "$TMP/tdir-cwd"; : > "$TMP/tdir-file"
tmp_exec TMPDIR="$TMP/tdir"
check "a TMPDIR outside -d is allowed and passed on" '[ "$CODE" = 0 ] && same_place "$(cat "$STUB_ARGS.tmpdir")" "$TMP/tdir"'
if $WINDOWS; then cmd //c mklink //J "$(cygpath -w "$TMP/tdir-link")" "$(cygpath -w "$TMP/tdir-real")" >/dev/null 2>&1
else ln -s "$TMP/tdir-real" "$TMP/tdir-link"; fi
tmp_exec TMPDIR="$TMP/tdir-link"
check "a linked TMPDIR is passed on where it physically lives" '[ "$CODE" = 0 ] && same_place "$(cat "$STUB_ARGS.tmpdir")" "$TMP/tdir-real"'
tmp_exec TMPDIR="$TMP/tdir-real/../tdir"
check "a TMPDIR with .. is passed on resolved" '[ "$CODE" = 0 ] && same_place "$(cat "$STUB_ARGS.tmpdir")" "$TMP/tdir"'
RUN=$(new_run); (cd "$TMP/tdir-cwd" && TMPDIR=../tdir "$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>&1); TCODE=$?
check "a relative TMPDIR is passed on as an absolute path" '[ "$TCODE" = 0 ] && same_place "$(cat "$STUB_ARGS.tmpdir")" "$TMP/tdir"'
tmp_exec TMPDIR="$HOME"
check "refuses a write run with TMPDIR set to the home, and says what to do" '[ "$CODE" = 64 ] && grep -q "point TMPDIR at another folder" "$TMP/tmpdir.err"'
tmp_exec TMPDIR="$REPO/sub"
check "refuses a TMPDIR that does not exist" '[ "$CODE" = 64 ] && grep -q "not a folder that can be entered" "$TMP/tmpdir.err"'
tmp_exec TMPDIR="$TMP/tdir-file"
check "refuses a TMPDIR that is a file" '[ "$CODE" = 64 ] && grep -q "not a folder that can be entered" "$TMP/tmpdir.err"'
mkdir -p "$REPO/sub"
tmp_exec TMPDIR="$REPO/sub"
check "refuses a TMPDIR inside -d" '[ "$CODE" = 64 ] && grep -q "lies inside the writable folder" "$TMP/tmpdir.err"'
rmdir "$REPO/sub"
mkdir -p "$SYS_TMP/proj"
RUN=$(new_run); "$SH" "$RUNNER" exec "$RUN" -d "$SYS_TMP/proj" >/dev/null 2>"$TMP/tmpdir.err"; TCODE=$?
check "refuses a working directory inside a temporary folder" '[ "$TCODE" = 64 ] && grep -q "lies inside it" "$TMP/tmpdir.err"'
RUN=$(new_run); "$SH" "$RUNNER" exec "$RUN" -d "$SYS_TMP/proj" -s read-only >/dev/null 2>&1; TCODE=$?
check "read-only runs may work inside a temporary folder" '[ "$TCODE" = 0 ]'
tmp_exec TMPDIR="$SYS_TMP"
check "refuses a TMPDIR inside another temporary folder" '[ "$CODE" = 64 ] && grep -q "lies inside the writable folder" "$TMP/tmpdir.err"'
check "a refused working directory comes with what to do" \
  '"$SH" "$RUNNER" exec "$(new_run)" -d "$CODEX_HOME" 2>&1 >/dev/null | grep -q "choose another working directory, or use -s read-only"'
if $WINDOWS; then
  tmp_exec TEMP="$TMP/tdir"
  check "TEMP is passed on where it physically lives" '[ "$CODE" = 0 ] && same_place "$(cat "$STUB_ARGS.temp")" "$TMP/tdir"'
  tmp_exec -u TEMP Temp="$TMP/tdir"
  check "refuses a temporary folder variable in another case (Temp)" '[ "$CODE" = 64 ] && grep -q "besides the usual spelling" "$TMP/tmpdir.err"'
  RUN=$(new_run); TMPDIR="$(cygpath -w "$TMP/tdir")" "$SH" "$RUNNER" exec "$RUN" -d "$TMP/tdir" >/dev/null 2>&1; TCODE=$?
  check "a TMPDIR in Windows spelling equal to -d counts once" '[ "$TCODE" = 0 ]'
elif [ "$(id -u)" != 0 ]; then
  mkdir -p "$TMP/tdir-locked"; chmod 000 "$TMP/tdir-locked"
  tmp_exec TMPDIR="$TMP/tdir-locked"
  check "refuses a TMPDIR that cannot be entered" '[ "$CODE" = 64 ] && grep -q "not a folder that can be entered" "$TMP/tmpdir.err"'
  chmod 755 "$TMP/tdir-locked"
fi
# Settings may live where a link inside a protected folder leads, or where XDG
# variables say: those places are protected too.
mkdir -p "$TMP/dotfiles/claude-plugin" "$TMP/xdg-config"
if $WINDOWS; then cmd //c mklink //J "$(cygpath -w "$CLAUDE_CONFIG_DIR/linked-plugin")" "$(cygpath -w "$TMP/dotfiles/claude-plugin")" >/dev/null 2>&1
else ln -s "$TMP/dotfiles/claude-plugin" "$CLAUDE_CONFIG_DIR/linked-plugin"; fi
run_exec -d "$TMP/dotfiles"
check "refuses a working directory holding the target of a link in the Claude configuration" '[ "$CODE" = 64 ]'
if $WINDOWS; then cmd //c rmdir "$(cygpath -w "$CLAUDE_CONFIG_DIR/linked-plugin")" >/dev/null 2>&1; else rm "$CLAUDE_CONFIG_DIR/linked-plugin"; fi
RUN=$(new_run); XDG_CONFIG_HOME="$TMP/xdg-config" "$SH" "$RUNNER" exec "$RUN" -d "$TMP/xdg-config" >/dev/null 2>&1; TCODE=$?
check "refuses XDG_CONFIG_HOME as working directory" '[ "$TCODE" = 64 ]'
# A configuration folder that is a link is walked where it lives, and links to
# folders inside a protected folder are followed to further links.
mkdir -p "$TMP/claude-real" "$TMP/dotf2" "$TMP/nestreal" "$TMP/deeptarget"
mklink_dir() { if $WINDOWS; then cmd //c mklink //J "$(cygpath -w "$1")" "$(cygpath -w "$2")" >/dev/null 2>&1; else ln -s "$2" "$1"; fi; }
rmlink_dir() { if $WINDOWS; then cmd //c rmdir "$(cygpath -w "$1")" >/dev/null 2>&1; else rm "$1"; fi; }
mklink_dir "$TMP/claude-link" "$TMP/claude-real"; mklink_dir "$TMP/claude-real/plugin" "$TMP/dotf2"
RUN=$(new_run); CLAUDE_CONFIG_DIR="$TMP/claude-link" "$SH" "$RUNNER" exec "$RUN" -d "$TMP/dotf2" >/dev/null 2>&1; TCODE=$?
check "a linked Claude configuration still protects what its links lead to" '[ "$TCODE" = 64 ]'
mklink_dir "$CLAUDE_CONFIG_DIR/nest" "$TMP/nestreal"; mklink_dir "$TMP/nestreal/deep" "$TMP/deeptarget"
run_exec -d "$TMP/deeptarget"
check "a link inside a linked folder of the configuration is followed too" '[ "$CODE" = 64 ]'
rmlink_dir "$TMP/nestreal/deep"; rmlink_dir "$CLAUDE_CONFIG_DIR/nest"; rmlink_dir "$TMP/claude-real/plugin"; rmlink_dir "$TMP/claude-link"
run_exec -d "$TMP/deeptarget"
check "once those links are gone the folder is fine" '[ "$CODE" = 0 ]'
# Concurrent write runs: a live claim (its launcher is this shell) on $REPO
# refuses a run in $REPO/sub, and one in $REPO itself (whose git that run uses).
claim_exec() { RUN=$(new_run); "$SH" "$RUNNER" exec "$RUN" "$@" >/dev/null 2>"$TMP/claim.err"; CODE=$?; }
LIVE=$(new_run); printf 'pid %s\nw %s\nr %s\n' "$$" "$REPO" "$REPO" > "$LIVE/claim"
mkdir -p "$REPO/sub"
claim_exec -d "$REPO/sub"
check "refuses a write run inside the working directory of a running one" \
  '[ "$CODE" = 64 ] && grep -q "is still running" "$TMP/claim.err"'
claim_exec -d "$REPO"
check "refuses a write run in the working directory of a running one" '[ "$CODE" = 64 ]'
claim_exec -d "$REPO/sub" -s read-only
check "read-only runs, whose git runs outside the sandbox, are refused there too" '[ "$CODE" = 64 ]'
echo 0 > "$LIVE/exit"
claim_exec -d "$REPO/sub"
check "a finished run no longer holds its folders" '[ "$CODE" = 0 ]'
# A launcher that is gone does not release the claim while Codex's process
# group still runs.
sh -c 'exit 0' & wait $!; DEAD=$!
set -m; sleep 120 & LIVEPG=$!; set +m
LIVE2=$(new_run); printf 'pid %s\npgid %s\nw %s\n' "$DEAD" "$LIVEPG" "$REPO" > "$LIVE2/claim"
claim_exec -d "$REPO/sub"
check "a claim holds while its Codex process group runs, launcher or not" '[ "$CODE" = 64 ]'
kill -- "-$LIVEPG" 2>/dev/null; wait "$LIVEPG" 2>/dev/null
claim_exec -d "$REPO/sub"
check "the claim ends with that process group" '[ "$CODE" = 0 ]'
if [ "$GIT_MINOR" -ge 42 ]; then
  # -w runs on one repository reserve it but write only their own worktrees.
  LIVE3=$(new_run); printf 'pid %s\nr %s\nw %s\n' "$$" "$REPO" "$LIVE3/worktree" > "$LIVE3/claim"
  claim_exec -w -d "$REPO"
  check "-w runs on the same repository may run at the same time" '[ "$CODE" = 0 ]'
  claim_exec -d "$REPO"
  check "a write run in a repository that a running -w run uses is refused" '[ "$CODE" = 64 ] && grep -q "git uses" "$TMP/claim.err"'
  echo 0 > "$LIVE3/exit"
fi
rmdir "$REPO/sub"
# The claims lock is a flock(2) lock: a run waits while another holds it, and
# the lock goes away with its holder, also when that is killed.
if command -v perl >/dev/null 2>&1; then
  hold_lock() { ( exec 9>>"$CODEX_WORKER_STATE/claims.flock"; exec perl -e 'use Fcntl ":flock"; open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX) or exit 1; sleep $ARGV[0]' "$1" ) & }
  hold_lock 3; HOLDER=$!; sleep 0.5
  T0=$(date +%s); claim_exec -d "$REPO"; T1=$(date +%s)
  check "a run waits for the claims lock and goes ahead once it is free" '[ "$CODE" = 0 ] && [ $((T1 - T0)) -ge 2 ]'
  wait "$HOLDER" 2>/dev/null
  hold_lock 60; HOLDER=$!; sleep 0.5; kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  claim_exec -d "$REPO"
  check "the claims lock goes away with a holder that was killed" '[ "$CODE" = 0 ]'
fi
# A finished run's claim is over, even if a process group of that number lives.
set -m; sleep 60 & REUSED=$!; set +m
LIVE7=$(new_run); printf 'pid %s\npgid %s\nw %s\n' "$DEAD" "$REUSED" "$REPO" > "$LIVE7/claim"; echo 0 > "$LIVE7/exit"
mkdir -p "$REPO/sub"; claim_exec -d "$REPO/sub"; rmdir "$REPO/sub"
check "a claim with an exit code is over, whatever its process group number now names" '[ "$CODE" = 0 ]'
kill -- "-$REUSED" 2>/dev/null; wait "$REUSED" 2>/dev/null
# Every runs root on the per-user list is protected, not only this one.
mkdir -p "$TMP/other-proj"
CODEX_WORKER_RUNS="$TMP/other-proj/runs" "$SH" "$RUNNER" new >/dev/null
claim_exec -d "$TMP/other-proj"
check "refuses a working directory holding another runs root" '[ "$CODE" = 64 ]'
rm -f "$TMP/other-proj/runs/.codex-worker-runs"
claim_exec -d "$TMP/other-proj"
check "a listed runs root stays protected when its marker is gone" '[ "$CODE" = 64 ]'
unlist "$TMP/other-proj/runs"
# A reserved folder protects what is inside it as well.
mkdir -p "$TMP/rsv/inner"
LIVE4=$(new_run); printf 'pid %s\nr %s\n' "$$" "$TMP/rsv" > "$LIVE4/claim"
claim_exec -d "$TMP/rsv/inner"
check "refuses a write run inside a folder another run's git uses" '[ "$CODE" = 64 ] && grep -q "git uses" "$TMP/claim.err"'
echo 0 > "$LIVE4/exit"
if ! $WINDOWS; then
  # Claimed paths are read back whole, trailing spaces included.
  mkdir -p "$TMP/sp /sub"
  LIVE5=$(new_run); printf 'pid %s\nw %s\n' "$$" "$TMP/sp " > "$LIVE5/claim"
  claim_exec -d "$TMP/sp /sub"
  check "a claimed path with a trailing space still holds what is inside it" '[ "$CODE" = 64 ]'
  echo 0 > "$LIVE5/exit"
fi
# A new runs root is refused where a running write run may write.
mkdir -p "$TMP/regw"
LIVE6=$(new_run); printf 'pid %s\nw %s\n' "$$" "$TMP/regw" > "$LIVE6/claim"
CODEX_WORKER_RUNS="$TMP/regw/runs" "$SH" "$RUNNER" new >/dev/null 2>"$TMP/claim.err"; TCODE=$?
check "refuses a new runs root inside a running write run's folder" '[ "$TCODE" = 64 ] && grep -q "overlap" "$TMP/claim.err"'
echo 0 > "$LIVE6/exit"
# ...also one that was on the list before and is made again (its marker had
# gone), and one that would hold a running write run's folder.
mkdir -p "$TMP/regw2" "$TMP/arch/x"
CODEX_WORKER_RUNS="$TMP/regw2/runs" "$SH" "$RUNNER" new >/dev/null 2>&1
rm -f "$TMP/regw2/runs/.codex-worker-runs"
LIVE8=$(new_run); printf 'pid %s\nw %s\nw %s\n' "$$" "$TMP/regw2" "$TMP/arch/x" > "$LIVE8/claim"
CODEX_WORKER_RUNS="$TMP/regw2/runs" "$SH" "$RUNNER" new >/dev/null 2>&1; TCODE=$?
check "refuses to bring back a listed runs root inside a running write run's folder" '[ "$TCODE" = 64 ] && [ ! -e "$TMP/regw2/runs/.codex-worker-runs" ]'
CODEX_WORKER_RUNS="$TMP/arch" "$SH" "$RUNNER" new >/dev/null 2>&1; TCODE=$?
check "refuses a new runs root that holds a running write run's folder" '[ "$TCODE" = 64 ]'
# ...and one whose marker a run in that folder forged (listed and marked).
mkdir -p "$TMP/regw2/runs"; : > "$TMP/regw2/runs/.codex-worker-runs"
CODEX_WORKER_RUNS="$TMP/regw2/runs" "$SH" "$RUNNER" new >/dev/null 2>&1; TCODE=$?
check "refuses a listed runs root with a forged marker inside a running write run's folder" '[ "$TCODE" = 64 ]'
echo 0 > "$LIVE8/exit"
unlist "$TMP/regw2/runs"; unlist "$TMP/regw/runs"; unlist "$TMP/arch"
# A real run records its Codex process group, which is alive while it runs.
RUN=$(new_run); STUB_SLEEP=8 "$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>&1 & BGRUN=$!
for i in $(seq 1 100); do grep -q '^pgid ' "$RUN/claim" 2>/dev/null && break; sleep 0.2; done
pg_alive() { local pg; for pg in $(sed -n 's/^pgid //p' "$1"); do kill -0 -- "-$pg" 2>/dev/null && return 0; done; return 1; }
check "a run records its Codex process group, alive while Codex runs" 'pg_alive "$RUN/claim"'
wait "$BGRUN"
check "that process group is gone once the run ends" '! pg_alive "$RUN/claim"'
# A link reached through a linked folder of ~/.config is followed all the way.
mkdir -p "$TMP/home2/.config" "$TMP/home2/.dotf/nvim/a/b/c" "$TMP/code/plugin"
mklink_dir "$TMP/home2/.config/nvim" "$TMP/home2/.dotf/nvim"; mklink_dir "$TMP/home2/.dotf/nvim/a/b/c/plugin" "$TMP/code/plugin"
RUN=$(new_run); HOME="$TMP/home2" "$SH" "$RUNNER" exec "$RUN" -d "$TMP/code/plugin" >/dev/null 2>&1; TCODE=$?
check "a deep link in a dotfiles folder that ~/.config links to is protected" '[ "$TCODE" = 64 ]'
rmlink_dir "$TMP/home2/.dotf/nvim/a/b/c/plugin"; rmlink_dir "$TMP/home2/.config/nvim"
if [ "$GIT_MINOR" -ge 42 ]; then
  # -w never writes branches into a git directory in a protected place.
  mkdir -p "$TMP/home4/.dotrepo" && git -C "$TMP/home4/.dotrepo" init -q && echo x > "$TMP/home4/.dotrepo/f" \
    && git -C "$TMP/home4/.dotrepo" add f && git -C "$TMP/home4/.dotrepo" commit -qm init \
    && git -C "$TMP/home4/.dotrepo" worktree add -q "$TMP/dotwt" >/dev/null 2>&1
  RUN=$(new_run); HOME="$TMP/home4" "$SH" "$RUNNER" exec "$RUN" -w -s read-only -d "$TMP/dotwt" >/dev/null 2>"$TMP/claim.err"; TCODE=$?
  check "-w refuses a repository whose git directory is in a protected place" '[ "$TCODE" = 64 ] && grep -q "refusing -w" "$TMP/claim.err"'
  # ...with the same inventory as working directories: an XDG folder too.
  mkdir -p "$TMP/xdgw/repo" && git -C "$TMP/xdgw/repo" init -q && echo x > "$TMP/xdgw/repo/f" \
    && git -C "$TMP/xdgw/repo" add f && git -C "$TMP/xdgw/repo" commit -qm init \
    && git -C "$TMP/xdgw/repo" worktree add -q "$TMP/xdgwt" >/dev/null 2>&1
  RUN=$(new_run); XDG_CONFIG_HOME="$TMP/xdgw" "$SH" "$RUNNER" exec "$RUN" -w -s read-only -d "$TMP/xdgwt" >/dev/null 2>"$TMP/claim.err"; TCODE=$?
  check "-w refuses a repository whose git directory is in XDG_CONFIG_HOME" '[ "$TCODE" = 64 ] && grep -q "refusing -w" "$TMP/claim.err"'
fi
# Changed paths keep marks that reorder text escaped in the receipt.
BIDINAME="ab$(printf '\342\200\256')cd.txt"
STUB_TOUCH="$REPO/$BIDINAME" run_exec -d "$REPO"
check "a changed file name with a bidi mark is escaped in the receipt" 'grep -qF "ab\xe2\x80\xaecd.txt" "$RUN/receipt.txt"'
rm -f "$REPO/$BIDINAME"
# Changed paths keep C1 controls escaped in the receipt.
C1NAME="c1$(printf '\302\233')name.txt"
STUB_TOUCH="$REPO/$C1NAME" run_exec -d "$REPO"
check "a changed file name with a C1 control is escaped in the receipt" \
  'grep -qF "c1\xc2\x9bname.txt" "$RUN/receipt.txt" && ! LC_ALL=C grep -q "$(printf "\302\233")" "$RUN/receipt.txt"'
rm -f "$REPO/$C1NAME"
STUB_ANSWER=$'fine\r\033[2Jforged\302\233x' run_exec -d "$REPO"
check "receipts drop terminal controls from Codex's answer" \
  '! LC_ALL=C grep -q "$(printf "[\033\r]")" "$RUN/receipt.txt" && grep -q "fine\[2Jforgedx" "$RUN/receipt.txt"'
# The installer warns about a runs root in a temporary folder, and its walk up
# ends at a drive root in native spelling too.
# (TMP here is the test folder, not the system's: it is unset for the walk.)
warn_in="$(wp "$SYS_TMP")/runs/x" warn_out_of="$(wp "$TMP")/runs"
warn_out=$(unset TMP; eval "$(sed -n '/^warn_temp() {/,/^}/p' "$ROOT/install.sh")"
           warn() { printf 'WARN %s\n' "$*"; }; is_windows() { $WINDOWS; }; winpath() { wp "$1"; }
           warn_temp "$warn_in" "the runs root"; warn_temp "$warn_out_of" "the runs root")
check "the installer warns about a runs root in a temporary folder, once" \
  '[ "$(printf "%s\n" "$warn_out" | grep -c "is in the temporary folder")" = 1 ]'
mkdir -p "$TMP/home/.ssh" "$TMP/home/projects"
RUN=$(new_run); HOME="$TMP/home" "$SH" "$RUNNER" exec "$RUN" -d "$TMP/home/.ssh" >/dev/null 2>&1
check "refuses a hidden folder of your home for write runs" '[ $? = 64 ]'
mkdir -p "$TMP/home/Library/LaunchAgents" "$TMP/home/AppData/Roaming"
for protected in "$TMP/home/Library/LaunchAgents" "$TMP/home/Library" "$TMP/home/AppData"; do
  RUN=$(new_run); HOME="$TMP/home" "$SH" "$RUNNER" exec "$RUN" -d "$protected" >/dev/null 2>&1
  check "refuses $protected (protected folder or its parent)" '[ $? = 64 ]'
done
RUN=$(new_run); HOME="$TMP/home" "$SH" "$RUNNER" exec "$RUN" -d "$TMP/home/projects" >/dev/null 2>&1
check "accepts an ordinary folder in your home" '[ $? = 0 ]'
run_exec -d "$HOME" -s read-only
check "read-only runs may use any folder" '[ "$CODE" = 0 ]'
RUN=$(new_run)
"$SH" "$RUNNER" exec "$RUN" -d "$REPO" -e turbo >/dev/null 2>&1
"$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>&1
check "a usage error leaves the run dir usable" '[ $? = 0 ]'
"$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>&1
check "refuses to run the same run dir twice" '[ $? = 64 ]'
mkdir -p "$TMP/elsewhere/20260101-000000-1-1" && echo x > "$TMP/elsewhere/20260101-000000-1-1/prompt.txt"
"$SH" "$RUNNER" exec "$TMP/elsewhere/20260101-000000-1-1" -d "$REPO" >/dev/null 2>&1
check "refuses a run dir outside the runs root" '[ $? = 64 ]'
mkdir -p "$RUNS/not-a-run" && echo x > "$RUNS/not-a-run/prompt.txt"
"$SH" "$RUNNER" exec "$RUNS/not-a-run" -d "$REPO" >/dev/null 2>&1
check "refuses a directory not created by new" '[ $? = 64 ]'
RUN=$(new_run); echo leftover > "$RUN/answer.md"
"$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>&1
check "refuses a run dir with pre-existing output files" '[ $? = 64 ] && grep -q leftover "$RUN/answer.md"'
if ! $WINDOWS; then
  RUN=$(new_run)
  check "run dirs are private (700)" '[ "$(ls -ld "$RUN" | cut -c1-10)" = drwx------ ]'
  mkdir -p "$TMP/shared" && chmod 777 "$TMP/shared"
  CODEX_WORKER_RUNS="$TMP/shared" "$SH" "$RUNNER" new >/dev/null 2>&1
  check "refuses an unmarked runs root writable by others" '[ $? = 64 ]'
else skipped "POSIX permission checks"; fi

echo "Launcher: codex arguments"
run_exec -d "$REPO"
check "default sandbox is workspace-write" 'has_arg workspace-write'
check "network is off by default" 'has_arg sandbox_workspace_write.network_access=false'
check "writable roots are pinned empty" 'has_arg "sandbox_workspace_write.writable_roots=[]"'
check "approval policy is pinned to never" "has_arg 'approval_policy=\"never\"'"
check "answer goes to -o file, prompt via stdin" 'has_arg -o && has_arg - && has_arg --json'
check "Codex gets the checked folder it was started in (-C .), not a path to look up again" \
  '[ "$(sed -n "/^-C\$/{n;p;}" "$STUB_ARGS")" = . ]'
run_exec -d "$REPO" -s read-only
check "read-only sandbox" 'has_arg read-only && ! grep -q network_access "$STUB_ARGS"'
run_exec -d "$REPO" -n
check "-n enables network" 'has_arg sandbox_workspace_write.network_access=true'
run_exec -d "$REPO" -m gpt-test-1 -e high
check "model and effort" 'has_arg gpt-test-1 && has_arg model_reasoning_effort=high'
run_exec -d "$REPO" -r "$UUID"
check "resume puts the thread id after all options" \
  '[ "$(sed -n 2p "$STUB_ARGS")" = resume ] && [ "$(tail -n 2 "$STUB_ARGS" | head -1)" = "$UUID" ] && ! has_arg -C'
run_exec -d "$REPO" -o "$ROOT/schemas/findings.schema.json"
check "schema is passed to --output-schema" 'has_arg --output-schema'
run_exec -d "$REPO"
check "guardrails are appended" 'grep -q "<guardrails>" "$RUN/prompt.sent.txt"'
check "LC_ALL is not forced on Codex" '[ "$(cat "$STUB_ARGS.lc_all")" = "${LC_ALL-unset}" ]'
run_exec -d "$REPO" -G
check "-G skips guardrails" '[ ! -f "$RUN/prompt.sent.txt" ]'
(cd "$TMP" && RUN=$(new_run) && "$SH" "$RUNNER" exec "$RUN" -d repo -o ../"$(basename "$TMP")"/repo/tracked.txt >/dev/null 2>&1)
check "relative -d and -o are made absolute" \
  '[ "$(cat "$STUB_ARGS.cwd")" = "$(cd "$REPO" && pwd -P)" ] && [ "$(arg_after --output-schema)" = "$(wp "$REPO/tracked.txt")" ]'

echo "Launcher: receipt"
run_exec -d "$REPO"
# shellcheck disable=SC2034  # read inside a check string
FINISHED=$RUN
check "exit 0 on success" '[ "$CODE" = 0 ]'
check "receipt has thread id" 'grep -q "Thread:  stub-thread-1" "$RUN/receipt.txt"'
check "receipt has answer preview" 'grep -q "STUB ANSWER" "$RUN/receipt.txt"'
check "untouched repo reports nothing changed" 'grep -q "Changed: nothing" "$RUN/receipt.txt"'
check "receipt command reprints a finished run" '"$SH" "$RUNNER" receipt "$FINISHED" | grep -q "Codex finished, exit 0"'
STUB_EXIT=3 run_exec -d "$REPO"
check "propagates codex exit code" '[ "$CODE" = 3 ]'
check "failed run shows stderr tail" 'grep -q "stub failure" "$RUN/receipt.txt"'
STUB_EXIT=1 STUB_BIG_STDERR=1 run_exec -d "$REPO"
check "huge stderr is capped in the receipt" '[ "$(wc -c < "$RUN/receipt.txt")" -lt 6000 ]'
if command -v iconv >/dev/null 2>&1; then
  STUB_EXIT=1 STUB_UTF8_STDERR=1 run_exec -d "$REPO"
  check "truncated stderr stays valid UTF-8" 'iconv -f UTF-8 -t UTF-8 "$RUN/receipt.txt" >/dev/null 2>&1'
  STUB_ANSWER="x$(printf '中%.0s' $(seq 1 600))" run_exec -d "$REPO"
  check "truncated answer preview stays valid UTF-8" 'iconv -f UTF-8 -t UTF-8 "$RUN/receipt.txt" >/dev/null 2>&1'
else skipped "UTF-8 truncation (no iconv)"; fi
STUB_ANSWER="$(printf '%01300d' 0)" run_exec -d "$REPO"
check "long answers are previewed, not inlined" 'grep -q "first 1200 of" "$RUN/receipt.txt"'
RUN=$(new_run); "$SH" "$RUNNER" receipt "$RUN" >/dev/null
check "receipt of an unfinished run returns 75" '[ $? = 75 ]'
"$SH" "$RUNNER" receipt "$TMP/elsewhere/20260101-000000-1-1" >/dev/null 2>&1
check "receipt refuses a run dir outside the root" '[ $? = 64 ]'

echo "Launcher: change report"
STUB_TOUCH=new-file.txt run_exec -d "$REPO"
check "reports a new file" 'grep -qxF "new-file.txt" "$RUN/changed.txt"'
DIRTY=$(new_repo dirty)
echo "x" > "$DIRTY/a b.txt"; echo "x" > "$DIRTY/中文.txt"; echo "edited before" >> "$DIRTY/tracked.txt"
STUB_TOUCH="a b.txt" run_exec -d "$DIRTY"
check "second edit to a dirty file with a space" 'grep -qxF "a b.txt" "$RUN/changed.txt"'
STUB_TOUCH="中文.txt" run_exec -d "$DIRTY"
check "second edit to a dirty non-ASCII file" 'grep -qxF "中文.txt" "$RUN/changed.txt"'
STUB_TOUCH=tracked.txt run_exec -d "$DIRTY"
check "second edit to a dirty tracked file" 'grep -qxF "tracked.txt" "$RUN/changed.txt"'
check "change list holds plain paths" '! grep -qE "^[0-9a-f]{40}| -> " "$RUN/changed.txt"'
if ! $WINDOWS; then
  echo x > "$DIRTY/\"quoted.txt"; printf 'x\n' > "$DIRTY/tab	name.txt"; printf 'x\n' > "$DIRTY/new
line.txt"
  STUB_TOUCH='"quoted.txt' run_exec -d "$DIRTY"
  check "second edit to a file starting with a quote" 'grep -qxF "\"quoted.txt" "$RUN/changed.txt"'
  STUB_TOUCH="tab	name.txt" run_exec -d "$DIRTY"
  check "file names with tabs are escaped, not mangled" 'grep -qxF "tab\\tname.txt" "$RUN/changed.txt"'
  STUB_TOUCH="new
line.txt" run_exec -d "$DIRTY"
  check "file names with newlines are escaped" 'grep -qxF "new\\nline.txt" "$RUN/changed.txt"'
else skipped "quote/tab/newline file names (not allowed on Windows)"; fi
REN=$(new_repo renamed); git -C "$REN" mv tracked.txt moved.txt
STUB_TOUCH=moved.txt run_exec -d "$REN"
check "edit to a staged rename is reported by its new name" 'grep -qxF "moved.txt" "$RUN/changed.txt"'
COM=$(new_repo committed)
STUB_COMMIT=made-by-codex.txt run_exec -d "$COM"
check "files committed by Codex are reported" 'grep -qxF "made-by-codex.txt" "$RUN/changed.txt"'
if ! $WINDOWS; then
  # A tracked directory replaced by a link to an outside directory: the outside
  # files must not be read through it.
  VL=$(new_repo via-link); mkdir -p "$VL/d" && echo inside > "$VL/d/f" && git -C "$VL" add d && git -C "$VL" commit -qm d
  mkdir -p "$TMP/outside" && echo "outside secret" > "$TMP/outside/f"
  rm -r "$VL/d" && ln -s "$TMP/outside" "$VL/d"
  run_exec -d "$VL"
  check "snapshot never hashes through a linked parent directory" \
    'grep -q " via-link d/f$" "$RUN/git-before.txt" && ! grep -q "$(git hash-object "$TMP/outside/f")" "$RUN/git-before.txt"'
fi

echo "Launcher: repository filters are not executed"
if [ "${GIT_MINOR:-0}" -ge 42 ]; then
  FIL=$(new_repo filtered); MARK="$TMP/FILTER_RAN"
  echo 'evil.txt filter=pwn' > "$FIL/.gitattributes"; echo a > "$FIL/evil.txt"
  git -C "$FIL" add . && git -C "$FIL" commit -qm filt
  git -C "$FIL" config filter.pwn.clean "sh -c 'echo clean >> \"$MARK\"; cat'"
  git -C "$FIL" config filter.pwn.smudge "sh -c 'echo smudge >> \"$MARK\"; cat'"
  echo b >> "$FIL/evil.txt"; rm -f "$MARK"
  STUB_TOUCH=evil.txt run_exec -d "$FIL"
  check "the filtered file is reported (plain run)" 'grep -qxF "evil.txt" "$RUN/changed.txt"'
  STUB_TOUCH=evil.txt run_exec -d "$FIL" -w
  check "the filtered file is reported (worktree run)" 'grep -qxF "evil.txt" "$RUN/changed.txt"'
  check "clean and smudge filters from .gitattributes never ran" '[ ! -e "$MARK" ]'
  FIL2=$(new_repo info-attrs); echo a > "$FIL2/f.txt"; git -C "$FIL2" add . && git -C "$FIL2" commit -qm f
  echo 'f.txt filter=pwn' > "$FIL2/.git/info/attributes"
  git -C "$FIL2" config filter.pwn.clean "sh -c 'echo clean >> \"$MARK\"; cat'"
  git -C "$FIL2" config filter.pwn.smudge "sh -c 'echo smudge >> \"$MARK\"; cat'"
  git -C "$FIL2" config filter.pwn.process "sh -c 'echo process >> \"$MARK\"; exit 1'"
  echo b >> "$FIL2/f.txt"
  STUB_TOUCH=f.txt run_exec -d "$FIL2"
  check "plain run on the info/attributes repo succeeded and reported f.txt" '[ "$CODE" = 0 ] && grep -qxF f.txt "$RUN/changed.txt"'
  STUB_TOUCH=f.txt run_exec -d "$FIL2" -w
  check "worktree run on the info/attributes repo succeeded and reported f.txt" '[ "$CODE" = 0 ] && grep -qxF f.txt "$RUN/changed.txt"'
  check "filters selected via .git/info/attributes never ran" '[ ! -e "$MARK" ]'
  # hash-object always applies a selected clean filter, so it proves the
  # launcher's git wrapper neutralises even names containing "=".
  echo 'f.txt filter=a=b' > "$FIL2/.git/info/attributes"
  git -C "$FIL2" config 'filter.a=b.clean' "sh -c 'echo clean >> \"$MARK\"; cat'"
  git -C "$FIL2" hash-object f.txt >/dev/null 2>&1
  check "control: plain git runs the filter named a=b" '[ -e "$MARK" ]'
  rm -f "$MARK"
  # shellcheck disable=SC2034  # read inside a check string
  HASH=$( eval "$(sed -n '/^EMPTY_TREE=/p;/^g() {/,/^}/p' "$RUNNER")"; g -C "$FIL2" hash-object f.txt 2>/dev/null )
  check "the launcher's git wrapper neutralises a filter named a=b" \
    '[[ $HASH =~ ^[0-9a-f]{40}$ ]] && [ ! -e "$MARK" ]'
else skipped "filter neutralisation (git older than 2.42)"; fi

echo "Launcher: worktree isolation"
WT=$(new_repo wt); mkdir -p "$WT/sub" && echo s > "$WT/sub/file.txt" && git -C "$WT" add . && git -C "$WT" commit -qm sub
STUB_TOUCH=tracked.txt run_exec -d "$WT" -w
check "worktree run succeeds" '[ "$CODE" = 0 ]'
check "receipt names the branch" 'grep -q "Branch:  codex/" "$RUN/receipt.txt"'
check "the repository is recorded outside the worktree" '[ "$(wp "$(cat "$RUN/repo")")" = "$(wp "$WT")" ]'
check "edit is reported" 'grep -qxF "tracked.txt" "$RUN/changed.txt"'
check "main checkout is untouched" '[ -z "$(git -C "$WT" status --porcelain)" ]'
check "branch exists in the main repo" 'git -C "$WT" branch --list "codex/*" | grep -q codex/'
STUB_TOUCH=new.txt run_exec -d "$WT/sub" -w
check "-w keeps the requested subdirectory" '[ "$(cat "$STUB_ARGS.cwd")" = "$(cd "$RUN/worktree/sub" && pwd -P)" ]'
check "subdirectory edits are reported repo-relative" 'grep -qxF "sub/new.txt" "$RUN/changed.txt"'
echo dirty >> "$WT/tracked.txt"
run_exec -d "$WT" -w
check "-w notes that uncommitted work is not included" 'grep -q "uncommitted changes" "$RUN/receipt.txt"'

if ! $WINDOWS; then
  # shellcheck disable=SC2034  # read inside a check string
  RUN=$(new_run); START=$(date +%s)
  STUB_SLEEP=30 "$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>&1 &
  LPID=$!; sleep 1; kill -TERM "$LPID"; wait "$LPID" 2>/dev/null
  check "an interrupt stops Codex promptly and records exit 130" \
    '[ "$(cat "$RUN/exit" 2>/dev/null)" = 130 ] && [ $(( $(date +%s) - START )) -lt 15 ]'
  RUN=$(new_run)
  STUB_SLEEP=3 "$SH" "$RUNNER" exec "$RUN" -d "$REPO" >/dev/null 2>&1 &
  LPID=$!; sleep 1; kill -KILL "$LPID"; wait "$LPID" 2>/dev/null
  "$SH" "$RUNNER" receipt "$RUN" >/dev/null 2>&1
  check "a killed launcher is reported as died, not running" '[ $? = 70 ]'
  sleep 3
else skipped "signal handling (POSIX only)"; fi

echo "Guard hook"
L="$(wp "$TMP/claude/codex-worker/codex-run.sh")"
S="$(wp "$TMP/claude/codex-worker/findings.schema.json")"
B="C:/Program Files/Git/bin/bash.exe"
RUNS_PHYS="$(wp "$(cd "$RUNS" && pwd -P)")"
R="$RUNS_PHYS/20260101-120000-123-456"; mkdir -p "$RUNS/20260101-120000-123-456"
CFG="$TMP/guard.json"
L="$L" S="$S" B="$B" RR="$RUNS_PHYS" OUT="$CFG" node -e '
  const e = process.env;
  require("fs").writeFileSync(e.OUT, JSON.stringify({launcher: e.L, bashExe: e.B, runsRoot: e.RR, schema: e.S}));'
guard_raw() { printf '%s' "$1" | node "$GUARD" "${2:-$CFG}" 2>/dev/null; echo $?; }
event() { TOOL=$1 V=$2 node -e '
  const t = process.env.TOOL, v = process.env.V;
  process.stdout.write(JSON.stringify({tool_name: t, tool_input: t === "Write" ? {file_path: v} : {command: v}}));'; }
allows() { [ "$(guard_raw "$(event "$1" "$2")")" = 0 ]; }
blocks() { [ "$(guard_raw "$(event "$1" "$2")")" = 2 ]; }

while IFS= read -r cmd; do
  check "allows: $cmd" 'allows Bash "$cmd"'
done <<EOF
"$L" new
"$L" exec "$R" -d "/some dir/repo (1)" -s read-only -w -m gpt-6-astra -e high
"$L" exec "$R" -d "$(wp "$REPO")" -o "$S" -r $UUID
"$L" exec "$R" -d "/项目/仓库" -n
"$L" receipt "$R"
EOF
check "allows: PowerShell & \"<git bash>\" \"<launcher>\" new" "allows PowerShell '& \"$B\" \"$L\" new'"
# Bash keeps Unicode spaces in front of a command as part of its name (a program
# relative to the current folder), so only the blanks the shell skips may lead.
check "allows: a trailing newline" 'allows Bash "\"$L\" new
"'
# A hook that times out lets the command through, so the guard stays linear.
LONG_EVENT=$(L="$L" node -e 'process.stdout.write(JSON.stringify({tool_name: "Bash", tool_input: {command: "\"" + process.env.L + "\"" + " ".repeat(300000) + "new" + " ".repeat(300000) + "x\u00a0"}}))')
T0=$(date +%s); LONG_RC=$(guard_raw "$LONG_EVENT"); T1=$(date +%s)
check "the guard decides on a command with 600000 blanks within seconds" '[ "$LONG_RC" = 2 ] && [ $((T1 - T0)) -le 5 ]'
for lead in "$(printf '\302\240')" "$(printf '\357\273\277')" "$(printf '\343\200\200')" "$(printf '\r')"; do
  check "blocks a launcher led by $(printf '%s' "$lead" | od -An -tx1 | tr -d ' \n')" 'blocks Bash "$lead\"$L\" new" && blocks Bash "${lead}$L new"'
done
check "allows: Write <run>/prompt.txt" 'allows Write "$R/prompt.txt"'
if $WINDOWS; then
  check "allows: Write with backslashes" 'allows Write "$(printf "%s" "$R/prompt.txt" | tr / "\\\\")"'
fi

while IFS= read -r cmd; do
  check "blocks: $cmd" 'blocks Bash "$cmd"'
done <<EOF
codex exec -s read-only x
c=codex; \$c exec x
"\$(command -v codex)" exec x
/usr/bin/codex exec x
npx @openai/codex exec x
bash -c "co""dex ex""ec x"
codex -c sandbox_mode=dan"ger-full-access" exec x
"codex" exec --yo""lo x
bash ./dispatch.sh
CODEX_HOME=/tmp/x "$L" new
"$L" new; rm -rf ~
"$L" new && echo hi
"$L" new > /tmp/out
"$L" new | cat
"$L" exec "$R" -d . -G
"$L" exec "$R" -d . -s danger-full-access
"$L" exec "$R" -d . -o /tmp/evil.json
"$L" exec "$R" -d . -d .
"$L" exec "$R" -d . --dangerously-bypass-approvals-and-sandbox
"$L" exec "$R" -d . -r --yolo
"$L" exec "$R" -d . -r --dangerously-bypass-approvals-and-sandbox
"$L" exec "$R" -d . -r 01a1-beef
"$L" exec "$R" -d . -m --yolo
"$L" exec "$R" -d "/repo/../../etc"
"$L" exec "$R" -d "//server/share"
"$L" exec "$R" -s read-only
"$L" exec "/tmp/20260101-120000-123-456" -d .
"$L" exec "$R/../20260101-120000-123-457" -d .
"$L" receipt "$R" extra
"$L" status
"$L"
EOF
# Smart quotes, Unicode line/paragraph separators, no-break space, en dash: as
# octal UTF-8 bytes, because bash 3.2 has no \u escapes.
for oct in '\342\200\234' '\342\200\235' '\342\200\236' '\342\200\230' '\342\200\231' \
           '\342\200\232' '\342\200\233' '\342\200\250' '\302\240' '\342\200\223'; do
  q=$(printf "$oct")
  check "blocks: Unicode $(printf '%s' "$q" | od -An -tx1 | tr -d ' ') inside a quoted value" \
    "blocks PowerShell '& \"$B\" \"$L\" exec \"$R\" -d \"x${q}y\"'"
done
check "blocks: tab-separated arguments" 'blocks Bash "$(printf "\"%s\"\tnew" "$L")"'
check "blocks: PowerShell without the Git Bash prefix" "blocks PowerShell '& codex.exe exec x'"
check "blocks: PowerShell string concatenation" "blocks PowerShell '& CODEX.EXE exec (\"--yo\" + \"lo\") x'"
check "blocks: PowerShell running the launcher without bash.exe" "blocks PowerShell '& \"$L\" new'"
check "blocks: PowerShell with a Git Bash style /c/ executable path" \
  '[ "$(guard_raw "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"& \\\"/c/Program Files/Git/bin/bash.exe\\\" \\\"$L\\\" new\"}}")" = 2 ]'
check "blocks: multi-line command" 'blocks Bash "$(printf "%s\n%s" "\"$L\" new" "rm -rf /")"'
check "blocks: Write over the guard itself" 'blocks Write "$(wp "$TMP/claude/codex-worker/codex-guard.mjs")"'
check "blocks: Write of another file in a run dir" 'blocks Write "$R/run.sh"'
check "blocks: Write into a run dir that does not exist" 'blocks Write "$RUNS_PHYS/20260101-120000-999-999/prompt.txt"'
check "blocks: Write with .. segments" 'blocks Write "$R/../20260101-120000-123-457/prompt.txt"'
check "blocks: Write outside the runs root" 'blocks Write "/tmp/20260101-120000-123-456/prompt.txt"'
check "blocks: Write with a trailing separator" 'blocks Write "$R/prompt.txt/"'
if $WINDOWS; then
  # Built as literal JSON: Git Bash would rewrite a POSIX-looking path passed
  # through an environment variable into a C:/ path before node sees it.
  check "blocks: Write with a Git Bash style /c/ path" \
    '[ "$(guard_raw "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(cygpath -u "$R")/prompt.txt\"}}")" = 2 ]'
fi
if ! $WINDOWS; then
  check "blocks: POSIX backslash path tricks" 'blocks Write "$RUNS_PHYS\\20260101-120000-123-456\\prompt.txt"'
  mkdir -p "$TMP/outside"; ln -s "$TMP/outside" "$RUNS/20260101-120000-123-458"
  check "blocks: Write through a symlinked run dir" 'blocks Write "$RUNS_PHYS/20260101-120000-123-458/prompt.txt"'
  mkdir -p "$RUNS/20260101-120000-123-459"; ln -s "$TMP/outside/target" "$RUNS/20260101-120000-123-459/prompt.txt"
  check "blocks: Write to a prompt.txt symlink" 'blocks Write "$RUNS_PHYS/20260101-120000-123-459/prompt.txt"'
else skipped "POSIX symlink and backslash cases"; fi
check "blocks: malformed hook input" '[ "$(guard_raw "not json")" = 2 ]'
check "blocks: missing command field" '[ "$(guard_raw "{\"tool_name\":\"Bash\",\"tool_input\":{}}")" = 2 ]'
check "blocks: tools it does not know" '[ "$(guard_raw "{\"tool_name\":\"Read\",\"tool_input\":{}}")" = 2 ]'
check "blocks: missing configuration" '[ "$(guard_raw "$(event Bash "\"$L\" new")" "$TMP/missing.json")" = 2 ]'

echo "Installer"
AGENT="$CLAUDE_CONFIG_DIR/agents/codex-worker.md"
"$SH" "$ROOT/install.sh" > "$TMP/install.log" 2>&1
check "install succeeds" '[ $? = 0 ]'
grep -q "^  ok    guard allows" "$TMP/install.log" || sed 's/^/        | /' "$TMP/install.log"
check "agent rendered without placeholders" '[ -f "$AGENT" ] && ! grep -q "{{" "$AGENT"'
check "agent carries the ownership marker" 'grep -q "installed-by: codex-worker" "$AGENT"'
check "hook command is a JSON-quoted string" 'grep -qE "^ +command: \"node " "$AGENT"'
check "hook fails closed on hook errors" 'grep -qE "^ +onFailure: block" "$AGENT"'
check "hook covers Write, agent has no Read" 'grep -q "matcher: Bash|PowerShell|Write" "$AGENT" && grep -q "^tools: Bash, PowerShell, Write$" "$AGENT"'
check "scripts, guard config and runs-root installed" \
  '[ -x "$CLAUDE_CONFIG_DIR/codex-worker/codex-run.sh" ] && [ -f "$CLAUDE_CONFIG_DIR/codex-worker/codex-guard.json" ] && [ -f "$CLAUDE_CONFIG_DIR/codex-worker/runs-root" ]'
check "installed launcher finds the runs root without the env var" \
  '[ "$(dirname "$(env -u CODEX_WORKER_RUNS HOME="$TMP/inst-home" "$SH" "$CLAUDE_CONFIG_DIR/codex-worker/codex-run.sh" new)")" = "$RUNS_PHYS" ]'
check "the installed launcher keeps its state in the home, whatever CODEX_WORKER_STATE says" \
  'grep -qxF "$(cd "$RUNS" && pwd -P)" "$TMP/inst-home/.cache/codex-worker/runs-roots"'
check "installed guard accepts the installed launcher" \
  'printf "%s" "$(event Bash "\"$(wp "$CLAUDE_CONFIG_DIR/codex-worker/codex-run.sh")\" new")" | node "$CLAUDE_CONFIG_DIR/codex-worker/codex-guard.mjs" "$CLAUDE_CONFIG_DIR/codex-worker/codex-guard.json"'
"$SH" "$ROOT/install.sh" --model claude-sonnet-5-5 >/dev/null 2>&1
check "reinstall updates the model" 'grep -q "^model: claude-sonnet-5-5" "$AGENT"'
"$SH" "$ROOT/install.sh" --uninstall >/dev/null 2>&1
check "uninstall removes agent and scripts" '[ ! -e "$AGENT" ] && [ ! -e "$CLAUDE_CONFIG_DIR/codex-worker" ]'
mkdir -p "$(dirname "$AGENT")" && echo "hand written" > "$AGENT"
"$SH" "$ROOT/install.sh" >/dev/null 2>&1
check "refuses to overwrite a foreign agent" '[ $? != 0 ] && grep -q "hand written" "$AGENT"'
"$SH" "$ROOT/install.sh" --uninstall >/dev/null 2>&1
check "refuses to uninstall a foreign agent" '[ $? != 0 ] && [ -f "$AGENT" ]'
"$SH" "$ROOT/install.sh" --force >/dev/null 2>&1
check "--force backs up and replaces" 'grep -q "installed-by: codex-worker" "$AGENT" && ls "$AGENT".bak.* >/dev/null 2>&1'
CLAUDE_CONFIG_DIR="$TMP/odd\$(x)" "$SH" "$ROOT/install.sh" >/dev/null 2>&1
check "refuses config paths with shell metacharacters" '[ $? != 0 ] && [ ! -e "$TMP/odd\$(x)/agents" ]'
CODEX_WORKER_RUNS=relative/runs "$SH" "$ROOT/install.sh" >/dev/null 2>&1
check "refuses a relative CODEX_WORKER_RUNS" '[ $? != 0 ]'

echo "Installer: purge"
UNMARKED="$TMP/unmarked"; mkdir -p "$UNMARKED/20260101-000000-1-1"; echo keep > "$UNMARKED/keep.txt"
CODEX_WORKER_RUNS="$UNMARKED" "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
check "purge leaves a directory without the marker alone" '[ -f "$UNMARKED/keep.txt" ] && [ -d "$UNMARKED/20260101-000000-1-1" ]'
check "purging another root keeps the recorded runs-root" '[ -f "$CLAUDE_CONFIG_DIR/codex-worker/runs-root" ]'
"$SH" "$ROOT/install.sh" >/dev/null 2>&1   # records runs-root again
# Purge takes a runs root off the per-user list, also one that is gone or has
# no marker (the list would keep its folders protected).
PH="$TMP/purge-home/.cache/codex-worker"; mkdir -p "$PH"
printf '%s\n' /elsewhere/keep "$(cd "$TMP" && pwd -P)/gone-runs" "$(cd "$UNMARKED" && pwd -P)" > "$PH/runs-roots"
HOME="$TMP/purge-home" CODEX_WORKER_RUNS="$TMP/gone-runs" "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
HOME="$TMP/purge-home" CODEX_WORKER_RUNS="$UNMARKED" "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
check "purge takes gone and unmarked runs roots off the per-user list" '[ "$(cat "$PH/runs-roots")" = /elsewhere/keep ]'
"$SH" "$ROOT/install.sh" >/dev/null 2>&1
if ! $WINDOWS; then
  VICTIM=$(new_repo victim); git -C "$VICTIM" worktree add -q "$TMP/victim-wt" HEAD
  echo precious > "$TMP/victim-wt/precious.txt"
  mkdir -p "$RUNS/20260101-000000-9-9"; ln -s "$TMP/victim-wt" "$RUNS/20260101-000000-9-9/worktree"
  echo "$VICTIM" > "$RUNS/20260101-000000-9-9/repo"
  # A run dir rm cannot fully remove: the first purge must keep what a retry needs.
  STUCK_REPO=$(new_repo stuck); STUCK="$RUNS/20260101-000000-7-7"
  git -C "$STUCK_REPO" worktree add -q "$STUCK/worktree" HEAD; echo "$STUCK_REPO" > "$STUCK/repo"
  # Codex-made permission traps inside the worktree are undone by purge itself...
  mkdir -p "$STUCK/worktree/trap/deep" && echo x > "$STUCK/worktree/trap/deep/f" && chmod 000 "$STUCK/worktree/trap"
  # ...but a run dir the user made read-only is left alone (and needs root to delete).
  chmod 555 "$STUCK"
else
  # An NTFS junction inside a worktree must be removed as a link, never descended into.
  mkdir -p "$TMP/jvictim" "$RUNS/20260101-000000-5-5/worktree"; echo precious > "$TMP/jvictim/precious.txt"
  cmd //c mklink //J "$(cygpath -w "$RUNS/20260101-000000-5-5/worktree/link")" "$(cygpath -w "$TMP/jvictim")" >/dev/null 2>&1
  check "precondition: the junction was created" '[ -f "$RUNS/20260101-000000-5-5/worktree/link/precious.txt" ]'
fi
if [ "$GIT_MINOR" -ge 48 ]; then
  REL_REPO=$(new_repo relative); REL="$RUNS/20260101-000000-6-6"
  git -C "$REL_REPO" -c worktree.useRelativePaths=true worktree add -q "$REL/worktree" HEAD; echo "$REL_REPO" > "$REL/repo"
  check "precondition: a relative worktree registration exists" 'grep -q "^\.\." "$REL_REPO"/.git/worktrees/*/gitdir'
else
  skipped "relative worktree registrations (git < 2.48)"
fi
echo keep > "$RUNS/keep.txt"
check "precondition: a run worktree is registered before purge" 'git -C "$WT" worktree list | grep -q "/runs/"'
if ! $WINDOWS && [ "$(id -u)" != 0 ]; then
  "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
  check "a partial purge fails" '[ $? != 0 ]'
  check "a partial purge keeps the marker, runs-root and the repo file" \
    '[ -f "$RUNS/.codex-worker-runs" ] && [ -f "$CLAUDE_CONFIG_DIR/codex-worker/runs-root" ] && [ -f "$STUCK/repo" ]'
  check "a partial purge keeps the stuck worktree registered" '[ -n "$(ls -A "$STUCK_REPO/.git/worktrees" 2>/dev/null)" ]'
elif ! $WINDOWS; then
  skipped "partial purge (running as root, permissions do not block rm)"
fi
$WINDOWS || chmod 755 "$STUCK"
# The retry finds the runs root through the recorded runs-root file.
env -u CODEX_WORKER_RUNS "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
check "purge succeeds" '[ $? = 0 ]'
check "purge removes run directories" '[ -z "$(ls -d "$RUNS"/2026* 2>/dev/null)" ]'
check "purge keeps unrelated files in the runs root" '[ -f "$RUNS/keep.txt" ]'
check "purge removes the marker and runs-root" '[ ! -e "$RUNS/.codex-worker-runs" ] && [ ! -e "$CLAUDE_CONFIG_DIR/codex-worker" ]'
check "purge unregisters worktrees" '! git -C "$WT" worktree list | grep -q "/runs/"'
if [ "$GIT_MINOR" -ge 48 ]; then
  check "purge unregisters relative worktree registrations" '[ -z "$(ls -A "$REL_REPO/.git/worktrees" 2>/dev/null)" ]'
fi
if ! $WINDOWS; then
  check "a retried purge unregisters the stuck worktree" '[ -z "$(ls -A "$STUCK_REPO/.git/worktrees" 2>/dev/null)" ]'
  check "purge never follows a nested worktree symlink" '[ -f "$TMP/victim-wt/precious.txt" ]'
else
  check "purge never follows an NTFS junction" '[ -f "$TMP/jvictim/precious.txt" ]'
fi

echo "Installer: purge keeps retry data"
R2="$TMP/runs2"; mkdir -p "$R2/20260101-000000-1-1" "$R2/20260101-000000-2-2" "$TMP/not-a-repo"; : > "$R2/.codex-worker-runs"
echo "$TMP/not-a-repo" > "$R2/20260101-000000-1-1/repo"   # git cannot read it
echo $$ > "$R2/20260101-000000-2-2/pid"                    # still running: this shell
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
mkdir -p "$R2/20260101-000000-3-3"; echo "$DEAD" > "$R2/20260101-000000-3-3/pid"   # launcher died, no exit file
echo f > "$TMP/a-file"; mkdir -p "$R2/20260101-000000-4-4"; echo "$TMP/a-file/repo" > "$R2/20260101-000000-4-4/repo"
if ! $WINDOWS && [ "$(id -u)" != 0 ]; then
  mkdir -p "$R2/20260101-000000-5-5"; echo "$TMP/somewhere" > "$R2/20260101-000000-5-5/repo"; chmod 000 "$R2/20260101-000000-5-5/repo"
  # The recorded repository is itself a link into an unsearchable directory.
  mkdir -p "$TMP/locked-repos/r" "$R2/20260101-000000-6-6"; ln -s "$TMP/locked-repos/r" "$TMP/repo-link"
  echo "$TMP/repo-link" > "$R2/20260101-000000-6-6/repo"; chmod 000 "$TMP/locked-repos"
fi
GIT_CEILING_DIRECTORIES="$TMP" CODEX_WORKER_RUNS="$R2" "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
check "purge fails when a repository cannot be read" '[ $? != 0 ] && [ -f "$R2/20260101-000000-1-1/repo" ] && [ -f "$R2/.codex-worker-runs" ]'
check "purge leaves a running run alone" '[ -f "$R2/20260101-000000-2-2/pid" ]'
check "purge removes a run whose launcher died" '[ ! -e "$R2/20260101-000000-3-3" ]'
check "purge treats a repository under a file as gone" '[ ! -e "$R2/20260101-000000-4-4" ]'
if ! $WINDOWS && [ "$(id -u)" != 0 ]; then
  check "purge keeps a run whose repo file cannot be read" '[ -e "$R2/20260101-000000-5-5/repo" ]'
  check "purge keeps a run whose repository is a link it cannot follow" '[ -f "$R2/20260101-000000-6-6/repo" ]'
  chmod 755 "$TMP/locked-repos"
  R3="$TMP/runs3"; mkdir -p "$R3/20260101-000000-1-1"; : > "$R3/.codex-worker-runs"; chmod 300 "$R3"
  CODEX_WORKER_RUNS="$R3" "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
  check "purge fails on a runs root it cannot list" '[ $? != 0 ] && chmod 700 "$R3" && [ -f "$R3/.codex-worker-runs" ] && [ -d "$R3/20260101-000000-1-1" ]'
fi

echo "Helpers"
check "lexical resolves dot segments" \
  '( eval "$(sed -n "/^lexical() {/,/^}/p" "$ROOT/install.sh")"; set -u; [ "$(lexical /a/b/../c/./d)" = /a/c/d ] && [ "$(lexical /a/..)" = / ] && [ "$(lexical C:/x/../y)" = C:/y ] )'
mkdir -p "$TMP/lc"; cp "$RUNNER" "$TMP/lc/codex-run.sh"; echo "rel/runs" > "$TMP/lc/runs-root"
"$SH" "$TMP/lc/codex-run.sh" new >/dev/null 2>&1
check "launcher refuses a relative recorded runs root" '[ $? = 64 ]'
if ! $WINDOWS; then
  echo "C:/runs" > "$TMP/lc/runs-root"; "$SH" "$TMP/lc/codex-run.sh" new >/dev/null 2>&1
  check "launcher treats drive-letter paths as relative off Windows" '[ $? = 64 ]'
fi
if ! $WINDOWS && [ "$GIT_MINOR" -ge 42 ]; then
  LR=$(new_repo linked-refs); mkdir -p "$TMP/elsewhere" "$LR/.git/refs/heads"; ln -s "$TMP/elsewhere" "$LR/.git/refs/heads/codex"
  run_exec -d "$LR" -w
  check "-w refuses git metadata dirs that link elsewhere" '[ "$CODE" = 66 ] && [ -z "$(ls -A "$TMP/elsewhere")" ]'
  LF=$(new_repo linked-file); echo "# outside" > "$TMP/outside-packed"; ln -s "$TMP/outside-packed" "$LF/.git/packed-refs"
  run_exec -d "$LF" -w
  check "-w refuses linked git metadata files (packed-refs, config, reftable...)" '[ "$CODE" = 66 ] && [ "$(cat "$TMP/outside-packed")" = "# outside" ]'
  # Links under hooks/ are common and harmless (hooks are disabled), also in a
  # path with glob characters.
  mkdir -p "$TMP/pr[1]"; HK=$(new_repo "pr[1]/hooked"); echo '#!/bin/sh' > "$TMP/hook.sh"; ln -s "$TMP/hook.sh" "$HK/.git/hooks/pre-commit"
  run_exec -d "$HK" -w
  check "-w accepts links under .git/hooks, even below a path with [ ]" '[ "$CODE" = 0 ]'
fi
if $WINDOWS && [ "$GIT_MINOR" -ge 42 ]; then
  JR=$(new_repo junction-refs); mkdir -p "$TMP/jelsewhere"
  cmd //c mklink //J "$(cygpath -w "$JR/.git/refs/heads/codex")" "$(cygpath -w "$TMP/jelsewhere")" >/dev/null 2>&1
  run_exec -d "$JR" -w
  check "-w refuses a junction inside the git directory" '[ "$CODE" = 66 ] && [ -z "$(ls -A "$TMP/jelsewhere")" ]'
  # The user folders are asked from Windows: a stub system PowerShell under a
  # fake SYSTEMROOT answers Documents, Roaming, Local, Startup and the profile.
  FS="$TMP/fakesys/System32/WindowsPowerShell/v1.0"; mkdir -p "$FS" "$TMP/OneDrive/Documents/WindowsPowerShell" "$TMP/jreal"
  cmd //c mklink //J "$(cygpath -w "$TMP/jdocs")" "$(cygpath -w "$TMP/jreal")" >/dev/null 2>&1
  stub_folders() {   # $1 = Documents; the others are harmless folders under $TMP
    { echo '#!/bin/sh'; for f in "$1" "$TMP/fake/Roaming" "$TMP/fake/Local" "$TMP/fake/Startup" "$TMP/fake/profile"; do
        printf 'echo "%s"\n' "$(cygpath -w "$f")"; done; } > "$FS/powershell.exe"
    chmod +x "$FS/powershell.exe"
  }
  stub_folders "$TMP/OneDrive/Documents"
  SYSTEMROOT="$(cygpath -w "$TMP/fakesys")" run_exec -d "$TMP/OneDrive/Documents/WindowsPowerShell"
  check "refuses the PowerShell folder in a redirected Documents" '[ "$CODE" = 64 ]'
  SYSTEMROOT="$(cygpath -w "$TMP/fakesys")" run_exec -d "$TMP/OneDrive"
  check "refuses a folder that contains the redirected profile folder" '[ "$CODE" = 64 ]'
  stub_folders "$TMP/jdocs"   # a junction; neither profile folder exists yet
  SYSTEMROOT="$(cygpath -w "$TMP/fakesys")" run_exec -d "$TMP/jreal"
  check "refuses the physical Documents behind a junction before the profile folders exist" '[ "$CODE" = 64 ]'
  # Documents -> jmid/docs -> jreal2: the middle junction moves Documents too.
  mkdir -p "$TMP/jmid" "$TMP/jreal2"
  cmd //c mklink //J "$(cygpath -w "$TMP/jmid/docs")" "$(cygpath -w "$TMP/jreal2")" >/dev/null 2>&1
  cmd //c mklink //J "$(cygpath -w "$TMP/jdocs2")" "$(cygpath -w "$TMP/jmid/docs")" >/dev/null 2>&1
  check "precondition: the junction chain was created" '[ -L "$TMP/jdocs2" ] && [ -L "$TMP/jmid/docs" ]'
  stub_folders "$TMP/jdocs2"
  SYSTEMROOT="$(cygpath -w "$TMP/fakesys")" run_exec -d "$TMP/jmid"
  check "refuses a folder holding a junction on the way to Documents" '[ "$CODE" = 64 ]'
  # A configuration folder given in native Windows spelling is protected too.
  mkdir -p "$TMP/ccfg/agents"
  CLAUDE_CONFIG_DIR="$(cygpath -m "$TMP/ccfg")" run_exec -d "$TMP/ccfg/agents"
  check "refuses a folder inside a CLAUDE_CONFIG_DIR spelled C:/..." '[ "$CODE" = 64 ]'
  # ... or as a UNC path (//server/share keeps its root), when the admin share is there.
  UNC_TMP="//localhost/C\$/$(cygpath -m "$TMP" | sed 's|^[A-Za-z]:/||')"
  if [ "$(cygpath -m "$TMP" | cut -c1-2)" = "C:" ] && [ -d "$UNC_TMP/ccfg" ]; then
    CLAUDE_CONFIG_DIR="$UNC_TMP/ccfg" run_exec -d "$TMP/ccfg/agents"
    check "refuses a folder inside a CLAUDE_CONFIG_DIR spelled //server/share/..." '[ "$CODE" = 64 ]'
    # Native spelling (\\server\share\...), which cygpath alone would misread.
    CODEX_HOME=$(printf '%s' "$UNC_TMP/ccfg" | tr / '\\') run_exec -d "$TMP/ccfg/agents"
    check "refuses a folder inside a CODEX_HOME spelled \\\\server\\share\\..." '[ "$CODE" = 64 ]'
  else
    skipped "UNC CLAUDE_CONFIG_DIR (no admin share)"
  fi
  # NTFS folds case outside ASCII too; the spelling given to -d is kept by pwd -P.
  mkdir -p "$TMP/hömé/.ssh/x"
  HOME="$TMP/hömé" run_exec -d "$TMP/HÖMÉ/.ssh/x"
  check "refuses a hidden home folder spelled with other non-ASCII case" '[ "$CODE" = 64 ]'
  HOME="$TMP/hömé" run_exec -d "$TMP/HÖMÉ/.SSH"
  check "refuses a hidden home folder spelled with other case throughout" '[ "$CODE" = 64 ]'
  printf '#!/bin/sh\nexit 1\n' > "$FS/powershell.exe"
  SYSTEMROOT="$(cygpath -w "$TMP/fakesys")" run_exec -d "$REPO"
  check "refuses a write run when Windows cannot be asked for the user folders" '[ "$CODE" = 64 ]'
  SYSTEMROOT="$(cygpath -w "$TMP/fakesys")" run_exec -d "$REPO" -s read-only
  check "read-only runs do not need the user folders" '[ "$CODE" = 0 ]'
  JS=$(new_repo junction-snap); mkdir -p "$TMP/jsnap"
  cmd //c mklink //J "$(cygpath -w "$JS/.git/refs/heads/elsewhere")" "$(cygpath -w "$TMP/jsnap")" >/dev/null 2>&1
  run_exec -d "$JS" -s read-only
  check "change report is disabled when the git directory holds a junction" '[ "$CODE" = 0 ] && grep -q "contains links" "$RUN/note.txt"'
fi
if ! $WINDOWS; then
  SL=$(new_repo link-snap); ln -s "$TMP/elsewhere" "$SL/.git/sharedindex.0000000000000000000000000000000000000000"
  run_exec -d "$SL" -s read-only
  check "change report is disabled when the git directory holds a link" '[ "$CODE" = 0 ] && grep -q "contains links" "$RUN/note.txt"'
  # A per-worktree git dir outside the common dir (commondir) is scanned too.
  PW=$(new_repo per-wt); git -C "$PW" worktree add -q "$TMP/per-wt-co" HEAD
  ADM=$(git -C "$TMP/per-wt-co" rev-parse --absolute-git-dir); mv "$ADM" "$TMP/private-gitdir"
  echo "$(cd "$PW/.git" && pwd -P)" > "$TMP/private-gitdir/commondir"; echo "gitdir: $TMP/private-gitdir" > "$TMP/per-wt-co/.git"
  ln -s "$TMP/elsewhere" "$TMP/private-gitdir/sharedindex.0000000000000000000000000000000000000000"
  run_exec -d "$TMP/per-wt-co" -s read-only
  check "links in a separate per-worktree git dir disable the change report" '[ "$CODE" = 0 ] && grep -q "contains links" "$RUN/note.txt"'
  # Protected folders reached through links: dangling, to a file, under a linked HOME.
  mkdir -p "$TMP/h1" "$TMP/proj"; ln -s "$TMP/proj/keys" "$TMP/h1/.ssh"
  HOME="$TMP/h1" run_exec -d "$TMP/proj"
  check "refuses the target of a dangling protected link" '[ "$CODE" = 64 ]'
  mkdir -p "$TMP/h2" "$TMP/dots"; echo "# rc" > "$TMP/dots/bashrc"; ln -s "$TMP/dots/bashrc" "$TMP/h2/.bashrc"
  HOME="$TMP/h2" run_exec -d "$TMP/dots"
  check "refuses a folder holding the target of a linked dotfile" '[ "$CODE" = 64 ]'
  mkdir -p "$TMP/hreal/.vscode"; ln -s "$TMP/hreal" "$TMP/hlink"
  HOME="$TMP/hlink" run_exec -d "$TMP/hreal/.vscode"
  check "refuses a hidden folder of a linked HOME at its physical place" '[ "$CODE" = 64 ]'
  # A folder on the way cannot be searched, so links behind it are unknown:
  # resolution must not fail open, even for an unrelated working directory.
  mkdir -p "$TMP/h3" "$TMP/proj3/locked" "$TMP/ok3"; ln -s "$TMP/proj3/locked/keys" "$TMP/h3/.ssh"; chmod 000 "$TMP/proj3/locked"
  HOME="$TMP/h3" run_exec -d "$TMP/proj3"
  check "refuses a protected link into a folder that cannot be entered" '[ "$CODE" = 64 ]'
  HOME="$TMP/h3" run_exec -d "$TMP/ok3"
  check "refuses any write run while a protected path passes an unsearchable folder" '[ "$CODE" = 64 ]'
  chmod 755 "$TMP/proj3/locked"
  # A per-worktree git dir hidden under the common dir's hooks/ is scanned on its own.
  PH=$(new_repo per-wt-hooks); git -C "$PH" worktree add -q "$TMP/per-wt-hooks-co" HEAD
  ADM=$(git -C "$TMP/per-wt-hooks-co" rev-parse --absolute-git-dir); mv "$ADM" "$PH/.git/hooks/private-admin"
  echo "$(cd "$PH/.git" && pwd -P)" > "$PH/.git/hooks/private-admin/commondir"
  echo "gitdir: $PH/.git/hooks/private-admin" > "$TMP/per-wt-hooks-co/.git"
  ln -s "$TMP/elsewhere" "$PH/.git/hooks/private-admin/sharedindex.0000000000000000000000000000000000000000"
  run_exec -d "$TMP/per-wt-hooks-co" -s read-only
  check "a per-worktree git dir under hooks/ is scanned too" '[ "$CODE" = 0 ] && grep -q "contains links" "$RUN/note.txt"'
  # A fixed protected path below a linked home entry (macOS ~/Library) is resolved.
  mkdir -p "$TMP/h4" "$TMP/vol/Library/LaunchAgents"; ln -s "$TMP/vol/Library" "$TMP/h4/Library"
  HOME="$TMP/h4" run_exec -d "$TMP/vol/Library/LaunchAgents"
  check "refuses LaunchAgents at its physical place below a linked ~/Library" '[ "$CODE" = 64 ]'
  # A looping link in the home protects only its own path and links; it does not refuse every run.
  mkdir -p "$TMP/h5" "$TMP/ok5"; ln -s .loop "$TMP/h5/.loop"
  HOME="$TMP/h5" run_exec -d "$TMP/ok5"
  check "a looping link in the home does not refuse unrelated write runs" '[ "$CODE" = 0 ]'
  # Every link on the way is protected: replacing one would move the protected path.
  mkdir -p "$TMP/h6" "$TMP/p6" "$TMP/else6"; ln -s "$TMP/p6/rc" "$TMP/h6/.bashrc"; ln -s "$TMP/else6/rc" "$TMP/p6/rc"
  HOME="$TMP/h6" run_exec -d "$TMP/p6"
  check "refuses a folder holding the middle link of a protected chain" '[ "$CODE" = 64 ]'
  mkdir -p "$TMP/h7" "$TMP/p7"; ln -s "$TMP/p7/rc" "$TMP/h7/.bashrc"; ln -s rc "$TMP/p7/rc"
  HOME="$TMP/h7" run_exec -d "$TMP/p7"
  check "refuses a folder holding a link of a protected loop" '[ "$CODE" = 64 ]'
  mkdir -p "$TMP/h8" "$TMP/p8" "$TMP/vol8/Library/LaunchAgents"
  ln -s "$TMP/p8/Lib" "$TMP/h8/Library"; ln -s "$TMP/vol8/Library" "$TMP/p8/Lib"
  HOME="$TMP/h8" run_exec -d "$TMP/p8"
  check "refuses a folder holding a link on the way to LaunchAgents" '[ "$CODE" = 64 ]'
  mkdir -p "$TMP/h9" "$TMP/p9" "$TMP/real9"; ln -s "$TMP/p9/cl" "$TMP/h9/cfg"; ln -s "$TMP/real9" "$TMP/p9/cl"
  HOME="$TMP/h9" CLAUDE_CONFIG_DIR="$TMP/h9/cfg" run_exec -d "$TMP/p9"
  check "refuses a folder holding a link on the way to the Claude config" '[ "$CODE" = 64 ]'
  mkdir -p "$TMP/h10/sub" "$TMP/p10" "$TMP/else10"; ln -s ../../else10/rc "$TMP/h10/sub/x"; ln -s sub/x "$TMP/h10/.bashrc"
  HOME="$TMP/h10" run_exec -d "$TMP/p10"
  check "a relative protected chain elsewhere does not refuse unrelated runs" '[ "$CODE" = 0 ]'
  HOME="$TMP/h10" run_exec -d "$TMP/else10"
  check "refuses the folder a relative chain with .. ends in" '[ "$CODE" = 64 ]'
  # A loop that grows on every turn cannot be opened by any system either.
  mkdir -p "$TMP/h11" "$TMP/ok11"; ln -s .loop/child "$TMP/h11/.loop"
  HOME="$TMP/h11" run_exec -d "$TMP/ok11"
  check "a growing link loop in the home does not refuse unrelated runs" '[ "$CODE" = 0 ]'
  # A protected link to the filesystem root protects everything below it.
  mkdir -p "$TMP/h12" "$TMP/ok12"; ln -s / "$TMP/h12/.root"
  HOME="$TMP/h12" run_exec -d "$TMP/ok12"
  check "a protected link to / refuses write runs" '[ "$CODE" = 64 ]'
  # A folder (or missing name) that a later ".." leaves could be replaced by a link.
  mkdir -p "$TMP/h13" "$TMP/w13/repo/bridge" "$TMP/w13/other"; ln -s "$TMP/w13/repo/bridge/../../bashrc" "$TMP/h13/.bashrc"
  HOME="$TMP/h13" run_exec -d "$TMP/w13/repo"
  check "refuses a folder holding a folder a protected path leaves with .." '[ "$CODE" = 64 ]'
  HOME="$TMP/h13" run_exec -d "$TMP/w13/other"
  check "a protected path with .. does not refuse unrelated runs" '[ "$CODE" = 0 ]'
  mkdir -p "$TMP/h14" "$TMP/w14/repo"; ln -s "$TMP/w14/repo/ghost/../../rc" "$TMP/h14/.bashrc"
  HOME="$TMP/h14" run_exec -d "$TMP/w14/repo"
  check "refuses a folder holding a missing name a protected path leaves with .." '[ "$CODE" = 64 ]'
  mkdir -p "$TMP/h15/proj"; ln -s ../shared15/cfg "$TMP/h15/.cfg"
  HOME="$TMP/h15" run_exec -d "$TMP/h15/proj"
  check "a home link going up with .. does not refuse runs inside the home" '[ "$CODE" = 0 ]'
  # Names with a newline cannot be checked, so write runs are refused.
  mkdir -p "$TMP/h16" "$TMP/ok16" "$TMP/h16/.a
b"
  HOME="$TMP/h16" run_exec -d "$TMP/ok16"
  check "a protected name with a newline refuses write runs" '[ "$CODE" = 64 ]'
  # Links are looked at again once ".." leaves a missing name.
  mkdir -p "$TMP/out17" "$TMP/w17/nested"; ln -s "$TMP/w17" "$TMP/out17/bridge"
  CLAUDE_CONFIG_DIR="$TMP/out17/missing/../bridge/nested/config" run_exec -d "$TMP/w17"
  check "refuses a run holding a link reached after .. leaves a missing name" '[ "$CODE" = 64 ]'
  # A trailing newline in -d is not dropped on the way to the checks.
  mkdir -p "$TMP/nl18" "$TMP/nl18
"
  run_exec -d "$TMP/nl18
"
  check "refuses a working directory whose name ends in a newline" '[ "$CODE" = 64 ]'
  # A link Codex plants in the git dir during the run stops the second snapshot.
  PL=$(new_repo planted)
  STUB_LINK="$PL/.git/planted" run_exec -d "$PL"
  check "no change report after Codex adds a link to the git dir" '[ "$CODE" = 0 ] && grep -q "changed or gained links during the run" "$RUN/note.txt"'
fi
if ! $WINDOWS && [ "$(id -u)" != 0 ]; then
  R4="$TMP/runs4"; mkdir -p "$R4/20260101-000000-1-1"; : > "$R4/.codex-worker-runs"; chmod 600 "$R4"
  CODEX_WORKER_RUNS="$R4" "$SH" "$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
  check "purge fails on a runs root it cannot search (marker hidden)" '[ $? != 0 ] && chmod 700 "$R4" && [ -f "$R4/.codex-worker-runs" ] && [ -d "$R4/20260101-000000-1-1" ]'
  chmod 700 "$R4"
fi
if [ "$GIT_MINOR" -ge 42 ]; then
  CWA=$(new_repo cw-a); CWB=$(new_repo cw-b); git -C "$CWA" config core.worktree "$CWB"
  run_exec -d "$CWA" -w
  check "-w refuses a core.worktree that points at another repository" '[ "$CODE" = 64 ] && ! git -C "$CWB" branch --list "codex/*" | grep -q .'
  run_exec -d "$CWA" -s read-only
  check "change report is disabled for a redirected top level" 'grep -q "core.worktree" "$RUN/note.txt"'
fi
mkdir -p "$TMP/fakehome/Documents/PowerShell"
HOME="$TMP/fakehome" run_exec -d "$TMP/fakehome/Documents/PowerShell"
check "refuses the PowerShell profile folder as a write workdir" '[ "$CODE" = 64 ]'

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
