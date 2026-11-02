#!/usr/bin/env node
// codex-guard: PreToolUse hook for the codex-worker subagent.
//
//   node codex-guard.mjs <codex-guard.json>
//
// An allowlist that fails closed (exit 2 blocks the tool call):
//   Bash / PowerShell  only the installed launcher, as
//                        <launcher> new
//                        <launcher> exec <run-dir> -d DIR [-s read-only|workspace-write] [-n] [-w]
//                                                  [-m MODEL] [-e EFFORT] [-o <bundled schema>] [-r UUID]
//                        <launcher> receipt <run-dir>
//                      PowerShell must prefix "& <git-bash> ". Quoted arguments may only
//                      contain letters, digits, spaces and a few path characters, so no
//                      shell syntax (including Unicode quotes PowerShell honours) can hide
//                      inside them.
//   Write              only <runs-root>/<run-id>/prompt.txt, where the run dir is a real
//                      directory created by the launcher and prompt.txt is not a link
//   anything else      blocked
// The config file is written by the installer: {launcher, bashExe, runsRoot, schema}.

import fs from "node:fs";
import path from "node:path";

const WINDOWS = process.platform === "win32";
const RUN_ID = /^[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$/;
const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const MODEL = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
const SAFE_BARE = /^[A-Za-z0-9._:/=+-]+$/;
// Inside quotes: any letter or digit (paths may be non-ASCII), combining marks,
// space and a few ASCII path characters. Excludes every quote, dash, operator
// and separator character, ASCII or Unicode.
const SAFE_QUOTED = /^[\p{L}\p{N}\p{M} ._:/=+,@()-]*$/u;
const VALUE_FLAGS = new Set(["-d", "-s", "-m", "-e", "-o", "-r"]);
const BARE_FLAGS = new Set(["-n", "-w"]);
const EFFORTS = new Set(["none", "minimal", "low", "medium", "high", "xhigh"]);

function block(reason) {
  process.stderr.write(
    `codex-guard blocked this call: ${reason}.\n` +
      "codex-worker may only run its launcher (new / exec / receipt) and write <run dir>/prompt.txt.\n",
  );
  process.exit(2);
}
process.on("uncaughtException", () => block("internal guard error"));

// Comparison form of a path. Windows: backslashes become slashes, Git Bash /c/
// drives become c:/, case is ignored. Elsewhere backslash is an ordinary
// character, so paths containing one are rejected rather than reinterpreted.
function norm(p) {
  let s = String(p);
  if (WINDOWS) {
    s = s.replace(/\\/g, "/").replace(/^\/([a-zA-Z])(\/|$)/, "$1:/").toLowerCase();
  } else if (s.includes("\\")) {
    block("backslashes are not allowed in paths");
  }
  if (s.startsWith("//")) block("network (UNC) paths are not allowed");
  if (/\/\/|\/\.\.?(\/|$)/.test(s)) block("paths must not contain //, /./ or /../");
  return s.length > 1 ? s.replace(/\/$/, "") : s;
}

function splitWords(command) {
  const words = [];
  let i = 0;
  while (i < command.length) {
    const c = command[i];
    if (c === " ") { i++; continue; }
    if (c === '"' || c === "'") {
      const end = command.indexOf(c, i + 1);
      if (end < 0) block("unbalanced quotes");
      const next = command[end + 1];
      if (next !== undefined && next !== " ") block("quotes must enclose a whole argument");
      const text = command.slice(i + 1, end);
      if (!SAFE_QUOTED.test(text)) block(`unsupported characters inside quotes: ${JSON.stringify(text)}`);
      words.push(text);
      i = end + 1;
      continue;
    }
    let j = i;
    while (j < command.length && command[j] !== " ") j++;
    const text = command.slice(i, j);
    if (!(words.length === 0 && text === "&") && !SAFE_BARE.test(text)) {
      block(`unsupported characters in ${JSON.stringify(text)}`);
    }
    words.push(text);
    i = j;
  }
  return words;
}

function isRunDir(value, cfg) {
  const p = norm(value);
  const root = norm(cfg.runsRoot);
  return p.startsWith(root + "/") && RUN_ID.test(p.slice(root.length + 1));
}

function checkShell(tool, command, cfg) {
  // Only the blanks the shell itself skips are trimmed: String.trim() also drops
  // Unicode spaces (U+00A0, U+FEFF, ...) that bash keeps as part of the first
  // word, which would then name a program relative to the current folder.
  // Two scans, not a regex: /[ \t\n]+$/ takes quadratic time on long runs of
  // blanks, and a hook that times out lets the command through.
  const s = typeof command === "string" ? command : "";
  let a = 0, b = s.length;
  while (a < b && " \t\n".includes(s[a])) a++;
  while (b > a && " \t\n".includes(s[b - 1])) b--;
  const text = s.slice(a, b);
  if (!text) block("no command to inspect");
  const words = splitWords(text);
  if (tool === "PowerShell") {
    if (!cfg.bashExe) block("PowerShell is not configured for this platform");
    // PowerShell resolves /d/... against the current drive, not as D:/..., so the
    // executable must be written as a native drive path.
    if (words[0] !== "&" || words.length < 2 || !/^[A-Za-z]:\//.test(words[1].replace(/\\/g, "/")) ||
        norm(words[1]) !== norm(cfg.bashExe)) {
      block(`PowerShell commands must start with: & "${cfg.bashExe}" "${cfg.launcher}"`);
    }
    words.splice(0, 2);
  }
  if (!words.length || norm(words[0]) !== norm(cfg.launcher)) block(`only the launcher may be run: ${cfg.launcher}`);
  const [, sub, ...rest] = words;

  if (sub === "new") {
    if (rest.length) block("'new' takes no arguments");
    return;
  }
  if (sub === "receipt") {
    if (rest.length !== 1 || !isRunDir(rest[0], cfg)) block("'receipt' takes exactly one run dir");
    return;
  }
  if (sub !== "exec") block("allowed subcommands are new, exec and receipt");

  const [run, ...opts] = rest;
  if (!run || !isRunDir(run, cfg)) block("'exec' needs a run dir created by 'new'");
  const seen = new Set();
  for (let k = 0; k < opts.length; k++) {
    const flag = opts[k];
    if (seen.has(flag)) block(`${flag} given twice`);
    seen.add(flag);
    if (BARE_FLAGS.has(flag)) continue;
    if (!VALUE_FLAGS.has(flag)) block(`option ${JSON.stringify(flag)} is not allowed`);
    const value = opts[++k];
    if (value === undefined || value === "") block(`${flag} needs a value`);
    if (flag === "-s" && value !== "read-only" && value !== "workspace-write") block("sandbox must be read-only or workspace-write");
    if (flag === "-e" && !EFFORTS.has(value)) block("invalid effort");
    if (flag === "-m" && !MODEL.test(value)) block("invalid model name");
    if (flag === "-r" && !UUID.test(value)) block("the thread id must be a UUID");
    if (flag === "-o" && norm(value) !== norm(cfg.schema)) block(`-o only accepts ${cfg.schema}`);
    if (flag === "-d") {
      if (value.startsWith("-")) block("-d needs a directory");
      norm(value);
    }
  }
  if (!seen.has("-d")) block("exec needs -d <dir>");
}

function realOrNull(p) {
  try { return fs.realpathSync.native(p); } catch { return null; }
}

function checkWrite(filePath, cfg) {
  if (typeof filePath !== "string" || !filePath) block("no file path to inspect");
  if (/[\\/]$/.test(filePath)) block("the file path must not end with a separator");
  // Write takes native paths: on Windows a /c/... path is not a drive path.
  if (WINDOWS && !/^[A-Za-z]:[\\/]/.test(filePath)) block("Write needs an absolute drive path such as C:/...");
  const p = norm(filePath);
  const root = norm(cfg.runsRoot);
  const suffix = "/prompt.txt";
  if (!p.endsWith(suffix) || !isRunDir(p.slice(0, -suffix.length), cfg)) {
    block("Write may only create <run dir>/prompt.txt");
  }
  // Physical containment: the run dir must be a real directory (not a link or
  // junction) whose real path is directly inside the real runs root.
  const id = p.slice(root.length + 1, -suffix.length);
  const realRoot = realOrNull(cfg.runsRoot);
  // Check the directory the tool will actually write into, not a reconstruction.
  const dir = path.dirname(filePath);
  let st;
  try { st = fs.lstatSync(dir); } catch { block("the run dir does not exist; create it with 'new'"); }
  if (!st.isDirectory() || st.isSymbolicLink()) block("the run dir is not a real directory");
  const realDir = realOrNull(dir);
  if (!realRoot || !realDir || norm(realDir) !== norm(path.join(realRoot, id))) block("the run dir escapes the runs root");
  try {
    const pst = fs.lstatSync(filePath);
    if (!pst.isFile() || pst.isSymbolicLink()) block("prompt.txt exists and is not a regular file");
  } catch (err) {
    if (err?.code !== "ENOENT") throw err;
  }
}

let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
} catch {
  block("guard configuration missing or unreadable");
}
if (!cfg?.launcher || !cfg?.runsRoot || !cfg?.schema) block("guard configuration incomplete");

let event;
try {
  event = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  block("hook input is not valid JSON");
}

const tool = event?.tool_name;
const input = event?.tool_input ?? {};
if (tool === "Bash" || tool === "PowerShell") checkShell(tool, input.command, cfg);
else if (tool === "Write") checkWrite(input.file_path, cfg);
else block(`tool ${JSON.stringify(tool)} is not covered by this guard`);
process.exit(0);
