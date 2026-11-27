# Sandboxes
The sandbox is *where* an agent's tools act — pick in-memory Virtual, host-backed Local, a throwaway Container, or a Remote you inject.

Two seams compose the execution environment. The **sandbox** is *where* tools act; the
**permission mode** is *what* they may do. A denied capability returns `{ error: ... }`
and the agent loop continues — it does not raise. A path that escapes the workspace raises
`SecurityError`; an agent built with no resolvable model raises `Nexo::ConfigurationError`.

|                          | `:read` | `:glob` | `:write`            | `:shell`                          | `:fetch`   | `:search`  |
| ------------------------ | ------- | ------- | ------------------- | --------------------------------- | ---------- | ---------- |
| `:read_only` (default)   | ✅      | ✅      | ❌ `{error}`        | ❌ `{error}`                      | ❌ `{error}` | ❌ `{error}` |
| `:auto`                  | ✅      | ✅      | ✅                  | ✅                                | ✅         | ✅         |
| `:ask`                   | ✅      | ✅      | per `on_ask`        | per `on_ask`                      | per `on_ask` | per `on_ask` |
| `:approve`               | ✅      | ✅      | per call            | per call                          | per call   | per call   |
| `Virtual` sandbox        | ✅      | ✅      | ✅ (in-memory)      | ❌ `NotImplementedError`→`{error}` | ✅ †       | ✅ †       |
| `Local` sandbox          | ✅ (guarded) | ✅ | ✅ (guarded)        | ✅ (narrowed ENV, unconfined ⚠)   | ✅ †       | ✅ †       |
| `Container` sandbox      | ✅ (guarded) | ✅ | ✅ (guarded, scratch) | ✅ (in container)               | ✅ †       | ✅ †       |

`:read`/`:glob` are auto-allowed under **every** mode (they sit in the default
`allow` list), so `:ask`/`:approve` never prompt for them — only
`:write`/`:shell`/`:fetch`/`:search` reach the gate. **†** `:fetch` and `:search`
run in the **host process** (stdlib `net/http` / a host-injected backend), so **no
sandbox constrains them** — not even a `--network none` container. They are bounded
only by the capability gate above plus `fetch_allow` / the injected backend.

- **`Virtual`** (default) — in-memory, zero host access. `#shell` raises
  `NotImplementedError` on purpose: in-memory means no command execution. That is the
  safety property, not a gap.
