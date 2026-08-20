# Tools
Nexo attaches four sandbox-backed tools — `ReadFile`, `WriteFile`, `Shell`, and `Glob` — each gated by the [sandbox](sandboxes.md) and [permission](permissions.md) seams.

Which tools attach depends on what the sandbox supports *and* on what the permission mode could
ever allow:

- **Gated tool attach, on two axes.** An agent does not advertise a tool it could never
  successfully call, because a guaranteed failure in the schema costs a round trip every time a
  model tries it. `Agent#chat` attaches a tool only when **both** hold:

  1. *The sandbox supports the capability* (`Sandbox#supports?`). `Local`/`Container` support all
     four; `Virtual` supports everything but `:shell`, so a `:virtual` agent has no `Shell`.
  2. *The permission gate does not deny it statically* (`Permissions#never_allows?`). Under
     `:read_only`, `:write` and `:shell` can never be authorized unless listed in `allow:`, so
     neither `WriteFile` nor `Shell` is attached. `:auto`, `:ask` and `:approve` decide per call
     and always attach — `:approve` in particular *must* reach the gate so it can suspend the run.

  `ReadFile` and `Glob` are always attached. This is a cost and description-accuracy measure, not
  a security boundary: `Permissions#authorize!` remains the gate and still denies at call time.

`Shell` truncates unbounded command output before it reaches the model:

- **Shell output truncation (`Nexo::OutputTruncator`).** Unbounded command output (`npm install`,
  `git log`) is truncated before it reaches the model, so a single command can't blow a small
  context window. `Tools::Shell` wraps `stdout`/`stderr` through
  `OutputTruncator.call(text, max_lines: 200, max_chars: 16_000)` — strips ANSI escapes, keeps the
  **last** `max_lines` lines, appends a `…[truncated N lines]` marker, then caps at `max_chars`.
  The integer `status` passes through untouched. Pure line/char truncation — **no tokenizer**;
  configurable via the kwargs only (no global config, no per-agent macro).

`WriteFile` enforces a read-before-write guard so the agent can't clobber files blindly:

- **Read-before-write + stale guard (real-FS only).** Within a session, the agent is blocked from
  overwriting a file it never read, or one that changed underneath it. `Agent#chat` builds one
  `Nexo::ReadTracker` per chat and threads it into `ReadFile` (records `(path, mtime)` on a
  successful read) and `WriteFile` (enforces): overwriting an existing, un-read file returns
  `{error: "read <path> before overwriting it"}`; a file whose mtime changed since the read returns
  `{error: "stale: <path> changed since you read it"}`; a new file writes freely. The guard is
  **real-FS only** — skipped entirely on `Virtual` (nil `mtime`) and when no tracker is passed
  (direct tool construction). Best-effort: mtime-based, so a sub-second external edit may slip past
  the stale check (read-before-write is the primary guard). Clobber-safety within a session only —
  no versioning, locking, or VCS semantics.

These are sandbox refinements as much as tool behavior — see [Sandboxes](sandboxes.md) for the
guard details behind each capability. The `fetch` tool for reading the web lives in
[Web](web.md), gated by its own `:fetch` capability plus a host allow-list.

← Back to the [README](../README.md)
