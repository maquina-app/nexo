## [Unreleased]

## [0.16.1] - 2026-11-27

### Added

- **`Workflow#emit_agent_event(type, payload, extra = {})`**, public. It records one event of
  an agent's prompt the way `run_agent` does: named `agent_<type>`, payload reduced to plain
  data. A workflow that builds and prompts its agents itself (several agent classes in one
  workflow) had to write its own reducer, and `Workflow.usage` could not read the result.
- **`Workflow#cancel_requested?`** is public, for the same kind of workflow:
  `agent.prompt(text, cancel: -> { cancel_requested? })`.

### Fixed

- Tests only: the crash-and-retry test assumed Ruby 3.4's `Hash#inspect`, and the live
  `ContainerRunner` test did not run as the host's user on Linux. Three doc comments in
  `RunStore` had been separated from `claim_for_resume!`.
- Documented that `ContainerRunner` needs `user:` on a Linux host to write to the workspace.

## [0.16.0] - 2026-11-27

Fixes and verification left over from 0.13–0.15; the three changes that were parked for 1.0
(ruby_llm's file tools by default, undeclared tools refused by default, ruby_llm's agent
options on `Nexo::Agent`); more pieces of ruby_llm 2.2 for observing and controlling a run
and for MCP servers that do more than answer a tool call; and the removal of what ruby_llm
now provides, approvals included.

**Upgrading — defaults changed, and code was removed:**

1. **File tools are ruby_llm's, and Nexo's own are gone.** An agent gets `list_files`,
   `read_file`, `search_files`, `write_file` and `edit_file` in place of
   `nexo--tools--read_file`, `nexo--tools--write_file` and `nexo--tools--glob`. Update any
   skill, prompt or event consumer that names the old tools. `file_tools :nexo` raises
   `Nexo::ConfigurationError`. A custom sandbox class needs `#files`.
2. **An MCP server whose tools are named `read_file`, `write_file`… now clashes** with those
   file tools, and building the chat raises `Nexo::ConfigurationError`. Declare
   `file_tools :none` on that agent, or leave the clashing names out of `mcp_allow`.
3. **`Nexo.config.strict_tools` is `true`.** A tool put on the chat outside the `tools` macro
   is refused. Declare it with `tools`, or set `strict_tools = false`.
4. **`context_budget` moved into the `llm` block:** `llm { context_budget per_result: 0.25 }`.
   The macro raises `Nexo::ConfigurationError` saying so.
5. **`Permissions.new(approve_when:)` is `ask_when:`**, and `Permissions.new(decision:)`,
   `#decision`, `#with_decision` and `Agent.new(decision:)` are gone: use `decisions:` (per
   call, since 0.14).
6. **The `:turn_limit_exceeded` loop event is gone.** Rescue `RubyLLM::ToolRoundLimitError`.
7. **A call declined under `:approve`** gets ruby_llm's refusal (`"The user denied the … tool
   call."`) where it got Nexo's `"… not approved"`, and emits no `:tool_call` / `:tool_result`
   event, because the tool is never entered.

Also:

- A custom run store's `claim_for_resume!` must accept `from:` to support `Workflow.retry`,
  and needs `request_cancel!` / `cancel_requested?` / `clear_cancel!` to support cancelling a
  running run.
- `WorkflowRun::STATUSES` gained `"cancelling"` and `"cancelled"`. The column is a string, so
  no migration is needed; update any code that lists statuses.
- The loop's event block now also receives `:usage`, `:tool_progress` and `:fallback`. A block
  that assumes only `:tool_call`, `:tool_result` and `:done` should ignore the rest.
- A custom agent class used with `run_agent` is given `answers:` only when a run has answers,
  and `cancel:` only when its `#prompt` accepts it.
- Nexo's notices are now written to standard error even under `ruby -W0`.

### Removed

- **`Nexo::Tools::ReadFile`, `WriteFile`, `Glob`, `Nexo::ReadTracker` and `Sandbox#mtime`.**
  ruby_llm's file tools over `SandboxFileStore` do the same work, with a read-before-write
  guard that compares content and so works on every sandbox. (0.14 recorded that
  `ReadTracker` had no ruby_llm equivalent; with the file store it has one.)
- **`Permissions` `decision:` / `#decision` / `#with_decision`, `Agent.new(decision:)`** —
  the one-answer-for-every-call form deprecated in 0.14 — **and the `approve_when:` alias**.
- **The `context_budget` macro**, a pass-through to an option the `llm` block already takes.
- **The loop's tool-call count and `:turn_limit_exceeded` event.** ruby_llm's `rounds:` has
  been the cap since 0.13.

### Added

- **A server's prompts.** `Agent#mcp_prompts(:server)` lists them and
  `Agent#mcp_prompt(:server, :name, **arguments)` fills one in; `Agent#prompt` takes it in
  place of a text. In a workflow, `run_agent(->(agent) { agent.mcp_prompt(…) })`.
- **MCP tasks.** `mcp …, tasks: true` declares the MCP tasks extension. A call the server
  answers with a task is polled at the server's interval until it finishes; its status
  messages arrive as `:tool_progress`. After `Nexo.config.mcp_task_timeout` (300 s) the task
  is cancelled and the prompt raises `Nexo::Error`. A task is held in memory: a process that
  dies mid-task runs the call again on retry.
- **Several approvals at once.** `Nexo::ApprovalRequired#pending` and
  `run.state["__approvals_pending__"]` list every call of a response that waits for a
  decision; `resume(id, approvals: {key => true|false})` answers them by key.
- **A host tool declared with ruby_llm's `requires_approval`** is decided from the same
  `decisions`, under the capability `tool`.
- **`llm do ... end` on `Nexo::Agent`.** The block is written in `RubyLLM::Agent`'s own DSL
  (`thinking`, `temperature`, `schema`, `fallbacks`, `compaction`, `caching`, `headers`…) and
  applied to every chat the agent builds, a session's persisted chat included. It is
  evaluated on a private `RubyLLM::Agent` subclass (`Nexo::ModelOptions`), so Nexo re-implements
  none of those options. What Nexo owns is refused inside the block: `model`, `instructions`,
  `tools`, `mcp`, `skills`, `provider_tools`, `file_store`, `code_execution`.
- **`Workflow.retry(run_id)`** runs a `"failed"` or `"interrupted"` run again. Checkpoints the
  run finished before it stopped, and the finished steps of a `checkpoint_all` batch, are not
  repeated. Before this, only a suspended run could be re-entered, so a failed run's
  checkpoints were never used.
- **`file_tools :none`**, for an agent whose files come from an MCP server.
- **`Workflow.cancel(run_id)`.** A waiting run is cancelled at once; a running one is asked to
  stop through the run store and ends `"cancelled"` at its next checkpoint, `run_agent` or
  tool call. Across processes on the ActiveRecord store (new `"cancelling"` and `"cancelled"`
  statuses) and the Disk store. `Agent#prompt(cancel:)` is the same hook for a direct caller.
