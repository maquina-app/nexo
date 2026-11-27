# Tools
Nexo attaches file tools and a `Shell` tool, each gated by the [sandbox](sandboxes.md) and [permission](permissions.md) seams. Since 0.16 the file tools are `ruby_llm`'s own — `list_files`, `read_file`, `search_files`, `write_file` and `edit_file` — working on the agent's sandbox; see [File tools](#file-tools) below.

Which tools attach depends on what the sandbox supports *and* on what the permission mode could
ever allow:

- **Gated tool attach, on two axes.** An agent does not advertise a tool it could never
  successfully call, because a guaranteed failure in the schema costs a round trip every time a
  model tries it. `Agent#chat` attaches a tool only when **both** hold:

  1. *The sandbox supports the capability* (`Sandbox#supports?`). `Local`/`Container` support all
     four; `Virtual` supports everything but `:shell`, so a `:virtual` agent has no `Shell`.
  2. *The permission gate does not deny it statically* (`Permissions#never_allows?`). Under
     `:read_only`, `:write` and `:shell` can never be authorized unless listed in `allow:`, so
     neither the writing tools (`write_file`, `edit_file`) nor `Shell` are attached. `:auto`, `:ask` and `:approve` decide per call
     and always attach.

  The same rule covers a host tool declared with `capability:` and, since 0.14, an MCP tool:
  under `:read_only` one that is not in `mcp_allow` is not attached.

  The reading tools (`list_files`, `read_file`, `search_files`) are always attached. This is a cost and description-accuracy measure, not
  a security boundary: `Permissions#authorize!` remains the gate and still denies at call time.

To bound what **any** tool returns — an MCP tool, one of your own — declare a context
budget. It is `ruby_llm`'s own, one of the model options in the `llm` block:

```ruby
class Researcher < Nexo::Agent
  llm { context_budget per_result: 0.25, per_request: 0.7 }
end
```

(Before 0.16 this was a `context_budget` macro on the agent. It was a pass-through and was
removed; the macro now raises `Nexo::ConfigurationError` pointing here.)

`per_result:` cuts a single result longer than that share of the model's context window;
`per_request:` leaves the oldest results out of a request that would exceed its share. Both
need the window, which `ruby_llm` knows only for models in its registry: for a local or
unregistered model add `window: 128_000`, or the budget does nothing.

`Shell` truncates unbounded command output before it reaches the model:

- **Shell output truncation (`Nexo::OutputTruncator`).** Unbounded command output (`npm install`,
  `git log`) is truncated before it reaches the model, so a single command can't blow a small
  context window. `Tools::Shell` wraps `stdout`/`stderr` through
  `OutputTruncator.call(text, max_lines: 200, max_chars: 16_000)` — strips ANSI escapes, keeps the
  **last** `max_lines` lines, appends a `…[truncated N lines]` marker, then caps at `max_chars`.
  The integer `status` passes through untouched. Pure line/char truncation — **no tokenizer**;
  configurable via the kwargs only (no global config, no per-agent macro).

## File tools

An agent's file tools are `ruby_llm`'s own, attached over the agent's sandbox and behind the
permission gate. This is the default since 0.16; before that it was opt-in as
`file_tools :core`.

```ruby
class Editor < Nexo::Agent
  sandbox :local
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
end

Editor.new.chat.tools.keys
# => [:list_files, :read_file, :search_files, :write_file, :edit_file]
```

Reading, listing and searching are `:read`; writing and editing are `:write`, and under
`:read_only` the two writing tools are not attached. Under `:approve`, a write suspends the
run with the file's path as the detail.

- **Read before write.** The model cannot overwrite or edit a file it has not read in this
  chat, or one that changed since it read it. The check compares content digests, so it works
  on every sandbox, `:virtual` included. A new file is written freely.
- **Large files are paged**: 1,000 lines or 20,000 characters a call.
- **Dotfiles are not listed.**
- **Listing goes through the sandbox.** `:virtual` and `:local` answer directly. A container
  or remote sandbox runs one `find`, and reads each file to report its size.
- **There is no delete**, because a sandbox has none.
- The tool classes are internal to `ruby_llm`; Nexo's tests drive them through the real
  loop, which is what will catch a change there.

The `file_tools` macro chooses the set per agent, and `Nexo.config.file_tools` for every agent:

| `file_tools` | What the agent gets |
|---|---|
| `:core` (default) | `list_files`, `read_file`, `search_files`, `write_file`, `edit_file` |
| `:none` | No file tools. For an agent whose files come from somewhere else, such as a filesystem MCP server. |

### An MCP server with the same tool names

A filesystem MCP server usually calls its tools `read_file`, `write_file` and `search_files`
too. Two tools cannot share a name, so an agent that allows one of them raises a
`Nexo::ConfigurationError` naming the clash when its chat is built. Pick one side:

```ruby
class RemoteFiles < Nexo::Agent
  file_tools :none                       # the server's tools are the file tools
  mcp :files, transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-filesystem /data]
  mcp_allow "read_file", "search_files"
end
```

Or keep Nexo's and leave the clashing names out of `mcp_allow`.

### Upgrading from Nexo's own file tools

| Before 0.16 | Since 0.16 |
|---|---|
| `nexo--tools--read_file` | `read_file` (answers with line numbers, paged) |
| `nexo--tools--write_file` | `write_file`, or `edit_file` to change part of a file |
| `nexo--tools--glob` | `list_files` (with `pattern:`), or `search_files` for contents |

A skill or prompt that names an old tool, and a host that reads tool events by name, need the
new names. Nexo's own three (`Tools::ReadFile`, `Tools::WriteFile`, `Tools::Glob`) and
`file_tools :nexo` were removed in 0.16; `:nexo` raises `Nexo::ConfigurationError`.

A path may be relative to the sandbox's working directory or absolute inside it:
`/workspace/notes.md` in a container whose working directory is `/workspace` is `notes.md`.
`ruby_llm` treats every path as relative, so Nexo makes that translation before the gate and
the tool see the call. The `:glob` capability is still accepted in `allow:`, but nothing asks
for it any more: listing and searching are `:read`.

## Tools of your own — the `tools` macro

Declare a `RubyLLM::Tool` you wrote on the agent, and say what it does in Nexo's terms:

```ruby
class Archivist < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")

  tools Today, SumPayments                    # no side effects: no gate
  tools ArchiveRun, capability: :write        # gated exactly like write_file
  tools ->(agent) { Lookup.new(root: agent.cwd) }
end
```

Each entry is a tool class (built with no arguments), an instance, or a lambda that takes the
agent and returns a tool or an Array of tools. The macro accumulates and is inherited.

With `capability:` (`:read`, `:write`, `:shell`, `:fetch` or `:search`) the tool is wrapped in
`Nexo::GatedTool`, and the agent's permissions decide every call the same way they do for Nexo's
own tools: refused under `:read_only`, put to `on_ask` under `:ask`, suspended under `:approve`.
A denied call returns `{error: ...}` and the tool body never runs. A gated tool the mode can never
allow is left out of the schema. The detail your `on_ask`/`ask_when` hook receives is the tool
name followed by its arguments as JSON.

Without `capability:` the tool runs ungated. That is right only for a tool with no side effects.

### A long catalogue — `defer: true`

```ruby
tools(*Catalog.tools, capability: :read, defer: true)
```

A deferred tool's definition stays out of the model's context until the provider's tool search
loads it (0.16, `ruby_llm`'s `with_tools(defer:)`). A provider without tool search gets it as
an ordinary tool. Deferring changes what the model is told up front, not what it may do: a
deferred tool is gated exactly like any other. `mcp :name, …, defer: true` does the same for
a server's tools.

### `strict_tools` — refuse what was never declared

A tool added to the chat any other way — typically by overriding `#chat` and calling
`with_tools` — is one no permission gate ever saw. Nexo catches those calls with a single
`around_tool_call` block:

- By default (since 0.16) the call is **refused**: the model is told the call did not run, and
  Nexo prints one notice per tool name saying which agent and which tool.
- With `Nexo.config.strict_tools = false` the call runs, with the same notice. That was the
  default before 0.16.

```ruby
Nexo.configure { |config| config.strict_tools = false } # only while you move tools to the macro
```

A name that is not on the chat at all — a tool the model made up — is not Nexo's to refuse:
`ruby_llm` answers it with its own "There is no tool named…" error and nothing runs. The block is a
backstop, not the gate: a refused call can only carry `ruby_llm`'s fixed "did not run" text, so
the gate that explains itself stays with the tool.

These are sandbox refinements as much as tool behavior — see [Sandboxes](sandboxes.md) for the
guard details behind each capability. The `fetch` tool for reading the web lives in
[Web](web.md), gated by its own `:fetch` capability plus a host allow-list.

← Back to the [README](../README.md)
