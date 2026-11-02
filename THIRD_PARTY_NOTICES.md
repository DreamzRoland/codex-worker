# Third-party notices

codex-worker is its own code (MIT, see [LICENSE](LICENSE)), but two parts are
adapted from other open-source projects, and its design owes ideas to them.

## PeterSR/claude-code-codex-subagent

<https://github.com/PeterSR/claude-code-codex-subagent> (MIT License)

- `schemas/findings.schema.json` is adapted from that project's
  `schemas/findings.schema.json`: the same structure and fields (`summary`,
  `findings` with `title`, `severity`, `confidence`, `file`, `line`, `detail`,
  `failure_scenario`, and `open_questions`), with other severity and
  confidence values and a `$schema`/`title`.
- The guardrails `bin/codex-run.sh` appends to every prompt (`GUARDRAILS`) are
  a shortened adaptation of the guardrails that project appends to its prompts.
- The design of returning a short receipt (with the answer kept in a file)
  instead of Codex's transcript was inspired by it.

The license of that project:

```text
MIT License

Copyright (c) 2026 Peter Severin Rasmussen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## openai/codex-plugin-cc

<https://github.com/openai/codex-plugin-cc> (Apache License 2.0,
<https://www.apache.org/licenses/LICENSE-2.0>)

A few guardrail phrasings ("keep changes tightly scoped to the task", "do not
guess missing repository facts", "verify the result") follow the prompting
guidance of OpenAI's official Codex plugin for Claude Code, which the project
above draws on as well. No code from it is included.