- **Usage.** The loop emits `:usage` once per prompt with the tokens and cost it added, even
  when the prompt raises; `run_agent` records it and `Nexo::Workflow.usage(run)` totals a run.
- **`:tool_progress` and `:fallback` loop events**, recorded on a run as `agent_tool_progress`
  and `agent_fallback`.
- **Deferred tools:** `tools …, defer: true` and `mcp …, defer: true`, on ruby_llm's tool
  search. A deferred tool is gated like any other.
- **MCP resources:** `mcp …, resources: true` attaches `list_mcp_resources` and
  `read_mcp_resource`, on the MCP permission axis.
- **A tool that asks the person something** — an MCP server's question, or `Tool#ask` — raises
  `Nexo::InputRequired`. `run_agent` suspends on it and `resume(id, answers: {…})` answers it;
  `Agent.new(answers:)` answers up front.
- **Step-up authorization:** an MCP call refused for want of a scope raises
  `Nexo::AuthorizationRequired` with `#scopes`.
- **Encryption for `Nexo::MCP::CredentialStore`.** `new(dir:, key:)` encrypts every file with
  AES-256-GCM, authenticated with the credential's key name. `generate_key` makes a key.
  A file that does not decrypt reads as "not authorized".
- **`Workflow#run_agent(prompt, mcp_owner:)`**, so an agent with an `oauth:` MCP server can be
  driven from a workflow.
- **`readable: :ruby`** on `Sandboxes::Local`, and `Local.ruby_paths`: the running Ruby's
  prefix and gem paths, which a confined shell needs to run a Ruby script.
- **Reconnect on the Apple `container` runtime.** `reconnect: true` with `runtime: :apple`
  no longer raises; the sandbox lists containers as JSON and matches its label exactly.
- A CI job that runs the live container tests against the runner's Docker.

### Changed

- **`:approve` pauses through ruby_llm's approval mechanism.** A gated tool answers
  ruby_llm's `requires_approval?` and its approval resolver from `Permissions`
  (`Nexo::Approvable`), so an undecided call is held before the tool is entered, where it
  used to be an exception raised from inside the tool. The public API is the same
  (`permissions :approve`, `decisions:`, `resume(id, approved:)`, `run.state["__approval__"]`),
  and decisions are still keyed by what the call does, so they work on every run store
  without `acts_as_chat` — the reason 0.14 gave for not doing this. The gate inside each
  tool is unchanged and still refuses an undecided call that reaches it another way.
- **An absolute path inside the sandbox works with the file tools.** ruby_llm takes every
  path as relative, so `/workspace/a.md` was looked up as `workspace/a.md`.
- `Nexo.config.file_tools` defaults to `:core` and `Nexo.config.strict_tools` to `true` (see
  Upgrading).
- A tool name that is not on the chat at all is left to ruby_llm, which answers "There is no
  tool named…"; the backstop refuses only a tool that exists and was never declared.
- A read-only root filesystem is no longer reported as a hardening gap on `:apple`: its
  `--tmpfs` scratch is writable on `container` 1.7.

### Fixed

- **A timed-out command kept running inside a container.** `Sandboxes::Container` ran `exec`
  through `Timeout` and `Open3`, which stopped neither the runtime's client nor the process
  in the container. It now uses `Sandboxes::Subprocess`, and kills every process the timed-out
  exec started.
- **A workflow's event log recorded an MCP tool's result as an object address**
  (`#<RubyLLM::MCP::Result:0x…>`). It now records the result's text and whether the server
  called it an error.
- **`Workflow.reconcile_interrupted!` skipped the Disk run store**, so a CLI killed mid-run
  left its run `"running"` for good.
- **`ContainerRunner#supported?` was always false on `:apple`** (`container version` is not a
  subcommand); it asks `container system status`. Its runs pass `--progress none`.
- Nexo's notices used `Kernel#warn`, which prints nothing under `ruby -W0`.
- **A catch-all `rescue_from StandardError` on a tool swallowed an approval**, turning
  "pause and ask" into an error result. The pause no longer travels as an exception.
- `examples/mcp_filesystem.rb` clashed with the default file tools; it declares
  `file_tools :none`.

### Verified

- **MCP OAuth over real HTTP**, against an authorization server and MCP server on
  `127.0.0.1` (`test/mcp_oauth_roundtrip_test.rb`): discovery, dynamic registration and a
  Client ID Metadata Document, PKCE, bearer requests, refresh, per-owner reuse, a forged
  callback, `deauthorize`. This is what found the event-log and `run_agent` defects above.
- **Apple `container` 1.7.1** on macOS 27: the live sandbox tests, the reconnect smoke test
  and `ContainerRunner`, alongside Docker 29.
- **A crash and a retry across real processes** (`test/workflow_crash_retry_test.rb`): a run
  on the Disk store is killed with SIGKILL after its first checkpoint, and a second process
  sweeps and retries it without repeating that checkpoint.
- A confined shell runs a Ruby script with `readable: :ruby` (macOS, `mxc` 0.4.1).
- **MCP resources, a server's question, a missing scope and deferred tools**, through
  ruby_llm's real MCP client against the same local server (`test/mcp_beyond_tools_test.rb`).
- A gated tool can end the turn with `halt`, and a tool's `progress` reaches the run log.
- **A server's prompts and tasks**, against the same local server.
- **Against a real model** (Ollama, `glm-5.3-flash:cloud`; `test/live_smoke_test.rb`): a
  request falling back to another model with the `:fallback` event; deferred tools found
  through ruby_llm's `tool_search`; manual compaction through Ollama's Responses protocol
  (one message appended, nothing removed); an `:approve` workflow that suspends, resumes and
  writes its file; and a review using the file tools.
- An absolute path in a Docker container (`/workspace/…`) through the file tools.

Not exercised: Anthropic's and OpenAI's own tool search and automatic compaction (no key
for either was available), compaction on a persisted chat, and a sign-in against a
third-party OAuth MCP server.

### Kept on purpose

- **Nexo's skill parser.** ruby_llm's skills attach a `load_skill` tool that reads files
  outside the permission gate, and reject names Nexo accepts. Nexo's skills inject
  instructions only.
- **MCP tools attached with `with_tools`**, not `with_mcp`, so each one is gated.
- **The `:glob` capability** is still accepted in `allow:`. Nothing asks for it any more
  (listing and searching are `:read`); removing it would break every host's allow list.
- **A resume runs the prompt again.** Carrying on a paused, persisted chat with
  `chat.complete` instead is a later step.

### Declined, again