- **`Local`** — host filesystem + shell, for trusted dev/CI. Every file path is expanded
  against `cwd` and must stay inside it (else `SecurityError`). The shell sees only `PATH`,
  `HOME`, `LANG` (plus explicit `env:` additions), and a command that outlives its timeout is
  killed with everything it started. ⚠ The path guard does not cover what a shell command
  touches: see [Confining the local shell](#confining-the-local-shell).
- **`Container`** — run the tools inside a throwaway local container via the `docker`
  (default) or Apple `container` CLI. Shell-out only, no client gem. **Hardened by default**
  (no network, dropped caps, read-only rootfs + ephemeral scratch, read-only host binds);
  every hardening is an explicit opt-out. See [Container sandbox](#container-sandbox--docker--apple-container) below.
- **`Remote`** — run the tools inside a remote container (E2B / Daytona / Modal / Docker /
  your own) by injecting a client. Escalating to `:remote` is always an explicit choice in
  your code — the default stays `:virtual`.

## Confining the local shell

On `:local`, `read`/`write`/`glob` are guarded to `cwd`. A shell command is not: it is a host
process that can read and write wherever your user can, and reach the network. `#hardening_gaps`
says so, so a host can show it before trusting the sandbox with a model:

```ruby
Nexo::Sandboxes::Local.new(cwd: dir).hardening_gaps
# => ["shell commands are not confined: they can read and write outside /path and reach the network …"]
```

`isolation: :confined` runs every command inside an OS sandbox — Seatbelt on macOS, Bubblewrap
on Linux — through `ruby_llm`'s sandbox contract. A confined command can write only inside
`cwd`, cannot read your home directory, and has no network:

```ruby
# Gemfile
gem "mxc"   # a soft dependency: Nexo loads it only for a confined shell

class Builder < Nexo::Agent
  sandbox :local, isolation: :confined, readable: :ruby
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])
end
```

Things to know:

- **A confined command cannot read outside `cwd` either.** That includes a Ruby, Node or Python
  installed under your home directory: `ruby` starts but cannot load its gems. Grant the
  toolchain with `readable:`. Tools that link Homebrew libraries need those paths too.
- **`readable: :ruby` grants the Ruby this process runs on** (0.16): the interpreter's prefix
  and every gem path, from `Nexo::Sandboxes::Local.ruby_paths`. It can be mixed with paths of
  your own — `readable: [:ruby, "/opt/homebrew/opt/libyaml"]`. For a different interpreter
  than the running one, list its install directory.
- **It never falls back.** If the sandbox cannot run on the machine, the first `shell` raises
  `Nexo::ConfigurationError` with the reason. A missing `mxc` gem raises
  `Nexo::MissingDependencyError`.
- **Bring your own policy.** `isolation:` also takes an `MXC::Sandbox` class or instance, or any
  object answering `supported?` and `run(*command, timeout:, readable:, writable:, directory:,
  env:, network:)`.
- **Verified on macOS (Seatbelt) and on Linux (Bubblewrap, in CI), `mxc` 0.4.1:** a write
  outside `cwd`, a read of a file outside it and a network connection were all refused. A
  Linux host must allow unprivileged user namespaces for Bubblewrap; GitHub's Ubuntu runners
  do.
- Unconfined remains the default. Use a [container](#container-sandbox--docker--apple-container)
  when you need a different filesystem, not only a fence.

### A container per command — `ContainerRunner`

`Nexo::Sandboxes::ContainerRunner` answers the same contract with a throwaway container
for each command, hardened like the container sandbox (no network, capabilities dropped,
read-only root). Use it where a process sandbox is not available or not enough:

```ruby
runner = Nexo::Sandboxes::ContainerRunner.new(image: "ruby:3.3-slim")

class Builder < Nexo::Agent
  sandbox :local, isolation: runner     # files on the host, commands in a container
end

RubyLLM.configure { |config| config.sandbox = runner }   # or for ruby_llm's own run_code
```

The working directory is bound into the container at its own path, read-write, and nothing
else of the host is visible. Each command pays a container start. It cannot honour a host
allow-list: every run has the network the runner was built with, none by default. Verified
on Docker 29 and on Apple `container` 1.7.1 (`runtime: :apple`): a command wrote inside the
workspace, could not read a file outside it, had no network, and was killed at its timeout.

### Two fixes in 0.14 that change behaviour

- **The narrowed environment is now real.** Before 0.14 the shell inherited the whole process
  environment, API keys included; the `PATH`/`HOME`/`LANG` list was only added on top. A command
  that relied on an inherited variable now needs it passed with `env:`
  (`sandbox :local, env: {"BUNDLE_GEMFILE" => "..."}`).
- **A timeout now stops the command.** Before 0.14 `Timeout::Error` was raised only after the
  command had finished on its own. Now the command's whole process group is killed, and the
  `Shell` tool reports the timeout to the model as `{error: ...}` instead of failing the run.

The container sandbox got the same fix in 0.16: until then a timed-out command kept running
inside the container. Each `exec` now carries a marker, and a timeout kills every process in
the container that has it.

## Safety refinements — safer, more legible real-FS sandboxes

Five small refinements tighten the real-filesystem sandboxes (`Local`, `Container`) and make
the execution environment more legible to the model. Each wires into an existing seam — no new
sandbox tier, no new capability, no new dependency. Every one *tightens* a default or *narrows*
scope; none widens authority silently.

- **Self-describing sandbox (`Sandbox#instructions`).** A real-FS sandbox appends one plain-text
  system message describing where the agent runs, so a weak local tool-caller (e.g. Ollama/Gemma)
  knows its environment. `Local` → *"You run on the host machine, cwd /path/to/repo. The real host
  filesystem and shell are reachable; file access is guarded to /path/to/repo."*; `Container` →
  *"You run inside a docker container (image node:22-slim), cwd /workspace, network none…"*.
  `Virtual` says nothing (`#instructions` is `nil`). Ordering in the system messages: **agent
  instructions → sandbox instructions → skill instructions**. Provider-neutral, injected through
  the existing `with_instructions` path.

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

- **Shell output truncation (`Nexo::OutputTruncator`).** Unbounded command output (`npm install`,
  `git log`) is truncated before it reaches the model, so a single command can't blow a small
  context window. `Tools::Shell` wraps `stdout`/`stderr` through
  `OutputTruncator.call(text, max_lines: 200, max_chars: 16_000)` — strips ANSI escapes, keeps the
  **last** `max_lines` lines, appends a `…[truncated N lines]` marker, then caps at `max_chars`.
  The integer `status` passes through untouched. Pure line/char truncation — **no tokenizer**;
  configurable via the kwargs only (no global config, no per-agent macro).

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

- **Scoped `:ask` predicate (`ask_when`).** Under `:ask`, `Permissions.new(ask_when: ->(cap, detail)
  { … })` scopes *which* actions actually prompt a human. When the predicate returns falsey the
  action is auto-allowed **without** calling `on_ask`; truthy (or when `ask_when` is unset) falls
  through to `on_ask` exactly as before. Unset = ask for everything (backward-compatible). It only
  ever *narrows* what is auto-allowed from the "ask for everything" baseline — it never widens
  authority, and it applies to `authorize!` only (the separate MCP ask axis is unchanged).

  ```ruby
  # Only prompt for writes under /protected; auto-allow everything else.
  perms = Nexo::Permissions.new(
    mode: :ask,
    on_ask:   ->(cap, detail) { ask_the_human(cap, detail) },
    ask_when: ->(cap, detail) { cap == :write && detail.to_s.start_with?("/protected") }
  )
  ```

## Ask a sandbox what it has — `#environment`

`#instructions` describes the execution environment *for the model*. `#environment`
answers the same question *for code*, in one `#shell` round trip:

```ruby
sandbox.environment
# => { commands: { "ruby" => { path: "/usr/local/bin/ruby", version: "4.0.0" } },
#      locale: "C.UTF-8",
#      error: nil }
```

It exists because a skill's script runs wherever the sandbox is, which is not the machine
it was written on. Measured on three real sandboxes:

| Sandbox | Probe | `locale` | Commands found |
|---|---|---|---|
| `:local` (host) | 0.14s | `en_US.UTF-8` | ruby 4.0.0, python3 3.14.5, node 26.3.0 |
| `:docker alpine:latest` | 0.25s | **none** | sh only |
| `:docker` full image (~5 GB) | 0.50s | **none** | ruby 4.0.0, python3 3.12.3, node 26.7.0 |
| `:apple` full image | 1.84s | **none** | ruby 4.0.0, python3 3.12.3, node 26.4.0 |

Note the last three rows: **a container has no locale even when it has a full toolchain.**
Under an unset locale Ruby's default external encoding is `US-ASCII`, and a bare
`File.read` on a UTF-8 file raises `Encoding::InvalidByteSequenceError`. "Has the
interpreter" and "can read a UTF-8 file" are independent, so they are reported separately.

The probe is POSIX `sh` — no interpreter needed on the far side, so it works on busybox —
memoized for the sandbox's lifetime, and extensible per call:

```ruby
sandbox.environment(commands: %w[ruby convert])
```

**It never raises.** A sandbox with no shell (`Virtual`) and a probe that could not run
both report empty, with the reason under `:error`:

```ruby
Nexo::Sandboxes::Virtual.new.environment[:error]
# => "sandbox has no shell"
```

That distinction matters: "I looked and there is no ruby" and "I never got to look" have
different fixes. An `:apple` container left on the default `readonly_rootfs: true`, for
instance, cannot start a process at all (`The volume is read only`) — reported as an
`:error`, not as an empty toolchain.

**Scope is deliberately coarse: commands on `PATH` and the locale, never packages.** Gems,
wheels and npm modules belong to whoever builds the image; modelling them here would be a
cross-language dependency resolver competing with the manifest every ecosystem already has.

### Declaring what an agent needs

```ruby
class Publisher < Nexo::Agent
  skills :dashboard_designer
  requires commands: {"ruby" => ">= 3.1"}, locale: :utf8
end
```

Checked once, before the first turn, and it fails with every unmet requirement at once:

```
Publisher cannot run here: no ruby on PATH; no locale set (needs a UTF-8 locale).
Provision the sandbox, or drop the `requires` declaration.
```

- `commands:` maps a command to a `Gem::Requirement` string, or `"*"` for any version. A
  command whose version cannot be read (busybox `sh` prints none) satisfies any constraint
  by being present — an unreadable version is not evidence of a wrong one.
- `locale:` takes `:utf8` (any UTF-8 locale, the case that actually comes up) or an exact
  `String`.
- Declaring nothing is the default and costs **no probe at all**.

The declaration lives here, in Nexo's vocabulary, rather than in the skill file: whoever
wires an agent to a sandbox is the only person who can *fix* a gap, so the declaration and
the fix sit together. A skill states its needs in prose through `compatibility:`, which is
the Agent Skills spec's field for it and is aimed at a human or a model.

## Remote sandbox — bring your own container

`Sandboxes::Remote` contains **zero vendor code**. It wraps any object that satisfies a
four-method contract — `read`, `write`, `exec`, `close` — and delegates the `Sandbox`
interface to it. Switching providers is swapping the injected object, nothing else:

```ruby
sandbox = Nexo::Sandboxes::Remote.new(client: my_container_client)
# read(path)  -> client.read(path)
# write(path, content) -> client.write(path, content)
# shell(cmd, timeout:) -> client.exec(cmd, timeout:)
# glob(pattern)        -> client.exec(<pattern as a positional $1, never interpolated>)
# close                -> client.close
```

Vendor SDKs rarely expose exactly `read/write/exec/close`, so adapt them with a tiny shim
object. Keep the vendor gem a **soft** dependency behind a lazy `require` that raises
`Nexo::MissingDependencyError` when it's absent:

```ruby
# A ~10-line adapter wrapping a hypothetical vendor client to the four-method contract.
class E2BAdapter
  def initialize(api_key:)
    require "e2b"            # soft dep — lazy, only when you actually use it
    @sbx = E2B::Sandbox.create(api_key: api_key)
  rescue LoadError
    raise Nexo::MissingDependencyError, "E2BAdapter needs `gem \"e2b\"` in your Gemfile."
  end

  def read(path)            = @sbx.files.read(path)
  def write(path, content)  = @sbx.files.write(path, content)
  def exec(cmd, timeout: 30) = (r = @sbx.commands.run(cmd, timeout: timeout)
                                {stdout: r.stdout, stderr: r.stderr, status: r.exit_code})
  def close                 = @sbx.kill
end

agent = Nexo::Agent.new(model: ENV.fetch("NEXO_MODEL"),
                        sandbox: Nexo::Sandboxes::Remote.new(client: E2BAdapter.new(api_key: ENV["E2B_API_KEY"])))
```

Nexo ships **only** `Remote` plus this documented pattern — purpose-built
`Sandboxes::E2B` / `Sandboxes::Daytona` classes are a possible future addition, deliberately
left out of v1 because their vendor client APIs aren't pinned yet.

### Path confinement is the client's job

`Local` and `Container` confine every `read`/`write`/`glob` to their working directory and
raise `SecurityError` on escape. **`Remote` does not.** It passes each path to the injected
client untouched, because only the provider knows what its own boundary is.

That is deliberate — Nexo re-implementing a confinement it cannot enforce would be
theatre — but it moves a guarantee you may be relying on. A shim is responsible for:

- rejecting paths that escape the session's working directory;
- deciding what `write` does with a missing parent directory (`Local` creates it,
  `Container` creates it — a shim should too, or say that it does not);
- raising on failure rather than returning a non-zero status the caller may ignore.

Give the shim an `instructions:` describing the environment, too — `Remote` cannot derive
one, and an agent told nothing about where it runs will assume it is on the host:

```ruby
Nexo::Sandboxes::Remote.new(
  client: my_client,
  instructions: "You run in an E2B sandbox, cwd /home/user. Ruby 3.4 is available."
)
```

## Container sandbox — Docker / Apple Container

`Sandboxes::Container` runs an agent's tools inside a **throwaway OCI container** via the
`docker` (default) or Apple `container` CLI — shell-out only through `Open3`, **no client
gem**, no Compose, no image builder. A model-driven agent never touches your host filesystem
or shell directly. Declare it with the `sandbox` macro (`image:` is required — there is no
default image):

```ruby
class ContainerReviewer < Nexo::Agent
  model   ENV.fetch("NEXO_MODEL")
  sandbox :docker, image: "node:22-slim",
          binds: { Dir.pwd => { to: "/workspace/repo", mode: :ro } }
end
```

The container `cwd` defaults to `/workspace` (a container path, **not** your host directory);
the host dir enters only through a `binds:` entry.

### `runtime:` — one class, two CLIs

`sandbox :docker` (or `runtime: :docker`) shells out to `docker`; `sandbox :apple`
(`runtime: :apple`) shells out to Apple's `container` binary. The `run`/`exec` surface is
largely shared; where the CLIs diverge the class branches on the runtime. An unknown
runtime raises `Nexo::ConfigurationError`.

**Apple `container` is verified live** — last against `container` 1.7.1 on macOS 27 (arm64),
with the same test files that run against Docker. Two flags Docker accepts are rejected
outright, so they are omitted for `:apple`:

| Knob | `:docker` | `:apple` |
|---|---|---|
| `--security-opt no-new-privileges` | applied | **rejected** (`Unknown option`) — omitted |
| `--pids-limit` | applied (`512`) | **rejected** (`Unknown option`) — omitted |

Everything else — `--network` (including `none`), `--cap-drop ALL`, `--read-only` with a
writable `--tmpfs`, `--memory`, `--cpus`, `--user`, `-v` binds, `-e` env, `-w`, `exec -i` — is
honored identically.

Because omitting a hardening flag means *weaker isolation than you asked for*, the
difference is reported rather than hidden:

```ruby
sandbox = Nexo::Sandboxes::Container.new(image: "…", runtime: :apple)
sandbox.hardening_gaps
# => ["--security-opt no-new-privileges is not supported by apple",
#     "--pids-limit is not supported by apple"]
```

`hardening_gaps` is empty on `:docker`. If your threat model requires one of those knobs,
check it and refuse rather than assuming every runtime honors every flag.

Practical notes for Apple `container`:

- Its service must be running: `container system start` (or `brew services start container`).
- **On `container` 1.2 a `--tmpfs` under `--read-only` was not writable**, so the default
  read-only rootfs left no writable workspace. That is fixed in 1.7; on an older version pass
  `readonly_rootfs: false` or mount a `:rw` bind.
- Containers are **VM-backed**, so infrastructure failures surface differently — e.g.
  `no available interface strategy for network default, plugin=container-network-vmnet`
  when the network service needs restarting (`container system stop && container system
  start`).

### Lifecycle — ephemeral by default, opt-in reconnect

The container starts **lazily** on first tool use and its id is memoized.

- **Ephemeral (default, `reconnect: false`):** `close` force-removes the container
  (`<bin> rm -f <id>`) and clears the memo. Idempotent — safe with nothing started or called
  twice. A standalone container-backed agent tears its container down on `Agent#close` (the
  agent owns the sandbox it resolved). A workflow driving one through `run_agent` shares the
  run's sandbox — `run_agent` borrows it, so teardown happens once at the end of the run in
  `Workflow.execute`'s `ensure` (on done, suspended, or failed), never per `run_agent` call.
- **Reconnect (`name:` + `reconnect: true`):** every container is tagged at `run` with an
  **exact identity label** — `--label nexo.sandbox.id=<name>`. On start the sandbox looks up
  that container by its **exact label** — on Docker with a filter
  (`docker ps -aq --no-trunc -f label=nexo.sandbox.id=<name>`), on Apple by listing every
  container as JSON and comparing the label (`container list` has no filter) — **not** a name
  substring, and reuses/restarts it instead of creating a new one; `close`
  leaves it running/stopped so a later sandbox with the same name reattaches. The default
  container name is `nexo-<run-id>`.
  - **Exact match, never a substring.** A container merely *named* `<name>x` is never
    reattached — the label filter is exact. This closes the substring-reattach safety hole:
    a long-lived session can never silently bind to the wrong environment.
  - **Ambiguity raises, never guesses.** If more than one container carries the same identity
    label, reconnect raises `Nexo::Error` (`ambiguous reconnect: <n> containers labeled
    <name>`) rather than pick one. Zero matches falls through to a fresh `run`; a
    daemon/CLI failure fails open to the create path.
  - **Reconnect never crosses runtimes.** The lookup shells the runtime-specific binary and
    each runtime keeps its own id namespace, so a `:docker` container is never reattached by an
    `:apple` sandbox or vice versa.

### Honest caveats

- **Network-none breaks installs.** `npm install` / `bundle install` need egress; with the
  default `network: :none` they fail. Pass `network: :bridge` or bake dependencies into the
  image.
- **Read-only rootfs needs the scratch.** With `--read-only`, only the tmpfs at `cwd` (and any
  `:rw` bind) is writable, and the tmpfs is **ephemeral** — lost on `close`. Persist via a
  `:rw` bind (this is where staged files and artifacts land).
- **Non-root is recommended, not forced.** The default hardening holds regardless of uid; set
  `user:` for defense-in-depth.
#### Apple `container` parity table

From live runs against **Apple `container` 1.7.1 on macOS 27 (arm64)** and **Docker 29**
(OrbStack), image `alpine`, in 0.16. An earlier pass used `container` 1.2.2; where the two
differ it is noted.

| Subcommand / flag | Docker | Apple `container` | Divergence → action |
|---|---|---|---|
| `run -d` | ✓ | ✓ | same |
| `exec -i` (stdin reaches the process) | ✓ | ✓ | same — this is what `#write` uses |
| `exec -e KEY=val` | ✓ | ✓ | same — carries the timeout marker |
| `stop` / `start <id>` | ✓ | ✓ | same |
| `rm -f <id>` | ✓ | ✓ | same |
| find by label | `ps -aq -f label=` (exact) | `list --all --format json`, label compared in Ruby | Apple has `list`, not `ps`, and no filter → **reconnect works on both** |
| daemon check | `version` | `system status` | `version` is not an Apple subcommand |
| `--network` (incl. `none`) | ✓ | ✓ | same — `--network none` has no network |
| `--cap-drop ALL` | ✓ | ✓ | same |
| `--read-only` | ✓ | ✓ | rootfs is read-only on both |
| `--tmpfs <cwd>:rw` | ✓ writable | ✓ writable (was **not** on 1.2.2) | same on 1.7.1 |
| `--security-opt no-new-privileges` | ✓ | ✗ `Unknown option` | → omitted for `:apple`, reported in `#hardening_gaps` |
| `--pids-limit` | ✓ | ✗ `Unknown option` | → omitted for `:apple`, reported in `#hardening_gaps` |
| `-v host:ctr:ro` | ✓ | ✓ | same |
| `-w <dir>` | ✓ | ✓ | same |
| `--user` | ✓ | ✓ | same |
| `--memory` / `--cpus` | ✓ | ✓ | same |
| `--progress none` | n/a | ✓ | Apple prints start progress on stderr without it; `ContainerRunner` passes it |

Two operational notes for Apple, both hit during the 1.2.2 verification:

- It resolves its **init image via the keychain** and fails in a non-interactive shell
  (`errSecAuthFailed`, `-25293`). Pin an already-pulled tag to skip the lookup:
  `--init-image ghcr.io/apple/containerization/vminit:<tag>`.
- Containers are **VM-backed**, so infrastructure failures look unfamiliar — e.g.
  `no available interface strategy for network default, plugin=container-network-vmnet`,
  cleared by `container system stop && container system start`.

← Back to the [README](../README.md)
