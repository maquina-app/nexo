## [Unreleased]

## [0.9.1] - 2026-08-20

A fix for `requires`, which in 0.9.0 could only see the sandbox probe's default
shortlist.

### Fixed

- `requires` now probes for the command names the agent actually declared. In 0.9.0
  `Agent#verify_environment!` called `Sandbox#environment` with its default shortlist
  (`ruby`, `python3`, `node`, `sh`), so any other declared name — a custom binary, or the
  absolute interpreter path you pin precisely because the sandbox shell's `PATH` is narrow
  — was never looked for and always reported as `no <name> on PATH`. Declarations drawn
  from the shortlist were unaffected.

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