- **`Nexo::Agent < RubyLLM::Agent`.** Read against 2.2.3 once more: that class builds one chat
  when it is created and keeps it, where a Nexo agent builds a chat per prompt; and `model`,
  `mcp`, `skills`, `tools` and `instructions` share a name with a different signature. The
  `llm` block gives the same options by composition, through ruby_llm's public API.

## [0.15.0] - 2026-11-26

Six things taken from ruby_llm 2.2, each behind Nexo's permission gate. Everything new is
opt-in except one default: a cap on tool calls per round.

**Upgrading:** one default changed. A model response may now run at most 20 tool calls;
the rest are answered with an error and the model can ask again. Raise or remove it with
`Nexo.config.tool_calls_per_round`. A custom sandbox class is unaffected unless you turn
on `file_tools :core`, which needs `#files`.

### Added

- **`Nexo.config.tool_calls_per_round`** (default `20`). `max_turns` counts model responses,
  and one response may hold any number of tool calls, so a round was unbounded. Passed to
  ruby_llm as `with_tool_options(calls:)`.
- **`context_budget` macro on `Nexo::Agent`**, a per-agent `Chat#with_context_budget`. It
  bounds what any tool returns as a share of the model's context window. Off unless declared.
- **OAuth for MCP servers.** `mcp ..., oauth: true` (or a Hash of options) hands the server to
  ruby_llm's MCP OAuth. `Agent.new(mcp_owner:)` says whose credentials to use,
  `Agent#mcp_server(name)` exposes the server so a host can drive `authorization_url` /
  `authorize` / `deauthorize`, and `Nexo::AuthorizationRequired` is raised before an
  unauthorized server is used. `Nexo::MCP::CredentialStore` keeps tokens on disk for hosts
  without ActiveRecord (plain JSON, `0600`, not encrypted).
- **`file_tools :core`.** Attaches ruby_llm's `list_files`, `read_file`, `search_files`,
  `write_file` and `edit_file` over the agent's sandbox through the new
  `Nexo::SandboxFileStore`, each wrapped in `Nexo::GatedTool`. Adds editing part of a file,
  searching contents, and a read-before-write guard that works on every sandbox. Nexo's own
  three tools remain the default until 1.0.
- **`Sandbox#files` and `#file_size`** on every sandbox (a container or remote sandbox lists
  through its shell).
- **`Nexo::Sandboxes::ContainerRunner`** answers ruby_llm's sandbox contract with a throwaway,
  hardened container per command. It works as `Sandboxes::Local`'s `isolation:` and as
  `RubyLLM.config.sandbox`.
- `Nexo::GatedTool` takes `detail:`, a callable naming what a call acts on.

### Fixed

- **Container reconnect compared a short id with a full one.** The lookup now asks for the
  full id (`ps -aq --no-trunc`). Found by running the reconnect smoke test against Docker for
  the first time.

### Verified

- The container sandbox and its reconnect path, live against Docker 29 (through OrbStack).
  Both were recorded as unverified since they shipped. Apple `container` parity is still not
  verified.
- The confined local shell on Linux (Bubblewrap), in CI: a write and a read outside the
  workspace and a network connection are refused.
- OAuth is tested against ruby_llm's real MCP class but not against a live authorization
  server.

### Changed

- `Sandboxes::Local#shell` and `ContainerRunner` share `Sandboxes::Subprocess`, the
  kill-on-timeout runner introduced in 0.14.

## [0.14.0] - 2026-11-26

A security release. Three guarantees Nexo documented did not hold and now do, and a tool
you wrote yourself can be gated like Nexo's own.

**Upgrading:** four changes can affect a host.

1. **The local shell no longer inherits your environment.** If a command an agent runs on
   `sandbox :local` relied on an inherited variable, pass it with `env:`.
2. **`resume(approved:)` answers one call.** A workflow whose agent makes several gated calls
   now suspends once per distinct call. A host that drove an agent directly with
   `Agent.new(decision:)` is unaffected.
3. **Under `:read_only`, MCP tools outside `mcp_allow` are no longer attached.** They were
   always denied when called; the model just stops seeing them.
4. **Tools added by overriding `#chat` now warn once.** Move them to the `tools` macro.

### Fixed

- **`Sandboxes::Local#shell` leaked the whole process environment.** The documented narrowing
  to `PATH`/`HOME`/`LANG` never happened: those were added on top of an inherited environment,
  so any secret in the host's `ENV` was readable by a model-run command. The child process now
  gets only the narrowed set plus explicit `env:` entries.
- **A shell timeout did not stop the command.** `Timeout::Error` was raised only after the
  command finished by itself. The command now runs in its own process group, which is killed
  when the timeout fires. `Tools::Shell` returns the timeout to the model as `{error:}` instead
  of failing the run.
- **One approval approved everything after it.** `Workflow.resume(id, approved: true)` handed
  the re-driven agent a single global decision, so every later `:approve`-gated call in that
  prompt ran without asking; the guide said it would suspend again. Answers are now filed per
  call under the reserved `__approvals__` state key, keyed by capability and detail (and a
  digest of the arguments for MCP tools). A call with no answer suspends.
- **`sandbox :local, env: {...}`** dropped `env:` in the Hash form. Every option now reaches
  `Sandboxes::Local`.
- **`Tools::Fetch` failed on hosts whose first address was unreachable.** Only the first
  resolved address was tried, so a host with an IPv6 record failed on a machine with no IPv6
  route. Each vetted address is now tried in turn (up to four), and only on connect errors.

### Added

- **`tools` macro on `Nexo::Agent`** for tools of your own, with an optional `capability:`.
  A tool declared with one is wrapped in the new `Nexo::GatedTool`, so the agent's permissions
  decide every call, and it is left out of the schema when the mode could never allow it.
- **`Nexo.config.strict_tools`.** One `around_tool_call` block catches calls to tools Nexo did
  not attach. Default `false`: the call runs and Nexo warns once per tool. `true` refuses it.
  This becomes the default in 1.0.
- **`isolation: :confined` on `Sandboxes::Local`** runs shell commands in an OS sandbox through
  `ruby_llm`'s sandbox contract (the `mxc` gem, a soft dependency): writes only inside `cwd`,
  no home directory, no network. `readable:` grants extra paths; `isolation:` also accepts an
  `MXC::Sandbox` or any object answering the contract. Verified on macOS; opt-in.
- **`Sandbox#hardening_gaps`** on every sandbox. `Local` reports an unconfined shell.
- **`Permissions#decisions`, `#with_decisions`, `::approval_key`, `#never_allows_mcp?`** and
  `Nexo::ApprovalRequired#key`.
- **Runs execute inside `RubyLLM.workflow`**, so `ruby_llm`'s instrumentation and usage records
  carry the Nexo run id. `checkpoint` and `run_agent` are steps of it. No outcome changes.

### Deprecated

