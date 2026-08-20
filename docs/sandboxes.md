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
| `:approve`               | ✅      | ✅      | per `decision`      | per `decision`                    | per `decision` | per `decision` |
| `Virtual` sandbox        | ✅      | ✅      | ✅ (in-memory)      | ❌ `NotImplementedError`→`{error}` | ✅ †       | ✅ †       |
| `Local` sandbox          | ✅ (guarded) | ✅ | ✅ (guarded)        | ✅ (narrowed ENV)                 | ✅ †       | ✅ †       |
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
- **`Local`** — host filesystem + shell, for trusted dev/CI. Two guards: every path is
  expanded against `cwd` and must stay inside it (else `SecurityError`), and the shell sees
  only `PATH`, `HOME`, `LANG` (plus explicit `env:` additions) — never the full process
  environment.
- **`Container`** — run the tools inside a throwaway local container via the `docker`
  (default) or Apple `container` CLI. Shell-out only, no client gem. **Hardened by default**
  (no network, dropped caps, read-only rootfs + ephemeral scratch, read-only host binds);
  every hardening is an explicit opt-out. See [Container sandbox](#container-sandbox--docker--apple-container) below.
- **`Remote`** — run the tools inside a remote container (E2B / Daytona / Modal / Docker /
  your own) by injecting a client. Escalating to `:remote` is always an explicit choice in
  your code — the default stays `:virtual`.

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

- **Capability-gated tool attach (`Sandbox#supports?`).** A `:virtual` agent no longer advertises
  a `Shell` tool it can never run — `Agent#chat` attaches `Shell` only when
  `@sandbox.supports?(:shell)`. `Local`/`Container` support all four capabilities; `Virtual`
  supports everything but `:shell`. `ReadFile`/`WriteFile`/`Glob` are always attached.

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
- A declared name is probed **as written**, so an absolute path is a legitimate
  requirement — `requires commands: {"/opt/rubies/4.0.0/bin/ruby" => ">= 3.0"}` is what you
  want when the sandbox shell's `PATH` is narrow enough that a version-managed interpreter
  does not resolve there. The check then runs against the exact binary the agent will
  invoke, not against whichever one happens to be first on `PATH`.

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

**Apple `container` parity is now verified** against `container` 1.2.2 on macOS. Three
flags docker accepts are rejected outright, so they are omitted for `:apple`:

| Knob | `:docker` | `:apple` |
|---|---|---|
| `--security-opt no-new-privileges` | applied | **rejected** (`Unknown option`) — omitted |
| `--pids-limit` | applied (`512`) | **rejected** (`Unknown option`) — omitted |
| `--read-only` + `--tmpfs <cwd>:rw` | scratch is writable | flags accepted, but **the scratch is NOT writable** |

Everything else — `--network` (including `none`), `--cap-drop ALL`, `--memory`,
`--cpus`, `--user`, `-v` binds, `-e` env, `-w`, `exec -i` — is honored identically.

> **`readonly_rootfs: true` is the default, and on `:apple` it leaves you with no
> writable workspace.** Apple accepts `--tmpfs /workspace:rw` but under `--read-only`
> the mount is still read-only, so every `write` fails. Pass `readonly_rootfs: false`,
> or mount a `:rw` bind, when using the `:apple` runtime.

Because omitting a hardening flag means *weaker isolation than you asked for*, the
difference is reported rather than hidden:

```ruby
sandbox = Nexo::Sandboxes::Container.new(image: "…", runtime: :apple, network: :none)
sandbox.hardening_gaps
# => ["--security-opt no-new-privileges is not supported by apple",
#     "--pids-limit is not supported by apple",
#     "apple has no 'none' network; using 'default' instead"]
```

`hardening_gaps` is empty on `:docker`. If your threat model requires one of those knobs,
check it and refuse rather than assuming every runtime honors every flag.

Two practical notes for Apple `container`:

- It resolves its **init image through the keychain** and fails in a non-interactive
  shell (`errSecAuthFailed`, status `-25293`). Pinning an already-pulled tag avoids the
  lookup: `container run --init-image ghcr.io/apple/containerization/vminit:<tag> …`.
- Containers are **VM-backed**, so infrastructure failures surface differently — e.g.
  `no available interface strategy for network default, plugin=container-network-vmnet`
  when the network service needs restarting (`container system stop && container system
  start`).

### Hardened by default — every knob an explicit opt-out

All of the following are applied to the `run` argv by default and individually invertible:

| Concern | Default | Loosen with |
|---|---|---|
| Network | `--network none` (no egress) | `network: :bridge` / `:host` / a network name |
| Capabilities | `--cap-drop ALL` | `cap_add: %w[NET_BIND_SERVICE ...]` |
| Rootfs | `--read-only` | `readonly_rootfs: false` |
| Writable scratch | `--tmpfs <cwd>:rw` (ephemeral), only when `readonly_rootfs` | a `:rw` host bind for persistence |
| Privilege escalation | `--security-opt no-new-privileges` | (not exposed) |
| PIDs | `--pids-limit 512` (fork-bomb guard) | `pids_limit:` (`nil` omits the flag) |
| Memory / CPU | unset (host decides) | `memory:` / `cpus:` |
| User / uid | left to the image | `user:` (opt-in defense-in-depth) |
| Host binds | **read-only** (`:ro`) | per-bind `{ to:, mode: :rw }` |
| Env vars | none | `env: { "KEY" => "val" }` → one `-e KEY=val` per entry |

Bind spec forms:

```ruby
binds: { "/host/proj" => "/workspace/proj" }                       # -> :ro
binds: { "/host/proj" => { to: "/workspace/proj", mode: :rw } }    # -> :rw
```

**Non-root is not forced.** The image's own uid is respected; `user:` is an opt-in. The other
hardening (`--cap-drop ALL`, `--security-opt no-new-privileges`, `--read-only`,
`--network none`) applies **regardless of uid**.

Every argument is passed to `Open3` as an **array**, never string-interpolated, so file
contents and commands can't break out of the argv. Paths are expanded against the container
`cwd` and a path that escapes raises `SecurityError`. A denied/failed **tool** op surfaces as
`{ error: ... }` through the gated tool layer; the **sandbox** itself raises only on misuse —
a missing binary (`Nexo::ConfigurationError` naming the binary), a path escape (`SecurityError`),
or a container start failure (`Nexo::Error`).

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
  that container by the **exact label filter** (`docker ps -aqf label=nexo.sandbox.id=<name>`),
  **not** a name substring, and reuses/restarts it instead of creating a new one; `close`
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
- **Apple `container` needs `readonly_rootfs: false`.** The default read-only rootfs makes the
  `--tmpfs` scratch unwritable on Apple, so an agent cannot write to its own workspace. The
  parity table below records what was verified.
- **Reconnect is Docker-only today.** `reconnect: true` combined with `runtime: :apple` raises
  `Nexo::ConfigurationError` at the point reconnect would run. Apple's `container` CLI has no
  **live-verified** exact `label=` filter, and a name-substring match is unsafe (it can attach
  the wrong container), so reconnect refuses rather than risk it. Use `runtime: :docker` for
  reconnect, or run an ephemeral `:apple` sandbox (`reconnect: false`). If a future Group 0 run
  confirms an exact-identity mechanism on Apple, wire that verified mechanism instead of raising.

#### Apple `container` parity table (Group 0)

Filled from live Group 0 runs against **Apple `container` 1.2.2 on macOS (arm64)** and
**Docker 29.4.0**, image `ubuntu:24.04`. Rows marked _unverified_ have not been run.

| Subcommand / flag | Docker | Apple `container` | Divergence → action |
|---|---|---|---|
| `run -d` | ✓ | ✓ | same |
| `exec -i` (stdin reaches the process) | ✓ | ✓ | same — this is what `#write` uses |
| `stop` / `start <id>` | ✓ | ✓ | same |
| `rm -f <id>` | ✓ | ✓ | same |
| `ps -aqf label=` | ✓ (exact) | ✗ `Plugin 'container-ps' not found` | Apple has `list`, not `ps` → **reconnect raises `ConfigurationError`** |
| `--network` (incl. `none`) | ✓ | ✓ | same — `--network none` runs |
| `--cap-drop ALL` | ✓ | ✓ | same |
| `--read-only` | ✓ | ✓ | rootfs is read-only on both |
| `--tmpfs <cwd>:rw` | ✓ writable | ✗ **not writable under `--read-only`** | → omit `--read-only` (`readonly_rootfs: false`) or use a `:rw` bind |
| `--security-opt no-new-privileges` | ✓ | ✗ `Unknown option` | → omitted for `:apple`, reported in `#hardening_gaps` |
| `--pids-limit` | ✓ | ✗ `Unknown option` | → omitted for `:apple`, reported in `#hardening_gaps` |
| `-v host:ctr:ro` | ✓ | ✓ | same |
| `-e KEY=val` | ✓ | ✓ | same |
| `-w <dir>` | ✓ | ✓ | same |
| `--user` | ✓ | ✓ | same |
| `--memory` / `--cpus` | ✓ | ✓ | same |

Two operational notes for Apple, both hit during verification:

- It resolves its **init image via the keychain** and fails in a non-interactive shell
  (`errSecAuthFailed`, `-25293`). Pin an already-pulled tag to skip the lookup:
  `--init-image ghcr.io/apple/containerization/vminit:<tag>`.
- Containers are **VM-backed**, so infrastructure failures look unfamiliar — e.g.
  `no available interface strategy for network default, plugin=container-network-vmnet`,
  cleared by `container system stop && container system start`.

← Back to the [README](../README.md)
