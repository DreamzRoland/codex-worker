# codex-worker

Use **OpenAI Codex as a subagent in Claude Code.**

`codex-worker` is a Claude Code subagent that hands a task to your local
[Codex CLI](https://github.com/openai/codex), lets it run in the background, and
returns a short receipt: exit code, thread id, which files changed, and a preview
of the answer. Claude stays the orchestrator; Codex (GPT models) does the work.

English | [简体中文](README.zh-CN.md)

```text
You ──▶ Claude Code (main session)
          │  Agent(subagent_type: "codex-worker", prompt: "...")
          ▼
        codex-worker  (thin dispatcher, Claude Haiku by default)
          │  1. codex-run.sh new            → run dir
          │  2. Write prompt.txt
          │  3. codex-run.sh exec … &       → background Bash
          │       └─ codex exec --json -o answer.md …   (your Codex login & config)
          │  4. woken up when it finishes → codex-run.sh receipt
          ▼
        receipt  ─────────────────────────▶ back to the main session
```

## Why

Claude Code subagents can only run Anthropic models, so a "Codex subagent" is
always a small Claude agent that drives Codex. This project keeps that wrapper
as thin, cheap and safe as possible:

- **Claude can dispatch, wait for and collect Codex runs on its own**, several in
  parallel, and continue a Codex thread by id.
- **Answers are written to disk**; only a receipt (≈1 KB) comes back, so long
  Codex output does not fill Claude's context.
- **Change report**: git snapshots (with content hashes) before and after each run
  list the Git-visible files that changed, including second edits to files that
  were already dirty and paths with spaces or non-ASCII names.
- **Worktree isolation** (`-w`): each write task gets its own branch and worktree,
  so parallel tasks never collide and your checkout stays untouched.
- **Pinned sandbox**: the launcher fixes the sandbox mode, network flag, extra
  writable roots and approval policy on the command line, so a user or project
  Codex config cannot widen them.
- **Allowlist guard**: a fail-closed PreToolUse hook lets the dispatcher run only
  the launcher (`new` / `exec` / `receipt` with validated options) and write only
  `<run dir>/prompt.txt`.
- **Structured output** via a bundled JSON Schema for review findings.
- Works with the Bash tool **and** the PowerShell tool (Windows CLI sessions only
  have PowerShell).

### Compared with the official plugin

[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) is great for
human-driven use (`/codex:review`, `/codex:rescue`). Its status/result commands
cannot be invoked by the model, and its sandbox is either read-only or
workspace-write. `codex-worker` is for letting **Claude** orchestrate Codex. The
two install side by side.

| | official plugin | codex-worker |
|---|---|---|
| Claude collects results itself | no (`/codex:result` is user-only) | yes |
| Parallel runs in isolated worktrees | not built in | yes (`-w`) |
| Continue a thread by exact id | `--resume-last` | `-r <thread-id>` |
| Structured JSON output | reviews | any task (`-o`) |
| Answer kept out of Claude's context | no | yes (receipt + file) |
| Interactive review commands | yes | no (use the plugin) |

## Requirements

- [Claude Code](https://code.claude.com) (CLI or desktop app), recent enough that a
  background subagent is re-invoked when its background command finishes
  (verified with 2.1.312)
- [Codex CLI](https://github.com/openai/codex), logged in: `npm install -g @openai/codex && codex login`
  (verified with 0.166.0)
- Node.js 18+ and Git 2.42+ (older Git works, but the change report and `-w` are
  then disabled, because they rely on `GIT_ATTR_SOURCE` to keep repository filters
  from running). On Windows: Git for Windows (provides Git Bash).
- perl (or `flock`) for the lock that keeps runs at the same time apart; macOS,
  Git for Windows and most Linux systems ship perl.

## Install

```bash
git clone https://github.com/DreamzRoland/codex-worker.git
cd codex-worker
./install.sh                 # macOS / Linux / Git Bash
```

Windows PowerShell:

```powershell
git clone https://github.com/DreamzRoland/codex-worker.git
cd codex-worker
.\install.ps1
```

Then **start a new Claude Code session**: agents are loaded at startup.

Installer options: `--model <claude-model-id>` (dispatcher model, default
`claude-haiku-5-5`), `--force` (replace a `codex-worker.md` you wrote yourself;
it is backed up first), `--bash-exe <path>` (Windows, if Git Bash is not
auto-detected). `CLAUDE_CONFIG_DIR` is honoured.

## Usage

Just ask Claude, in plain words:

> Use codex-worker to review `src/auth` in E:/proj for security bugs, read only, return JSON.

> Ask Codex (gpt-5.6-sol, high effort) to fix the failing test in ~/code/api.

> In parallel, have Codex implement A and B in ~/code/app, each in its own worktree.

The dispatcher turns your words into launcher options:

| You say | Option | Default |
|---|---|---|
| the folder / repo (not your home, a drive root, or Claude/Codex config folders) | `-d <dir>` | current directory |
| "read only", or a pure review/research task | `-s read-only` | `workspace-write` |
| "isolated", "worktree", "in parallel" | `-w` | off |
| "allow network" | `-n` (write tasks only) | off |
| a Codex model / effort | `-m <model>` `-e <effort>` | `~/.codex/config.toml` |
| "JSON", "structured findings" | `-o findings.schema.json` | off |
| "continue the last Codex task" | `-r <thread-id>` | new thread |

For a follow-up of the same kind in the same repository (another review round,
a fix after a review), continue the codex-worker subagent you used before
(Claude Code's SendMessage) rather than starting a new one: it resumes its Codex
thread with `-r`, so neither Claude nor Codex rebuilds its context. Claude Code
does not do this by itself (each Agent call starts a new subagent); the agent's
description asks Claude to. A subagent's prompt cache lives five minutes by
default, so a quick follow-up also reads that cache.

A receipt looks like this:

```text
Codex finished, exit 0.

Answer:  ~/.cache/codex-worker/runs/20261101-142125-25472-32722/answer.md (511 bytes)
Thread:  01a195c5-34b3-7bb0-9dad-a9c63818e066
Run dir: ~/.cache/codex-worker/runs/20261101-142125-25472-32722
Branch:  codex/20261101-142125-25472-32722  (uncommitted edits are in the worktree …/worktree)
Changed: 1 path(s) (Git-visible files)
           calc.py

--- answer ---
Fixed add() to return a + b. Verified with python -c …; no deviations.
```

With `-w`, Codex works in a separate worktree checked out on a new `codex/<run>`
branch. Its edits stay uncommitted in that worktree unless Codex commits them;
review, commit, merge or discard them yourself. The worktree starts from the last
commit, so uncommitted work in your checkout is not visible to Codex (the receipt
notes this when your checkout is dirty).

The launcher can also be used without Claude:

```bash
RUN=$(~/.claude/codex-worker/codex-run.sh new)
echo "Explain what main.py does" > "$RUN/prompt.txt"
~/.claude/codex-worker/codex-run.sh exec "$RUN" -d . -s read-only
```

## Security model

What protects you, from the inside out:

1. **Codex's own sandbox** is the real boundary for what Codex does. The launcher
   runs it as `read-only` or `workspace-write`, never `danger-full-access`, and
   pins on the command line: `sandbox_workspace_write.network_access` (off unless
   `-n`), `sandbox_workspace_write.writable_roots=[]` and `approval_policy="never"`.
   Command-line overrides take precedence over `~/.codex/config.toml` and trusted
   project `.codex/config.toml` files. `workspace-write` lets Codex write inside
   the working directory and Codex's temporary directories (`/tmp`, `$TMPDIR`).
2. **The working directory of write runs is checked**: the launcher refuses your
   home folder, filesystem, drive and network share roots, hidden folders in your home (`.ssh`,
   `.config`, ...), `AppData/Roaming`, `AppData/Local/Microsoft`,
   `Documents/PowerShell`, `Documents/WindowsPowerShell` and
   `~/Library/LaunchAgents`, and any folder that contains or is inside the Claude
   config dir, the Codex config dir, the runs root or the installed launcher, so
   Codex cannot be told to write to the guard, your configuration or the startup
   locations listed here. Each folder is also refused where it physically lives,
   even before it exists: the path is followed one name at a time through links
   and junctions (also dangling ones, links to files and links in parent
   folders, so a folder holding the real target of a linked `~/.bashrc` is
   refused), and every place a run could change to move the folder may not be
   in the run either: each link met on the way, and each folder or missing name
   that a later `..` leaves. Drive (`C:/...`) and UNC (`//server/share/...`)
   spellings are understood. If a protected path cannot be resolved (for
   example it passes a folder that cannot be searched, or a name has a newline
   in it), the write run is refused; a link loop, or a chain longer than any system follows, protects
   its own path and the links on it. Links inside the Claude and Codex
   configuration, `~/.ssh`, `~/.gnupg`, `~/.config` (or `$XDG_CONFIG_HOME`),
   `$ZDOTDIR`, `~/Library/LaunchAgents` and the Windows Startup and
   PowerShell folders (all the way down), and inside the other hidden folders
   of your home (three levels down), protect their targets too (for example a
   `settings.json` linked from a dotfiles repository). These folders are
   walked where they physically live (one may be a link itself), and so is
   every folder such a link leads to (at most 64; more refuses the write run).
   A link found in a folder walked all the way leads to a folder walked all
   the way too; a folder a link of another hidden folder leads to is
   protected but not walked. A link to the filesystem root or to a folder
   above it opens a whole tree rather than naming configuration (Wine's
   `dosdevices/z:`, say) and protects only its own path. A link whose target
   stays in its own folder needs nothing more, and links into the large
   protected folders that are not walked
   (`AppData/Roaming`, `AppData/Local/Microsoft`, and `~/Library` on macOS)
   are not followed further. On macOS all of `~/Library` is protected.
   `$XDG_CONFIG_HOME`,
   `$XDG_DATA_HOME`, `$ZDOTDIR` and the `$XDG_CONFIG_DIRS` entries are
   protected wherever they point. Other places a shell or login may run code
   from (`~/bin`, folders on `PATH`) are not covered. On
   Windows the configured Documents, Roaming and Local AppData, Startup and
   user profile folders are asked from the system PowerShell (absolute path, no
   profiles, time limit), so a moved Documents (OneDrive) or a `HOME` that is
   not your profile is covered; if Windows cannot be asked, write runs are
   refused. Folders are compared as files as well as by spelling, so another
   case (also outside ASCII) or Unicode form of a name does not get around the
   check, and the working directory is resolved again right before Codex
   starts: a run whose folder was replaced since the check is refused.
   **Runs at the same time** are kept apart: a write run could replace a
   folder another run writes to, or tamper with a repository another run's
   git uses outside the sandbox. Before git first looks at the repository,
   every run (read-only ones too) claims the folders Codex may write and the
   folders the launcher's git uses (the working directory, the repository's top
   level and its git directories), and the claim lasts until Codex's whole
   process group has ended (a run whose launcher was killed still holds it;
   processes Codex leaves behind are stopped when it ends). A run is refused
   (exit 64, its run dir stays usable) when one of its writable folders lies
   inside or holds one of another live run's, or when a writable folder of
   one run and a folder the other's git uses overlap in either direction; then
   every folder is checked again. So two runs cannot work in one folder or
   repository while one of them writes there, but `-w` runs can, each in its
   own worktree. Claims are compared across every runs root on the per-user
   list `~/.cache/codex-worker/runs-roots`, and every runs root on it is
   protected like your own, even once it is gone or lost its marker (a run
   could make it again), until `--uninstall --purge` takes it off the list;
   a runs root is taken into use (listed and given its marker) only where it
   and no running write run's writable folder overlap, checked each time it is
   used, and every claim checks the listed roots again. Installed launchers
   always use that folder (`$CODEX_WORKER_STATE` only moves it for a launcher
   run from a checkout). Claims and new runs roots are handled under one lock,
   `claims.flock` there, an flock(2) lock that the system releases whenever
   its holder ends. A `-w` run is refused when the repository's git
   directories lie in a protected place (checked like a working directory),
   since git writes branches and worktree records there. This check bounds writes only (see the first limit below).
   Read-only runs may use any folder that no write run holds, since they
   cannot write.
3. **The guard hook** constrains the Claude dispatcher, not Codex. It is an
   allowlist that fails closed: shell calls must be exactly the installed launcher
   with an allowed subcommand and validated options (no operators, variables,
   expansions, redirections, other programs, `-G`, or option-looking values;
   quoted values may only contain letters, digits, spaces and `._:/=+,@()-`, which
   also rules out the Unicode quotes PowerShell honours). Write may only create
   `prompt.txt` in an existing run directory that is not a link. The dispatcher has
   no Read tool. Malformed hook input is blocked, and the hook is declared with
   `onFailure: block` so a crashing hook blocks too (on Claude Code versions that
   support it; on older ones a hook that fails to start is non-blocking).
4. **Your Claude Code permission mode** still applies to the dispatcher on top of
   the guard.

### Scope of protection

The checks above are meant to keep a prompt-injected Codex run from writing,
now or through a later or concurrent run, to the places listed, and from
spoofing receipts. They do not cover:

- **Processes that leave Codex's process group.** A compromised run can start
  a daemon in a new session (`setsid`, a double fork) or, on Windows, leave a
  native process behind once Codex exits. Such a process keeps the sandbox's
  write access to that run's folders after the run's claim has ended, and can
  later tamper with a run working inside them. Containing that needs an
  operating-system container (a cgroup, a Windows Job Object), which a shell
  launcher cannot provide; after a run you do not trust, check for such
  processes before starting runs in or below its folders.
- **Places that load code but are not listed**: folders on `PATH`, `~/bin`,
  files sourced from outside the hidden home folders, links deeper than three
  levels in hidden home folders that are not configuration folders, and links
  inside `AppData/Roaming`, `AppData/Local/Microsoft` and `~/Library`.
- **Other users, root, and a different `HOME`** (the protected places follow
  the `HOME` the launcher sees), and flaws in Codex's own sandbox.
- **The shared temporary folders**: concurrent write runs can all write to
  `/tmp` (or `TEMP`), so they can see and change each other's temporary files.

Limits you should know about:

- **Codex can read anything your user account can read, in every mode.** The
  sandbox and the working-directory check limit where Codex writes, not what it
  reads: SSH keys, cloud credentials and `.env` files elsewhere on disk are
  readable, and what Codex reads goes to your model provider. A prompt-injected
  repository can ask for that. Do not run it where that matters.
- **Network off covers sandboxed commands only.** MCP servers, apps and web search
  that you enabled in your Codex configuration keep working and can reach the
  network. Disable them in your Codex config if you need a strict egress boundary.
- **Your Codex configuration and environment are trusted** (`CODEX_HOME`, profiles,
  model and provider settings). The launcher pins the sandbox keys above, nothing
  else.
- **Codex reads untrusted repository content.** Prompt injection inside the repo
  can steer Codex within its sandbox; review its changes like any contribution.
- **The change report is best effort**: it lists Git-visible net changes. Ignored
  files (for example `.env`) are not listed, and a run that edits and restores a
  file shows no change.
- **Git runs outside the sandbox** for snapshots and worktrees. For those calls
  repository `core.fsmonitor` and hooks are disabled, and attributes are read from
  the empty tree (`GIT_ATTR_SOURCE`, Git 2.42+) so clean/smudge/process filters
  configured by the repository never run, including filters selected through
  `.git/info/attributes` (every `filter.*` driver is overridden with an empty
  command). Submodules are not entered and implicit fetches are disabled
  (`protocol.allow=never`, `GIT_NO_LAZY_FETCH`), so transport programs such as
  `core.sshCommand` never start. Other repository config (for example aliases or a
  custom `diff.external`) is not used by these commands. Snapshots run with
  `GIT_OPTIONAL_LOCKS=0`, so `git status` does not rewrite the index; Git may
  still update repository metadata in a repository that uses a split index or a
  sparse index. Symbolic links are recorded by their target string, and files
  under a linked parent directory are not hashed, so nothing is read through a
  link. Git follows links when it writes (index files during `status`; refs,
  reftable, config and the registration for `-w`), so if the git directory
  contains any link or junction outside `hooks/`, or `core.worktree` makes the
  top level belong to a different git directory, the change report is disabled
  and `-w` is refused. Both the common and the per-worktree git directory are
  checked, and checked again after the run before the second snapshot. A `-w` run writes to the repository: a new branch and
  worktree registration, without `branch.*` tracking config.
- **`--uninstall --purge` is conservative**: it only touches run directories under
  a root that carries the `.codex-worker-runs` marker, removes them with `rm`
  (links and NTFS junctions are removed as links, never followed; both are
  covered by the tests), and unregisters only the matching worktree, including
  relative registrations (`worktree.useRelativePaths`). Runs that are still in
  progress are skipped. Directories Codex left without permissions inside a run
  are made accessible first (`chmod -R`, which does not follow links). If
  something still cannot be removed, or the runs root, a run's state files, the
  repository or its registrations cannot be read, purge exits
  non-zero and keeps what a retry needs (the run's `repo` file, its
  registration, the root marker and the recorded runs root); run it again once
  the files are free. `codex/*` branches are never deleted.
- **Prompts and answers are stored in plain text** in private run directories
  (mode 700 on Linux/macOS; on Windows they inherit your profile's ACLs) under
  `~/.cache/codex-worker/runs` (or the `$CODEX_WORKER_RUNS` given at install time)
  until you delete them. Codex may also write to the temporary folders (`/tmp`,
  `/var/tmp`, `$TMPDIR`, the macOS per-user temporary folder, and `TEMP`/`TMP`
  on Windows), so they get the same checks as the working directory: a write
  run is refused while the runs root, the Claude or Codex configuration or any
  other protected folder is in one of them (the launcher writes the receipt
  into the run directory after Codex ends, outside the sandbox). No writable
  folder may lie inside another, as the run could replace the inner one (by a
  link, say) while Codex runs: a write run is refused for a working directory
  inside a temporary folder (such as `/tmp/project`) or holding one, or a
  `$TMPDIR` inside the working directory, and so is one where a link on the
  way to `/tmp` or another fixed temporary folder lies in a writable folder. A
  `$TMPDIR` (or `TEMP`/`TMP`) that is not a folder that can be entered refuses
  write runs too, and Codex gets these variables set to where the folders
  physically live, so no link on the way can be changed during the run. On
  Windows a write run is also refused when `TEMP` and `TMP` are both unset
  (Windows would use your profile) or the environment has another spelling of
  them, such as `Temp`. Receipts carry no terminal control characters (C0,
  C1, or the marks that reorder text): Codex's answer and errors lose them,
  and changed paths have them escaped. The
  installer warns about a runs root or configuration in a temporary folder;
  read-only runs are not affected.
- Codex's own claims ("tests pass") are relayed as claims, not verified facts.

## What gets installed

| Path | Purpose |
|---|---|
| `~/.claude/agents/codex-worker.md` | the subagent (rendered from `agent/codex-worker.md.tmpl`) |
| `~/.claude/codex-worker/codex-run.sh` | launcher |
| `~/.claude/codex-worker/codex-guard.mjs` | PreToolUse guard hook |
| `~/.claude/codex-worker/codex-guard.json` | guard configuration (launcher, Git Bash, runs root, schema paths) |
| `~/.claude/codex-worker/findings.schema.json` | JSON Schema for structured findings |
| `~/.claude/codex-worker/runs-root` | runs root recorded at install time; the installed launcher always uses it (`CODEX_WORKER_RUNS` only matters when you install or uninstall) |

Uninstall: `./install.sh --uninstall` (or `.\install.ps1 --uninstall`). Add `--purge`
to delete run directories as well: only directories created by the launcher are
removed (the runs root must carry its `.codex-worker-runs` marker), their git
worktrees are unregistered, and `codex/*` branches in your repositories are kept.

## Troubleshooting

- **`Agent type 'codex-worker' not found`**: start a new session after installing.
- **`codex-guard blocked this call`**: the dispatcher tried a command outside the
  allowlist. It should retry with the exact launcher form; if it keeps failing,
  re-run the installer (the guard compares against the paths in `codex-guard.json`).
- **Subagent fails with a 404 / "model not found"**: check that `ANTHROPIC_DEFAULT_HAIKU_MODEL`
  in `~/.claude/settings.json` (often written by provider switchers) is not pointing to a
  model your endpoint does not serve, or install with `--model claude-sonnet-5-5`.
- **"I have no shell tool"**: re-run the installer; on Windows the CLI only offers the
  PowerShell tool, which the agent uses through Git Bash.
- **Windows: PowerShell runs WSL instead of Git Bash**: plain `bash` usually resolves to
  `C:\Windows\System32\bash.exe`; the installer always writes the explicit Git Bash path.
  Pass `--bash-exe` if it was not found.
- **Codex not logged in**: run `codex login`.
- **Headless `claude -p`**: in our tests a Codex run started by a subagent inside
  `claude -p` did not exit until `-p` stopped its background tasks (10-minute ceiling).
  Interactive sessions are not affected. Prefer interactive use for now.

## Development

```bash
bash tests/test.sh      # offline suite: stub codex, temporary CLAUDE_CONFIG_DIR
```

CI runs the suite on Ubuntu, macOS and Windows, plus ShellCheck. Issues and PRs
are welcome; please add a test for any behaviour change.

## Related projects

- [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc): official Codex plugin for Claude Code
- [PeterSR/claude-code-codex-subagent](https://github.com/PeterSR/claude-code-codex-subagent)
  (MIT): an earlier take on the same idea, whose receipt-not-transcript design
  inspired this one; the findings schema and the prompt guardrails are adapted
  from it (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md))

## License

[MIT](LICENSE). Parts adapted from other projects keep their notices in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Not affiliated with OpenAI or Anthropic.