- `Permissions#decision`, `#with_decision` and `Agent.new(decision:)`: one answer for every
  gated call. `Workflow#run_agent` no longer uses them. Use `decisions:`.

### Decided against, for now

Recorded so they are not re-litigated without new facts (all read from ruby_llm 2.2.3):

- **The permission check did not move into `around_tool_call`.** A skipped call can only give
  the model `"The <name> call did not run."`; the block's return value is ignored. Nexo's
  denial messages cannot travel through it, so the hook is the backstop, not the gate.
- **`:approve` was not rebuilt on ruby_llm's tool approvals.** Those are durable only with
  `acts_as_chat`; without ActiveRecord the pending state lives in memory. Nexo's approvals
  work with any run store.
- **`Nexo::Agent` is not a `RubyLLM::Agent` subclass**, and `Session`, `WebSearch`,
  `ReadTracker` and `OutputTruncator` stay: ruby_llm has no plain-Ruby equivalent of them.

## [0.13.0] - 2026-11-26

Nexo now runs on ruby_llm 2.2. MCP comes from ruby_llm itself, skills need no extra gem,
and `max_turns` is a real cap.

### Changed

- **`ruby_llm` is now pinned to the 2.2 line (`~> 2.2.0`, was `~> 1.16`).** Verified against
  2.2.3. ruby_llm 1.x is no longer supported; it ended at 1.16.0 and carries ReDoS
  advisories that are fixed only in 2.0.

  **Upgrading:** this is a breaking release for the host app's Gemfile and for any
  `RubyLLM::Tool` you wrote yourself.

  1. Remove `gem "ruby_llm-mcp"` and `gem "ruby_llm-skills"`. `ruby_llm-mcp` defines the
     same `RubyLLM::MCP` constant as ruby_llm 2.x and cannot be bundled with it; both gems
     pin ruby_llm 1.x. Anything you were getting from them transitively (for example
     `bigdecimal`) must now be declared by you.
  2. In your own tools, rename `param` to `parameter` and `desc:` to `description:`
     (`params do` becomes `parameters do`). ruby_llm 2.0 removed the old names.
  3. A tool wrapper you wrote (for `wrap_mcp_tool`) must accept keywords:
     `def call(**arguments)`. ruby_llm 2.x calls tools as `tool.call(**arguments)`, and the
     schema reader is `parameters_schema`, not `params_schema`.
  4. If you use `Nexo::Session` on ActiveRecord, run ruby_llm's own schema upgrade
     (`rails g ruby_llm:upgrade`, one minor at a time). ruby_llm 2.x keeps tool calls and
     the model registry in its own `ruby_llm_*` tables; the host owns only `Chat` and
     `Message`.
  5. Read ruby_llm's [upgrade guide](https://rubyllm.com/upgrading/) for everything outside
     Nexo — notably that OpenAI now defaults to the Responses API.

- **`max_turns` is a hard cap.** `Agent#prompt`, `Session#prompt` and
  `Workflow#run_agent` pass it to ruby_llm as `with_tool_options(rounds:)`. When a prompt
  uses up its tool rounds, `RubyLLM::ToolRoundLimitError` is raised instead of the model
  being asked again; inside a workflow that fails the run. It was telemetry only before.

  **Upgrading:** a run that used to pass `max_turns` and keep going now stops. Raise the
  number for runs that legitimately need more rounds, or pass `max_turns: nil` to run
  uncapped. The `:turn_limit_exceeded` event is still emitted, once per prompt.

- **MCP uses ruby_llm's built-in client.** The `mcp` macro, `mcp_allow`, the fail-closed
  gate, `wrap_mcp_tool` and `Nexo::MCP.build` are unchanged for callers. Three behaviours
  differ, all inherited from ruby_llm:
  - a callable `token:` is read again for **every request**, so a rotated token no longer
    needs `agent.close` and a reconnect;
  - a `:stdio` server starts with a short, safe environment — pass what it needs with
    `env:`;
  - a `:stdio` server's stderr is your process's stderr.

  An unknown transport or a `:stdio` server with no `command:` now raises
  `Nexo::ConfigurationError` when the server is built.

- **Skills are read by Nexo itself** (`Nexo::Skills::Skill`). `skills`, `Nexo::Skills.find`
  and `Nexo::Skills.materialize` are unchanged. A `SKILL.md` without YAML front matter now
  raises `Nexo::Error` naming the file. ruby_llm's own skills are not used: they reject
  underscore names (`email_triage`) and work through a `load_skill` tool, where Nexo's rule
  is that a skill adds instructions and nothing else.

- **Workflow events store tool arguments string-keyed** in both run stores. ruby_llm 2.x
  hands them over with Symbol keys; the Memory store would otherwise have disagreed with
  the ActiveRecord one.

### Removed

- **`Nexo::Loops::AgentSDK`**, with `Agent#permission_mode`, `Agent#allowed_tools`,
  `Agent::ALLOWED_TOOLS` and `Agent::PERMISSION_MODE_MAP`. The `ruby_llm-agent_sdk` gem it
  wrapped was never published, so this path never ran against real code. Its one purpose,
  a hard turn cap, is now `max_turns` on the default loop. `Nexo::Loop` remains as the seam
  for a backend of your own.
- **`Nexo::MCP.load!` and `Nexo::Skills.load!`.** There is no optional gem left to load.
- The `ruby_llm-test`, `ruby_llm-skills` and `ruby_llm-mcp` development dependencies. The
  suite scripts model replies with ruby_llm's own `RubyLLM::TestHelper`.

### Added

- `test/real_loop_test.rb` drives ruby_llm's real conversation loop with scripted replies
  and proves, end to end: a `:read_only` agent cannot reach the write tool, the MCP gate
  denies a tool before it runs, `max_turns` stops a runaway loop, and an `:approve` gate
  suspends a workflow and resumes it.
- `mcp` accepts `env:` and `directory:` for `:stdio` servers, and `command:` as an argv
  Array.

## [0.12.0] - 2026-09-12

The gem now says exactly which ruby_llm it supports, and its API docs are written in Markdown.

### Changed

- **`ruby_llm` is now pinned to the 1.16 line (`~> 1.16`, was `>= 1.16`).** The supported
  version is 1.16.0 — every composed API was verified against it. The upcoming ruby_llm 2.0
  is not supported yet, and the pessimistic constraint keeps it from being resolved in.
- **API documentation is written in Markdown.** RDoc now runs with `markup: markdown`
  (`.rdoc_options` + the `rake doc` task), and every doc comment under `lib/` was converted
  from RDoc markup — backtick code spans, `##` headings, fenced code samples. Guides link the
  `examples/` files by GitHub URL so the links work on rubydoc.info as well as on GitHub.

## [0.11.0] - 2026-08-20

