# codex-worker

在 Claude Code 里**把 OpenAI Codex 当作子智能体使用**。

`codex-worker` 是一个 Claude Code 子智能体：它把任务交给本机的
[Codex CLI](https://github.com/openai/codex) 在后台运行，完成后只交回一张简短回执：
退出码、thread id、实际改动了哪些文件，以及答案预览。Claude 负责调度，Codex（GPT 模型）负责干活。

[English](README.md) | 简体中文

```text
你 ──▶ Claude Code 主会话
         │  Agent(subagent_type: "codex-worker", prompt: "...")
         ▼
       codex-worker（转发层，默认 Claude Haiku）
         │  1. codex-run.sh new          → 运行目录
         │  2. 写入 prompt.txt
         │  3. codex-run.sh exec … &     → 后台 Bash
         │       └─ codex exec --json -o answer.md …（使用你的 Codex 登录和配置）
         │  4. 完成后被唤醒 → codex-run.sh receipt
         ▼
       回执 ───────────────────────────▶ 交回主会话
```

## 为什么做这个

Claude Code 的子智能体只能运行 Anthropic 模型，所以所谓的"Codex 子智能体"，本质上是一个小 Claude 智能体在遥控 Codex。本项目把这层包装做得尽量薄、便宜、安全：

- **Claude 能自己派发、等待、回收 Codex 任务**，可以并行，也能按 thread id 续接。
- **答案落盘**，只回传约 1 KB 的回执，长输出不会撑满 Claude 的上下文。
- **改动报告**：运行前后各拍一次 git 快照，并且比对文件内容哈希，列出 Git 能看到的、有变化的文件。运行前已经改过的文件被再次修改、文件名含空格或非 ASCII 字符，都能正确识别。
- **worktree 隔离**（`-w`）：每个写任务有自己的分支和 worktree，并行时互不冲突，主仓库保持不动。
- **固定沙箱策略**：启动器在命令行上把沙箱模式、网络开关、额外可写目录和审批策略都写死，用户或项目里的 Codex 配置无法放宽它们。
- **白名单 guard**：一个 PreToolUse hook，遇到不认识的调用一律拦截。转发层只能运行启动器（`new` / `exec` / `receipt`，参数会校验），并且只能写 `<运行目录>/prompt.txt`。
- **结构化输出**：自带审查结果用的 JSON Schema。
- 同时支持 Bash 和 PowerShell 两种 shell 工具。Windows 上的 CLI 会话只有 PowerShell。

### 与官方插件的区别

[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) 适合你手动发起操作（`/codex:review`、`/codex:rescue`）。它的 status、result 命令模型无法调用，沙箱也只有只读和可写两档。`codex-worker` 是让 **Claude** 来编排 Codex。两者可以同时安装。

| | 官方插件 | codex-worker |
|---|---|---|
| Claude 自己收结果 | 否（`/codex:result` 只能你手动输入） | 是 |
| 在隔离的 worktree 里并行运行 | 没有内置 | 是（`-w`） |
| 按精确 id 续接线程 | `--resume-last` | `-r <thread-id>` |
| 结构化 JSON 输出 | 仅限审查 | 任何任务（`-o`） |
| 答案不进入 Claude 上下文 | 否 | 是（回执 + 文件） |
| 交互式审查命令 | 有 | 无（请用官方插件） |

## 环境要求

- [Claude Code](https://code.claude.com)（CLI 或桌面版），版本要足够新：后台子智能体的后台命令结束时，子智能体要能被重新唤醒。已在 2.1.312 上验证。
- 已登录的 [Codex CLI](https://github.com/openai/codex)：`npm install -g @openai/codex && codex login`。已在 0.166.0 上验证。
- Node.js 18+ 和 Git 2.42+。更旧的 Git 也能用，但改动报告和 `-w` 会被关闭，因为它们要靠 `GIT_ATTR_SOURCE` 防止仓库过滤器被执行。Windows 上需要 Git for Windows，它自带 Git Bash。
- perl（或 `flock`），用于隔开同时运行的任务的那把锁；macOS、Git for Windows 和大多数 Linux 系统都自带 perl。

## 安装

```bash
git clone https://github.com/DreamzRoland/codex-worker.git
cd codex-worker
./install.sh                 # macOS / Linux / Git Bash
```

Windows PowerShell：

```powershell
git clone https://github.com/DreamzRoland/codex-worker.git
cd codex-worker
.\install.ps1
```

装完后**新开一个 Claude Code 会话**，因为 agent 只在会话启动时加载。

安装选项：
- `--model <claude 模型 id>`：转发层用的模型，默认 `claude-haiku-5-5`；
- `--force`：替换你自己写的 `codex-worker.md`，替换前会先备份；
- `--bash-exe <路径>`：仅 Windows，自动找不到 Git Bash 时手动指定。

安装器支持 `CLAUDE_CONFIG_DIR` 环境变量。

## 使用

直接用自然语言告诉 Claude，例如：

> 用 codex-worker 只读审查 E:/proj 的 `src/auth` 有没有安全问题，返回 JSON

> 让 Codex（gpt-5.6-sol，高推理强度）修复 ~/code/api 里失败的测试

> 并行让 Codex 在 ~/code/app 里分别实现 A 和 B，各用独立 worktree

转发层会把你的话翻译成启动器参数：

| 你说的 | 参数 | 默认 |
|---|---|---|
| 文件夹或仓库（不能是用户主目录、盘符根目录，或 Claude/Codex 的配置目录） | `-d <dir>` | 当前目录 |
| "只读"，或者纯审查、调研类任务 | `-s read-only` | `workspace-write` |
| "隔离""worktree""并行" | `-w` | 关 |
| "允许联网" | `-n`（只对写任务有效） | 关 |
| Codex 模型和推理强度 | `-m <model>` `-e <effort>` | `~/.codex/config.toml` |
| "JSON""结构化结果" | `-o findings.schema.json` | 关 |
| "继续上次的 Codex 任务" | `-r <thread-id>` | 新线程 |

同一仓库里的同类后续任务（下一轮审查、审查之后的修复），请继续使用上次的 codex-worker 子智能体（Claude Code 的 SendMessage），而不是新开一个：它会用 `-r` 接着之前的 Codex 线程，Claude 和 Codex 都不用重建上下文。Claude Code 不会自动这样做（每次 Agent 调用都会新建子智能体），所以 agent 的说明里要求 Claude 这样做。子智能体的提示词缓存默认只保留五分钟，所以间隔较短的后续任务还能命中这份缓存。

用 `-w` 时，Codex 在一个单独的 worktree 里工作，这个 worktree 检出的是新建的 `codex/<运行名>` 分支。除非 Codex 自己提交，它的改动会以未提交的状态留在这个 worktree 里；审查、提交、合并还是丢弃，由你决定。worktree 是从最近一次提交创建的，所以你工作区里还没提交的改动 Codex 看不到；如果你的工作区有未提交改动，回执里会提醒。

## 安全模型

从内到外有四层保护：

1. **Codex 自带的沙箱**才是约束 Codex 行为的真正边界。启动器只会用 `read-only` 或 `workspace-write` 来运行 Codex，绝不用 `danger-full-access`。`workspace-write` 允许 Codex 写工作目录，以及 Codex 自己的临时目录（`/tmp`、`$TMPDIR`）。启动器还在命令行上写死了三项设置：
   - `sandbox_workspace_write.network_access`：默认关闭，加 `-n` 才打开；
   - `sandbox_workspace_write.writable_roots=[]`：不允许额外的可写目录；
   - `approval_policy="never"`。

   命令行参数的优先级高于 `~/.codex/config.toml` 和受信任项目里的 `.codex/config.toml`。
2. **写任务的工作目录会被检查**：启动器拒绝以下几种工作目录：
   - 你的用户主目录；
   - 文件系统根目录、盘符根目录或网络共享根目录（`//server/share`）；
   - 用户主目录下的隐藏文件夹（`.ssh`、`.config` 等）；
   - `AppData/Roaming`、`AppData/Local/Microsoft`、`Documents/PowerShell`、`Documents/WindowsPowerShell` 和 `~/Library/LaunchAgents`；
   - 每个受保护目录在它的物理位置上同样受保护，即使它还不存在：路径会逐级解析，跟随途经的链接和 junction（包括悬空链接、指向文件的链接和上级目录中的链接，所以存放着被链接的 `~/.bashrc` 真实文件的目录也会被拒绝）；
   - 凡是写任务改动后能让受保护目录指向别处的位置，都不能位于写任务的工作目录内：包括解析途中经过的每个链接，以及之后被 `..` 退出的每个目录或尚不存在的名字；
   - 盘符写法（`C:/...`）和 UNC 写法（`//server/share/...`）都能正确识别；
   - 受保护路径解析失败时（比如途经一个无法进入的目录，或者某个名字里含有换行符），写任务会被拒绝；循环链接，以及长到任何系统都不会跟随到底的链接链，只保护它自身的路径和途经的各个链接；
   - Claude 和 Codex 配置目录、`~/.ssh`、`~/.gnupg`、`~/.config`（或 `$XDG_CONFIG_HOME`）、`$ZDOTDIR`、`~/Library/LaunchAgents` 以及 Windows 的启动文件夹和 PowerShell 目录里面的链接（不限深度），以及家目录下其他隐藏目录里三层以内的链接，连同它们的目标一起受保护（比如从 dotfiles 仓库链接过来的 `settings.json`）。这些目录按物理位置扫描（目录本身可能就是链接），链接指向的目录也会继续扫描（最多 64 个，超过则拒绝写任务）；在完整扫描的目录里找到的链接，它指向的目录也会被完整扫描；其他隐藏目录里的链接指向的目录受保护，但不再继续扫描。指向文件系统根或指向链接所在位置上级的链接，打开的是整棵目录树，而不是某个配置（比如 Wine 的 `dosdevices/z:`），只保护链接本身的路径。目标留在本目录内的链接无需再处理；指向不扫描的大型受保护目录（`AppData/Roaming`、`AppData/Local/Microsoft`，以及 macOS 上的 `~/Library`）的链接不再继续跟随。macOS 上整个 `~/Library` 都受保护。`$XDG_CONFIG_HOME`、`$XDG_DATA_HOME`、`$ZDOTDIR` 和 `$XDG_CONFIG_DIRS` 中的各个目录，无论指向哪里都受保护；
   - 不覆盖其他可能在 shell 或登录时执行代码的位置，比如 `~/bin`、`PATH` 里的目录；
   - 在 Windows 上，"文档"、Roaming 和 Local AppData、"启动"文件夹以及用户目录的配置位置，都通过系统 PowerShell 查询（绝对路径、不加载配置文件、有超时限制）。所以"文档"被移到 OneDrive，或者 `HOME` 不是你的用户目录时，也都在保护之内。如果查询失败，写任务会被拒绝；
   - 包含或位于以下任一目录之内的目录：Claude 配置目录、Codex 配置目录、运行目录根、已安装的启动器所在目录；
   - 目录除了按拼写比较，还会按文件身份比较，所以换一种大小写（包括非 ASCII 字母）或另一种 Unicode 形式的写法都绕不过检查；Codex 启动前会再解析一次工作目录，如果它在检查之后被替换（比如换成了链接），这次运行会被拒绝。

   这样就没法让 Codex 去写 guard 本身、你的配置或登录自启动项。这项检查只限制写入，不限制读取（见下面第一条限制）。只读任务不会写入，可以使用任何目录。
3. **guard hook** 约束的是 Claude 转发层，而不是 Codex。它是白名单，遇到不认识的情况一律拦截：
   - shell 调用必须严格是"已安装的启动器 + 允许的子命令和校验过的参数"。不能有运算符、变量、展开、重定向、其他程序，不能用 `-G`，也不能有看起来像选项的参数值。引号里只允许字母、数字、空格和 `._:/=+,@()-`，所以 PowerShell 认可的 Unicode 智能引号也进不来；
   - Write 只能在一个已经存在、而且不是链接的运行目录里创建 `prompt.txt`；
   - 转发层没有 Read 工具；
   - 格式不对的 hook 输入会被拦截。hook 声明了 `onFailure: block`，所以 hook 进程本身崩溃时也会拦截。这一点需要较新版本的 Claude Code 支持；在旧版本上，如果 hook 根本没能启动，就不会拦截。
4. **你在 Claude Code 里的权限模式**在 guard 之外，照样约束转发层。

需要了解的限制：

- **无论哪种模式，Codex 都能读取你这个用户能读的任何文件。** 沙箱和工作目录检查只限制 Codex 往哪里写，不限制它读什么：磁盘上其他位置的 SSH 密钥、云服务凭据、`.env` 文件都读得到，读到的内容会发给你的模型服务商。被提示注入的仓库可以诱导它这么做。在这一点要紧的机器或仓库上不要使用。
- **"网络关闭"只对沙箱里执行的命令有效。** 你在 Codex 配置里启用的 MCP 服务器、应用和网页搜索仍然可以联网。如果需要严格隔离网络，请在 Codex 配置里把它们关掉。
- **你的 Codex 配置和环境变量是被信任的**，包括 `CODEX_HOME`、profile、模型和服务商设置。启动器只固定上面那几个沙箱相关的键。
- **Codex 会读取仓库里不可信的内容。** 仓库里的提示注入可以在沙箱范围内影响 Codex 的行为，请像审查别人提交的代码一样审查它的改动。
- **改动报告只是尽力而为**：它列出的是 Git 能看到的净变化。被 Git 忽略的文件（比如 `.env`）不会列出；一个文件被改了又改回原样，也会显示没有变化。
- **Git 在沙箱外运行**，用于拍快照和创建 worktree。这些调用做了以下防护：
  - 禁用仓库自带的 `core.fsmonitor`；
  - 禁用仓库的 hooks；
  - 让 git 从空树读取属性（`GIT_ATTR_SOURCE`，需要 Git 2.42+），并把每个 `filter.*` 驱动都置空。这样仓库配置的 clean/smudge/process 过滤器都不会被执行，包括通过 `.git/info/attributes` 选中的过滤器；
  - 不进入子模块，并禁用隐式获取（`protocol.allow=never`、`GIT_NO_LAZY_FETCH`），所以 `core.sshCommand` 这类传输程序不会被启动；
  - 快照使用 `GIT_OPTIONAL_LOCKS=0`，`git status` 不会改写索引；但如果仓库用了 split index 或 sparse index，Git 仍可能更新仓库元数据；
  - 符号链接只按其目标字符串记录，位于链接目录之下的文件也不做哈希，所以不会顺着任何链接去读文件。
  
  git 写文件时会跟随链接（`status` 时写索引文件，`-w` 时写 refs、reftable、config 和 worktree 登记）。所以出现以下两种情况时，改动报告会关闭，`-w` 会被拒绝：
  - git 目录里 `hooks/` 以外有任何链接或 junction；
  - `core.worktree` 让仓库顶层属于另一个 git 目录。

  公共 git 目录和 per-worktree git 目录都会检查，运行结束后、第二次快照之前还会再检查一遍。

  `-w` 任务会写仓库：新建分支并登记 worktree，但不写 `branch.*` 跟踪配置。
- **`--uninstall --purge` 很保守**：
  - 只处理带 `.codex-worker-runs` 标记的根目录下的运行目录；
  - 用 `rm` 删除，链接和 NTFS junction 都只当作链接删掉，不会顺着进入别处，这两种情况都有测试覆盖；
  - 只注销与之对应的 worktree，包括相对路径登记（`worktree.useRelativePaths`）。
  
  仍在运行的任务会被跳过。运行目录里被 Codex 去掉权限的子目录，会先用 `chmod -R`（不跟随链接）恢复访问权限再删除。仍有东西删不掉，或者运行目录根、某个运行的状态文件、仓库及其 worktree 登记无法读取时，purge 以非零状态退出，并保留重试所需的信息：该运行的 `repo` 文件、它的 worktree 登记、根目录标记和记录下来的运行目录根。等没有程序占用这些文件后再运行一次即可。`codex/*` 分支永远不删。
- **提示词和答案以明文保存**在私有的运行目录里，位置是 `~/.cache/codex-worker/runs`（或安装时 `$CODEX_WORKER_RUNS` 指定的位置），直到你手动删除。Codex 也可以写临时目录（`/tmp`、`/var/tmp`、`$TMPDIR`、macOS 的用户临时目录，Windows 上还有 `TEMP`/`TMP`），所以这些目录和工作目录接受同样的检查：只要运行目录根、Claude 或 Codex 配置目录或其他受保护目录位于其中，写任务就会被拒绝（启动器会在 Codex 结束后、于沙箱之外把回执写进运行目录）。可写目录之间也不能互相嵌套，否则任务可以在 Codex 运行期间把里层目录换掉（比如换成一个链接）：工作目录位于临时目录里（例如 `/tmp/project`）或包含临时目录，`$TMPDIR` 位于工作目录里，或者通往 `/tmp` 等固定临时目录的路径上有链接落在可写目录里，写任务都会被拒绝。**同时运行的任务**会被隔开，否则一个写任务可以换掉另一个任务正在写的目录，或者篡改另一个任务的 git 在沙箱外使用的仓库。每个任务（包括只读任务）在 git 第一次查看仓库之前，先登记 Codex 可能写入的目录，以及启动器的 git 要用的目录（工作目录、仓库顶层目录和 git 目录）；这份登记一直保留到 Codex 的整个进程组结束（即使启动器被杀，登记也仍然有效；Codex 结束时留下的进程会被终止）。如果一个任务的可写目录位于另一个仍在运行的任务的可写目录里面或包含它，或者一个任务的可写目录和另一个任务的 git 要用的目录有任何重叠，任务会被拒绝（退出码 64，运行目录可以重用），登记之后所有目录还会再检查一遍。所以只要其中有一个在写，两个任务就不能同时在同一个目录或仓库里工作；`-w` 任务可以并行，各自在自己的 worktree 里。登记会和每用户列表 `~/.cache/codex-worker/runs-roots` 上的所有运行目录根比对，列表上的每个运行目录根都像你自己的一样受保护，即使它已被删除或丢了标记也一样（任务可能会把它重新建出来），直到 `--uninstall --purge` 把它从列表中移除；运行目录根只有在它和任何正在运行的写任务的可写目录都不重叠时，才会被启用（登记到列表并加上标记），每次使用时都会重新检查，而且每次登记都会再核对一遍列表上的运行目录根。已安装的启动器总是使用这个目录（`$CODEX_WORKER_STATE` 只对从源码目录直接运行的启动器有效）。登记和启用新的运行目录根都在同一把锁下进行，即那里的 `claims.flock`，这是一把 flock(2) 锁，持有者无论怎样结束，系统都会释放它。`-w` 任务的 git 目录如果位于受保护的位置（按工作目录的同一套规则检查），任务会被拒绝，因为 git 会往那里写分支和 worktree 记录。`$TMPDIR`（或 `TEMP`/`TMP`）指向的不是一个可以进入的目录时，写任务同样被拒绝；启动器会把这些变量改成目录的物理路径再交给 Codex，这样路径上的链接在运行期间被改动也没有影响。在 Windows 上，如果 `TEMP` 和 `TMP` 都没有设置（Windows 会改用你的用户目录），或者环境里有大小写不同的同名变量（比如 `Temp`），写任务也会被拒绝。回执里没有终端控制字符（C0、C1 以及改变文字方向的标记）：Codex 的答案和错误信息会去掉它们，改动的路径里的则会被转义。运行目录根或配置目录位于临时目录里时，安装程序会给出警告；只读任务不受影响。在 Linux/macOS 上目录权限是 700；在 Windows 上继承你用户目录的访问权限。
- Codex 自己说的"测试通过"之类的话，只会作为 Codex 的说法转述，不当作已验证的事实。

### 防护范围

上面的各项检查，是为了防止被提示注入的 Codex 任务（无论是当前任务，还是之后或同时运行的任务）写入上面列出的位置，或者伪造回执。以下情况不在防护范围内：

- **脱离 Codex 进程组的进程**：被攻破的任务可以在新会话里启动守护进程（`setsid`、两次 fork），在 Windows 上也可以在 Codex 退出后留下原生进程。这样的进程在任务的登记结束后，仍然保有沙箱对该任务目录的写权限，之后可以篡改在这些目录里工作的任务。要把它们关住，需要操作系统级的容器（cgroup、Windows Job Object），shell 启动器做不到；跑完一个你不信任的任务后，在它的目录里或下面开始新任务之前，请先检查有没有这类进程。
- **没有列出的加载代码的位置**：`PATH` 上的目录、`~/bin`、从隐藏目录以外的位置读入的文件、非配置类隐藏目录里三层以下的链接，以及 `AppData/Roaming`、`AppData/Local/Microsoft` 和 `~/Library` 里的链接。
- **其他用户、root，以及不同的 `HOME`**（受保护的位置以启动器看到的 `HOME` 为准），还有 Codex 自身沙箱的缺陷。
- **共享的临时目录**：同时运行的写任务都能写 `/tmp`（或 `TEMP`），所以它们能看到、也能改动彼此的临时文件。

## 安装了哪些文件

| 路径 | 作用 |
|---|---|
| `~/.claude/agents/codex-worker.md` | 子智能体，由 `agent/codex-worker.md.tmpl` 渲染生成 |
| `~/.claude/codex-worker/codex-run.sh` | 启动器 |
| `~/.claude/codex-worker/codex-guard.mjs` | PreToolUse 安全 hook |
| `~/.claude/codex-worker/codex-guard.json` | guard 的配置：启动器、Git Bash、运行目录根、schema 的路径 |
| `~/.claude/codex-worker/findings.schema.json` | 结构化输出用的 JSON Schema |
| `~/.claude/codex-worker/runs-root` | 安装时记录下来的运行目录根；已安装的启动器总是使用它（`CODEX_WORKER_RUNS` 只在安装和卸载时起作用） |

卸载：`./install.sh --uninstall`（Windows 上用 `.\install.ps1 --uninstall`）。加上 `--purge` 会同时删除运行目录，规则如下：
- 只删除启动器创建的目录，而且运行目录的根必须带有 `.codex-worker-runs` 标记文件；
- 删除前会先注销这些目录对应的 git worktree；
- 你仓库里的 `codex/*` 分支会保留。

## 常见问题

- **报 `Agent type 'codex-worker' not found`**：装完后要新开会话。
- **报 `codex-guard blocked this call`**：转发层尝试执行了白名单以外的命令。它应该按启动器的标准格式重试；如果一直失败，请重新运行安装器（guard 是拿 `codex-guard.json` 里记录的路径来比对的）。
- **子智能体报 404 或 "model not found"**：检查 `~/.claude/settings.json` 里的 `ANTHROPIC_DEFAULT_HAIKU_MODEL`。这个值经常被 cc-switch 之类的供应商切换工具写入，可能指向了你的接口不支持的模型。也可以用 `--model claude-sonnet-5-5` 重新安装。
- **子智能体说"没有 shell 工具"**：重新运行安装器。Windows 上的 CLI 只提供 PowerShell 工具，agent 会通过 Git Bash 调用启动器。
- **Windows 上 PowerShell 调到了 WSL 而不是 Git Bash**：在 PowerShell 里直接写 `bash` 通常会指向 `C:\Windows\System32\bash.exe`（WSL），所以安装器总是写入 Git Bash 的完整路径。自动找不到时，用 `--bash-exe` 手动指定。
- **Codex 没有登录**：运行 `codex login`。
- **headless `claude -p` 模式**：我们测试时发现，在 `claude -p` 里由子智能体启动的 Codex 进程不会自行退出，要等 `-p` 到 10 分钟上限把后台任务结束掉。交互式会话不受影响，目前请在交互式会话里使用。

## 开发

```bash
bash tests/test.sh      # 离线测试：使用替身 codex 和临时 CLAUDE_CONFIG_DIR
```

CI 会在 Ubuntu、macOS、Windows 上运行测试，并做 ShellCheck 检查。欢迎提 Issue 和 PR；改动行为时请附上对应的测试。

## 相关项目

- [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)：OpenAI 官方的 Claude Code 插件
- [PeterSR/claude-code-codex-subagent](https://github.com/PeterSR/claude-code-codex-subagent)（MIT）：同一思路更早的实现，本项目"回传回执而不是全文"的设计受它启发；结构化结果的 schema 和附加在提示词后的约束文字改编自该项目（见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）

## 许可证

[MIT](LICENSE)。改编自其他项目的部分，其版权和许可声明保留在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。与 OpenAI、Anthropic 无关联。