An agent's tool schema now tells the truth about what it may do.

### Changed

- **An agent no longer advertises a tool its permission mode can never authorize.**
  Tool attach was gated on the sandbox (`Sandbox#supports?`) but not on the gate, so a
  `:read_only` agent — the default — put `WriteFile` and `Shell` in its schema on every
  turn even though `#authorize!` was guaranteed to deny them. The same held for `Fetch`
  and `WebSearch`, which were gated on `fetch_allow` / `search_backend` being declared
  but not on the capability being permitted. Models do try these tools, and each attempt
  costs a full round trip.

  `Agent#chat`, `#apply_fetch` and `#apply_search` now also consult
  `Permissions#never_allows?`. Only `:read_only` is decidable ahead of time; `:auto`,
  `:ask` and `:approve` decide per call and still attach — `:approve` in particular must
  reach the gate so it can raise `ApprovalRequired` and suspend the run.

  This is a cost and description-accuracy measure, **not** a security change:
  `#authorize!` remains the boundary and still denies at call time.

  **Upgrading:** an agent that is supposed to write, shell out, fetch or search needs the
  capability in `allow:` (or a non-`:read_only` mode). If it does not have it today the
  tool was already failing on every call — the tool now disappears from the schema instead
  of erroring. Note that `fetch_allow` scopes hosts and `search_backend` names a backend;
  neither is a capability grant.

### Added

- `Nexo::Permissions#never_allows?(capability)` — true when a capability can never be
  authorized for this gate, for any call. Derived from the new `Permissions::PRIVILEGED`
  constant, which `#authorize!` also reads, so the predicate cannot drift from the gate.

## [0.10.0] - 2026-08-20

Durable workflows without a database.

### Added

- `Nexo.config.run_store` — set a store instance and it wins over the automatic
  choice (ActiveRecord under Rails, in-memory otherwise).
- `Nexo::RunStore::Disk` — a file-backed store, one JSON document per run under a
  directory, written atomically (temp file + rename). This is what makes `checkpoint`,
  `suspend!`/`resume` and a run's recorded artifacts available to a host with no
  database: all of them read state back from the store, and the in-memory one dies
  with the process. `Disk::Run` subclasses `Memory::Run`, so the run shape and every
  read helper are shared and host code behaves identically on either store. `#all`
  lists the directory newest-first. `claim_for_resume!` re-reads from disk so a stale
  copy cannot win a claim; it is atomic within a process, not across machines.

## [0.9.0] - 2026-08-20

Skills and sandboxes learn to talk about the environment, and an agent's output finally
survives its sandbox. A skill can state what it needs (`compatibility:`, which was parsed
and then dropped), a sandbox can report what it has (`Sandbox#environment`), and an agent
can require the two to match before the first turn. Separately, an agent's declared output
is now collected before teardown — a workflow releases its sandbox on **every** terminal
path, `suspended` included, so pausing for a human approval used to destroy everything the
run had produced on a container tier while the identical code on `:local` kept it. Along
the way `Workflow#artifact` turned out never to have worked outside `:virtual`. Verified
end to end against Docker 29.4.0 and Apple `container` 1.2.2.

### Added

- **A skill's `compatibility:` frontmatter now reaches the model.** `apply_instructions`
  passed only `skill.content`, so `compatibility:` — the Agent Skills spec's own field for
  stating what a skill needs in order to run — was parsed and then dropped. It is now
  appended to the skill's body as a labelled `Compatibility: …` line. Skills that do not
  set it contribute exactly their body, byte for byte, as before. `license:` and
  `allowed-tools:` stay unsurfaced on purpose: the first is prompt noise, and the second
  would be a second source of truth about what an agent may do, competing with
  `Nexo::Permissions`.
- **`Sandbox#environment` — a sandbox can report what it actually provides.** One POSIX
  `sh` round trip returns the commands on `PATH` (with versions) and the locale, memoized
  for the sandbox's lifetime and extensible per call. It never raises: a shell-less
  sandbox and a probe that could not run both answer empty, carrying the reason under
  `:error`, because "there is no ruby" and "I never got to look" have different fixes.
  Deliberately coarse — commands and locale, never packages.
- **`requires` on an agent, checked before the first turn.**
  `requires commands: {"ruby" => ">= 3.1"}, locale: :utf8` raises `Nexo::EnvironmentError`
  listing every unmet requirement at once, instead of letting the run reach
  `sh: ruby: not found` several turns in. Declaring nothing is the default and costs no
  probe. Motivating case: a container has **no locale even when it has a full toolchain**,
  under which Ruby's default external encoding is `US-ASCII` and a bare `File.read` on a
  UTF-8 file raises — measured on Docker and Apple `container` alike.
- **`Nexo::EnvironmentError`** (a `ConfigurationError`) for the above: the fix is in the
  image or the sandbox wiring rather than in the Ruby.
- **`produces` on an agent, collected into the run before the sandbox dies.** An agent
  declares the artifacts it writes (`produces "dashboard.html", "out/*.json"` — many per
  agent, globs allowed) and `run_agent` copies them out and records them on the run the
  moment the agent finishes, **including when it suspended for approval or raised**. A
  workflow releases its sandbox on every terminal path and `Container#close` is `rm -f`,
  so before this a durable-approval pause destroyed everything the run had produced, while
  the identical code on `:local` kept it. Verified end to end through real ephemeral
  containers on Docker 29.4.0 and Apple `container` 1.2.2.
- **`Workflow#artifact(name, path:)`** — a verbatim third mode. `from:` renders ERB and is
  documented as trusted templates only, which agent output can never be; `path:` copies
  sandbox bytes with no rendering. Non-UTF-8 bytes are Base64-wrapped so they survive a
  JSON column; `Workflow.artifact_body(art)` decodes.
- **`Workflow#restore_artifacts`** — materializes recorded artifacts back into the run's
  sandbox, so a later stage can read what an earlier one produced even on an ephemeral
  tier. The missing counterpart to `Skills.materialize`.

### Fixed

- **`Workflow#artifact` wrote to an absolute `/artifacts/<name>`, which every real sandbox
  rejects.** `Local#absolute` and `Container#guard_path` both raise
  `SecurityError: path escapes sandbox`, so the feature only ever worked on `:virtual`,
  whose in-memory paths are unguarded. The copy is now workspace-relative
  (`artifacts/<name>`) and resolves under the root on all four tiers.

### Changed

- **The in-sandbox copy of an artifact moved from `/artifacts/<name>` to
  `artifacts/<name>`**, relative to the sandbox root. Visible only to `:virtual` users —
  the only ones for whom `#artifact` worked at all — and only if they read the copy back
  by absolute path. The recorded `run.artifacts` data is unchanged.

## [0.8.1] - 2026-08-19

Sandbox tiers made honest and skill resources made usable. A skill's `scripts/` and
`assets/` live outside every sandbox, so an agent could not reach them; `Skills.materialize`
stages them in through the sandbox's own `#write`, which is the one route that works on
`:local`, `:container` and `:remote` alike. Along the way the `:apple` runtime turned out
to be unable to start a container at all, and `Container#write` was reporting success
while writing nothing. Verified end to end against Apple `container` 1.2.2 and Docker
29.4.0.

### Fixed

- **`Container#write` creates parent directories and raises on failure.** It ran
  `sh -c 'cat > "$0"'` and discarded the exit status, so writing a nested path into a
  fresh workspace failed with `Directory nonexistent` while reporting success to the
  caller. `Local#write` has always done `mkdir_p` and raised; the two now match. Staging
  anything with a directory in its path — a skill's `scripts/render.rb` — silently
  produced nothing on a container before this.
- **The `:apple` runtime can start a container.** `#run_argv` passed
  `--security-opt no-new-privileges` and `--pids-limit`, which Apple's `container` CLI
  rejects with `Unknown option`, so `runtime: :apple` failed before any tool ran. Both
  come from defaults, so no configuration avoided it. They are now omitted for `:apple`
  and reported through `#hardening_gaps`.

### Added

- **`Nexo::Skills.materialize(name, into:)`** — copies a skill's `scripts/`, `assets/`
  and `references/` into a sandbox so an agent can actually reach them, through the
  sandbox's own `#write`. Returns **sandbox-relative** paths so callers can build a
  command without knowing which tier they are on. `kinds:` narrows the copy;
  `overwrite: false` skips files already present, for images that bake the skill in.
- **`Container#hardening_gaps`** — hardening the caller asked for that the runtime
  cannot honor, as human-readable strings; empty on `:docker`. Running with weaker
  isolation than requested is now visible rather than silent. It also reports that
  Apple's `--tmpfs` is not writable under `--read-only`, which makes the default
  `readonly_rootfs: true` leave an `:apple` sandbox with no writable workspace.
- **`Agent#wrap_mcp_tool(tool)`** — a hook called once per MCP tool, after gating and
  before attachment, for decorating every MCP tool an agent gets (capping an oversized
  reply, timings, redaction). Default returns the tool unchanged; previously the only
  way in was overriding the private `#apply_mcp`. Gating happens underneath, so a
  wrapper cannot widen what the agent may do.
- **`Nexo.config.tool_concurrency`** — surfaces RubyLLM's concurrent execution of
  multiple tool calls from one assistant turn (`:fibers` / `:threads` / `false`).
  Defaults to `nil`, leaving RubyLLM's own setting alone, so behaviour is unchanged
  until you opt in. Applied after every tool is attached, since each `with_tools`
  resets it.
- **`Sandboxes::Remote#instructions`**, with an optional `instructions:` on the
  constructor. `Local` and `Container` describe their environment to the agent;
  `Remote` returned `nil`, leaving the tier most likely to surprise a tool-caller the
  one it knew least about.

### Changed

- **`max_turns` is now counted and reported** on `Loops::RubyLLM` instead of being
  accepted and ignored. It still cannot halt a run — ruby_llm executes the whole tool
  loop inside `Chat#ask` and its callbacks are observation-only — but exceeding the
  budget now emits `:turn_limit_exceeded` with `{turns:, max_turns:}`, once per prompt.
  Previously the parameter read as a safety bound it has never been.

### Documentation

- **`docs/skills.md`: bundled files are not reachable until staged.** The docs stated
  that a skill's `scripts/`/`references/` are reached through Nexo's sandbox-backed
  tools. They are not — a skill lives under `skills_path`, outside every sandbox, and
  nothing bridged the two. Now documents `Skills.materialize`, the relative-path rule,
  the ambient-environment pitfall, and the writable-space tradeoff.
- **Apple `container` parity table filled from live runs**, replacing the previous
  all-`unverified` placeholder. Records that `--network none` *does* work on Apple,
  that `ps -aqf` does not exist there (Apple has `list`), and the
  `--tmpfs`-under-`--read-only` divergence.
- **`docs/sandboxes.md`: path confinement on `:remote` is the client's job.** `Local`
  and `Container` raise `SecurityError` on escape; `Remote` passes paths through
  untouched. Deliberate, but it moves a guarantee callers may rely on.
- `docs/mcp.md` documents `wrap_mcp_tool`; `docs/concurrency.md` documents
  `tool_concurrency` and that tools must be concurrency-safe before enabling it;
  `docs/loops.md` documents what `max_turns` does and does not do.

## [0.8.0] - 2026-07-16

Durability enhancements for workflows: a suspended run can now wake itself on a
timer, and independent checkpoints run concurrently, each persisting as it
completes. Both build on the existing ActiveJob and `Nexo.concurrent` seams — no
schema, run-status, or store change.

### Added

- **Scheduled enqueue/resume.** `Workflow.run_later` and `Workflow.resume_later`
  accept `wait:` (a duration) or `wait_until:` (an absolute time), forwarded to the
  installed ActiveJob's own `.set(...)` scheduler — so a suspended run can wake
  itself on a timer and an initial enqueue can be deferred, without Nexo adding a
  scheduler. Passing both raises `ArgumentError`; with neither the enqueue is
  unchanged. Status stays `"queued"`/`"suspended"` (no new status). No retry
  semantics are added.
- **Parallel checkpoints.** `Workflow#checkpoint_all(name => callable, …)` runs
  independent checkpoints concurrently through the existing `Nexo.concurrent`
  driver, persisting **each step as it completes** so a resume after a partial
  failure re-runs only the still-missing steps. Each newly-completed step emits a
  `"checkpoint"`-typed event (name-only) on the existing `nexo.workflow.event`
  seam. Reuses `state`/`save_state!` — no schema, run-status, or store change.

## [0.7.0] - 2026-07-10

The harness fills out: MCP data sources, a web-content capability, durable
workflows (suspend/checkpoint/resume) with an approval bridge, continuing agent
sessions, a container sandbox, Rails runtime primitives, and a documentation
restructure — followed by a security-and-lifecycle hardening pass over the whole
Sandbox + Permissions seam.

### Added

- **MCP data sources.** `Agent.mcp` attaches Model Context Protocol servers
  (stdio/SSE/HTTP) via `ruby_llm-mcp` (soft, optional dependency). Every MCP tool
  call passes a second gate — `Permissions#authorize_mcp!` — scoped by the
  `mcp_allow` exact-match allow-list (default `[]`, so `:read_only` fails closed).
  `MCP::GatedTool` is a plain delegating wrapper; teardown is `Agent#close`.
- **MCP over HTTP with an OAuth token provider.** `MCP.build(token:)` accepts a
  static string or a callable and injects `Authorization: Bearer …` into the
  HTTP-family transports. A rotated token is resolved once per client build, so
  rotation needs `Agent#close` + a fresh prompt (documented reconnect caveat).
- **Web-content capability (`:fetch`).** `Nexo::Tools::Fetch` (stdlib `net/http`
  GET) is a two-lock capability: the `:fetch` permission (default-denied under
  `:read_only`) plus a host in the subdomain-aware `fetch_allow` list. An SSRF
  guard resolves the host once, pins the vetted IP, and denies loopback/private/
  link-local/CGNAT/unspecified ranges. Responses are byte-capped.
- **Web search capability (`:search`).** `Nexo::Tools::WebSearch` with an
  injected backend (`search_backend`), gated like `:fetch`.
- **Input staging + named artifacts.** `Workflow#stage` writes files into the
  run's sandbox before work begins; `Workflow#artifact` records named outputs
  (`content:` or a trusted ERB `from:` template) on the run, persisted immediately.
  Both reuse the sandbox + WorkflowRun seams; a data-only workflow builds nothing.
- **Workflow → agent glue.** `Workflow#run_agent(prompt, max_turns:)` runs the
  declared `agent` inside the run's shared sandbox and forwards every loop event
  through `emit`.
- **Durable workflows.** `Workflow#suspend!`, `#checkpoint`, and `Workflow.resume`
  add a `"suspended"` status and a JSON `state` column: a workflow can pause for
  input, persist completed checkpoints, and resume (sync or via `resume_later`)
  without re-running checkpointed work. `resume` atomically claims a suspended run
  (no double execution); checkpoint values are JSON-normalized for Memory/AR parity.
- **Durable approval bridge.** Under `permissions :approve`, an undecided
  sensitive tool call raises `ApprovalRequired`, which `run_agent` records under a
  reserved `__approval__` state key and turns into a `suspend!`; `resume(approved:)`
  threads the human decision back into the agent's permissions.
- **Continuing agent sessions.** `Nexo::Session` persists a chat across prompts
  via ruby_llm's `acts_as_chat` (host-owned schema), with idempotent instruction
  re-application on every resume and once-only observability wiring.
- **Container sandbox.** `Sandboxes::Container` runs an agent's tools inside a
  throwaway, hardened OCI container via the `docker` (default) or Apple `container`
  CLI — no vendor gem, argv arrays only (no shell-string interpolation). Ephemeral
  by default; opt-in `reconnect: true` reattaches by an exact identity label.
- **Rails runtime primitives.** `Nexo::WorkflowJob` (ActiveJob), Turbo mirroring,
  and `ActiveSupport::Notifications` (`nexo.workflow.status` / `nexo.workflow.event`)
  — all Rails-optional and guarded, no-ops when their dependency is absent.
- **Unified sandbox resolver.** `Sandboxes.resolve` is the single place a sandbox
  declaration (symbol / Hash / pre-built instance) becomes a concrete `Sandbox`.
- **`provider` / `assume_model_exists` agent macros** for non-registry models
  (e.g. Ollama), now documented in the getting-started guide.
- **Documentation restructure.** The README is a slim index; thirteen topic guides
  live under `docs/`, and `rake doc` / `rake doc:coverage` (a 100%-or-fail gate)
  render and enforce RDoc coverage.

### Security

- **MCP gate no longer fails open under `:approve`.** `authorize_mcp!` gained an
  `:approve` branch and a fail-closed `else raise Denied` backstop, so no mode
  falls through ungated.
- **Closed shell/command injection in `Container#glob` and `Remote#glob`.** The
  model-supplied pattern is passed as a positional argument, never interpolated
  into a command line — a `:read_only` agent can no longer reach command execution
  through the always-allowed `:glob` capability.
- **`Local` sandbox hardening.** `glob` guards the pattern against escapes and
  filters symlinked matches; `read`/`write` resolve symlinks via `realpath` so a
  symlink inside `cwd` pointing outside it no longer escapes the sandbox.
- **Fetch SSRF hardened.** Resolve-once IP pinning removes the DNS-rebinding
  window; the deny set adds `0.0.0.0/8`, CGNAT `100.64.0.0/10`, and the IPv6
  unspecified address.

### Fixed

- **Sandbox lifecycle — no container leak.** `Agent#close` now closes the sandbox
  it owns; `Workflow.execute` releases the run's sandbox on every terminal path.
  A borrowed sandbox (injected via `sandbox:`, e.g. `run_agent`) is left to its
  owner, so multiple `run_agent` calls no longer tear down a shared container.
- **Workflow lifecycle correctness.** A non-`StandardError` (path-escape
  `SecurityError`, shell-less `NotImplementedError`) now marks a run `"failed"`
  instead of stranding it `"running"`; `resume` claims the run atomically; a
  non-approval resume is no longer coerced into a silent denial; reserved
  `__suspend__` / `__approval__` state is cleared on a successful resume; status
  notifications fire for `queued`/`interrupted`; `resume` honors the original
  `buffer_events`.
- **Ambiguous workflow payloads raise.** `run` / `run_later` reject a positional
  payload combined with leftover keywords instead of silently dropping keys.
- **Agent config is inherited.** Subclassing a configured agent copies its macros
  instead of reverting to defaults.
- **Session/loop fixes.** The base `Loop#run` contract includes `chat:`;
  `Loops::AgentSDK` rejects a session chat with a clear error and emits the
  terminal `:done` event; durable-session instruction application collapses to one
  copy per resume even without an `instructions` macro; the Memory session path
  adopts the agent owning the live chat so `close`/`prompt` hit live resources.
- **Miscellaneous.** Memory `RunStore` is mutex-guarded and mirrors the AR read
  helpers; `engine.rb` is Zeitwerk-ignored; `Agent#close` is exception-safe per
  client; `skills`/`mcp_allow`/`fetch_allow` accumulate (deduped) like `mcp`;
  `ReadFile` caps its output; `WebSearch` and `stage` tolerate string- or
  symbol-keyed input; dead `save!` and `turns`-counter code removed.

## [0.6.0] - 2026-07-01

### Added

- **Opt-in fiber concurrency (`async`).** `Nexo.concurrent(max_in_flight:) { |c| c.add { … } }`
  runs many agent/workflow calls inside one `async` reactor, bounded by an
  `Async::Semaphore` and coordinated by an `Async::Barrier`. Results come back in
  **submission order**; the first task to raise is re-raised (errors are never
  swallowed) and the remaining in-flight tasks are stopped. `max_in_flight`
  (default `Nexo.config.max_in_flight`, i.e. `8`) keeps fan-out under provider
  rate limits — the reason to prefer it over a hand-rolled `Async {}`.
- **`async` is a SOFT/optional dependency** — lazily required only when a
  concurrency feature is used. `require "nexo"` with `async` absent does not
  raise; using `Nexo.concurrent` (or the `:async` sandbox offload) without it
  raises `Nexo::MissingDependencyError` with install guidance
  (`gem "async", "~> 2.0"`).
- **`Nexo::Configuration` gains three settings:** `concurrency`
  (`:threaded` default | `:async`), `max_in_flight` (`8`), and
  `buffer_workflow_events` (`false`).
- **`Sandboxes::Local` async offload.** `read`/`write`/`glob`/`shell` route
  through a private `#offload`; when `Nexo.config.concurrency == :async` the
  blocking file/subprocess I/O runs on a worker thread so it doesn't stall the
  reactor, otherwise it runs inline (byte-for-byte the previous behavior, zero
  overhead). The path-escape `SecurityError` guard, narrowed ENV, and
  `Timeout`-wrapped `Open3.capture3` are all preserved unchanged.
- **`Workflow.run(payload, buffer_events:)` buffered emit.** With
  `buffer_events: true` (default `Nexo.config.buffer_workflow_events`) events are
  buffered in memory and flushed to the store exactly once (in `run`'s `ensure`,
  so they persist on success and failure), avoiding a blocking per-event DB write
  under a reactor. The default (unbuffered) path is unchanged from 0.4.0.

### Notes

- `Loops::RubyLLM` needs **no changes** to run inside a reactor — `ruby_llm`'s
  Faraday `net/http` adapter already yields on socket I/O under Ruby's fiber
  scheduler. A regression test proves a prompt driven from inside `Async {}`
  returns unchanged.
- `Async::WorkerPool` is not present in the installed `async` (2.x), so the
  offload primitive is `Thread.new(&block).value` (re-raises block exceptions in
  the caller).

### Changed

- Raised minimum Ruby to 3.3; `Nexo.generate_run_id` now uses
  `SecureRandom.uuid_v7` unconditionally (dropped the 3.2 UUID v4 fallback).

## [0.5.0] - 2026-06-29

### Added

- **Pluggable loop backends.** `Nexo::Loop` is the new engine seam:
  `#run(agent:, prompt:, max_turns:, &on_event)`. Swap the loop by constructor
  injection (`loop:`) without changing the agent class.
- `Nexo::Loops::RubyLLM` (DEFAULT, provider-neutral) — the Spec 1 `Agent#prompt`
  loop logic extracted verbatim. It runs on any `ruby_llm` model and contains no
  vendor code. Wires turn-count *observability* through `RubyLLM::Chat`'s
  `before_tool_call`/`after_tool_result` callbacks (guarded by `respond_to?`),
  forwarding `:tool_call`/`:tool_result`/`:done` to an optional `on_event` block.
- `Nexo::Loops::AgentSDK` (opt-in, Anthropic-oriented) — wraps
  `RubyLLM::AgentSDK.query` for native `max_turns`, permission modes, and the
  SDK's built-in tools. `ruby_llm-agent_sdk` is a SOFT/optional dependency,
  required lazily; a clear `Nexo::MissingDependencyError` is raised when it's
  absent. Not a dependency of this release (its `.query` signature is
  verified-on-install).
- `Nexo::Sandboxes::Remote` — run an agent's tools inside a remote container by
  injecting any client satisfying the four-method contract (`read`/`write`/
  `exec`/`close`). Contains zero vendor code; switching providers is swapping the
  injected object. Vendor SDKs are adapted with a tiny documented shim.
- `Agent` gains a `loop:` option (default `Loops::RubyLLM.new`); `#prompt`
  delegates to it. New readers `#permission_mode` (Nexo→AgentSDK mode mapping:
  `:read_only`→`:default`, `:auto`→`:bypass_permissions`, `:ask`→`:default`) and
  `#allowed_tools` support the AgentSDK backend. `Permissions#mode` is now
  readable.

### Documented

- README: the loop/sandbox matrix, the two-configurations / same-agent example,
  the Remote shim pattern, the Nexo→AgentSDK permission mapping, and the turn-cap
  caveat (`Loops::RubyLLM` has no proven hard turn cap — observability only).

## [0.4.0] - 2026-06-29

### Added

- **Skills.** Drop a `SKILL.md` package into `app/skills/<name>/` and attach it
  to an agent with a single `skills :name` class macro — Nexo composes the
  existing `ruby_llm-skills` gem to load the skill's instructions, with zero
  loader setup. Skills guide *reasoning*; the sandbox-backed tools from Spec 1
  still perform *execution*.
- `Nexo::Skills.load!` lazily requires `ruby_llm-skills` (a SOFT/optional runtime
  dependency) and raises `Nexo::MissingDependencyError` with install guidance when
  it is absent; `require "nexo"` without the gem still loads cleanly.
- `Nexo::Skills.find(name)` resolves a skill from `Nexo.config.skills_path`
  (default `app/skills` under Rails), raising `Nexo::Error` that names the missing
  `SKILL.md` path when not found.
- `Nexo::Agent.skills(*names)` class macro; `#chat` layers each declared skill's
  instructions on top of the agent's own, in declaration order, after the
  sandbox-backed tools.
- A `nexo:skill NAME` generator scaffolding `app/skills/NAME/SKILL.md` (valid
  Agent Skills frontmatter) plus a kept `references/` directory.

### Safety

- Skill packages contribute **instructions only**: a loaded skill ships no
  independent tools, and Nexo deliberately does not attach `ruby_llm-skills`'
  progressive-disclosure tool (which reads files outside the sandbox). A skill's
  `references/`/`scripts/` files are reached through Nexo's own permission-gated,
  sandbox-backed tools, so attaching a skill never widens what an agent can do.

## [0.3.0] - 2026-06-29

### Added

- **WorkflowRun lifecycle primitive.** Subclass `Nexo::Workflow`, implement
  `#call(payload)`, and run it with `MyWorkflow.run(payload)` to get back a
  persisted run record carrying a UUID v7 runId, `status`, `payload`, `result`,
  `error`, and an ordered, inspectable event log.
- `#emit(type, data)` appends ordered events (persisted incrementally) and
  `Nexo::Workflow.logs(run_id)` / the `nexo:logs[run_id]` rake task inspect them.
- A storage seam `Nexo::RunStore` with two interchangeable backends: an
  in-memory store (plain Ruby, offline) and an ActiveRecord store (Rails),
  selected automatically by `Nexo::RunStore.default`.
- `Nexo::WorkflowRun` ActiveRecord model and a `nexo:workflows` generator that
  installs a portable (`json` columns, UUID string primary key) migration.
- `Nexo.generate_run_id` (time-ordered UUID v7).
- A guarded `Nexo::Engine` wiring the generator, rake task, and model into a
  host Rails app; the core still runs in plain Ruby with no Rails loaded.

## [0.1.0] - 2026-06-21

- Initial release
