# Skills
A skill is a `SKILL.md` package that teaches the model *how you want a task done* — reasoning, layered on with one macro.

A **skill** is a `SKILL.md` package — frontmatter plus instructions — that teaches the
model *how you want a task done*. Skills guide **reasoning**; the sandbox-backed tools
above perform **execution**. Nexo does not implement skill loading; it composes the
[`ruby_llm-skills`](https://github.com/kieranklaassen/ruby_llm-skills) gem so you attach a
skill with one macro and no loader setup.

Drop a package under `app/skills/` (or scaffold one — see below):

```
app/skills/
└── triage/
    ├── SKILL.md          # frontmatter (name, description) + process steps
    └── references/       # supporting docs the skill can cite
```

```markdown
---
name: triage
description: Triage incoming issues by severity and route them to the right owner.
---

# Triage

## Process
1. Classify the issue severity.
2. Route to the right owner.
```

Reference it with the `skills` macro — its instructions are layered on top of the agent's
own, in declaration order:

```ruby
require "nexo"

class TriageAgent < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")   # any ruby_llm model — never a hardcoded vendor default
  skills :triage                  # one macro, no loader wiring
end

TriageAgent.new.chat   # chat built with the base sandbox tools + the skill's instructions
```

Scaffold a new skill package with the generator (creates a valid `SKILL.md` plus a
`references/` directory):

```sh
rails g nexo:skill triage
#   create  app/skills/triage/references/.keep
#   create  app/skills/triage/SKILL.md
```

`ruby_llm-skills` is an **optional** dependency — required lazily only when you use a skill.
Without it installed, `require "nexo"` still loads; touching a skill raises a clear
`Nexo::MissingDependencyError` telling you to add `gem "ruby_llm-skills"`. Referencing a
skill that does not exist raises `Nexo::Error` naming the missing `SKILL.md` path.

## Say what a skill needs with `compatibility:`

A skill's script runs in whatever the agent's sandbox happens to be — which is not the
machine the script was written on. A container typically has **no locale**, so Ruby's
default external encoding is `US-ASCII` and a bare `File.read` on a UTF-8 file raises;
it may also have no interpreter at all.

`compatibility:` is the Agent Skills spec's field for saying so, and Nexo passes it to
the model alongside the skill body:

```yaml
---
name: dashboard-designer
description: Render the briefing dashboard.
compatibility: Requires a Ruby interpreter (>= 3.1) and a UTF-8 locale.
---
```

The model sees the body, then `Compatibility: Requires a Ruby interpreter …` as a labelled
line, so it can tell a requirement from a step. Skills that do not set the field contribute
exactly their body, unchanged.

It is **free text, by design** — the spec does not make it machine-checkable, and Nexo does
not try to. It is documentation aimed at a human or a model, not a dependency manifest:
provisioning the sandbox (a gem, a library, a config) is the job of whoever wires the agent
to it, not of the skill file. `license:` and `allowed-tools:` are parsed by
`ruby_llm-skills` but deliberately **not** surfaced — the first is prompt noise, and the
second would compete with `Nexo::Permissions`, which is the real gate.

## Skill tools stay gated

A skill contributes **instructions only**. A loaded skill ships no independent tools, and
Nexo deliberately does not attach `ruby_llm-skills`' progressive-disclosure tool (which
reads files outside the sandbox) — so **attaching a skill never widens what an agent can
do** beyond its configured sandbox/permission mode.

## Bundled files are not reachable until you stage them

A skill's `scripts/`, `assets/` and `references/` live under `skills_path`, which is
**outside every sandbox**. Sandboxes confine file access to their own working directory
(`Local` and `Container` raise `SecurityError` on escape), so an agent cannot read or run
a skill's bundled files just because the skill is attached.

`Skills.materialize` copies them in, through the sandbox's own `#write` — the only route
that works on every tier:

```ruby
staged = Nexo::Skills.materialize(:dashboard_designer, into: agent.sandbox)
# => { scripts: ["scripts/render_dashboard.rb"],
#      assets:  ["assets/dashboard-template.html"] }
```

They are then ordinary workspace files, reached through the permission-gated `read`,
`glob` and `shell` tools like anything else in the workspace — and the returned paths are
**sandbox-relative**, so you can build a command without knowing which tier you are on:

```ruby
agent.prompt("Run: ruby #{staged[:scripts].first} digest.json #{staged[:assets].first} out.html")
```

`Local` writes to the filesystem, `Container` streams over `docker exec` / `container
exec`, and `Remote` hands off to the injected client. The call is identical.

| Option | Meaning |
|---|---|
| `kinds:` | which of `scripts` / `assets` / `references` to copy (default: all three) |
| `overwrite:` | `false` skips files already present — what you want against an image that bakes the skill in |

Kinds the skill ships nothing for are omitted from the result.

Two things to get right:

- **Use relative paths** (`"scripts/render.rb"`), in the write and in any command you
  hand the agent. A host-absolute path is meaningless inside a container and on a remote
  sandbox.
- **A bundled script must not depend on ambient environment.** It runs wherever the
  sandbox is, which may have no locale (Ruby then defaults to `US-ASCII`, and reading a
  UTF-8 file raises `Encoding::InvalidByteSequenceError`), a different `PATH`, or no
  interpreter at all. Be explicit — `File.read(path, encoding: "UTF-8")` — and document
  which interpreter your skill needs.

Staged files land in **writable** space. If the agent also holds `:shell` it can rewrite a
script before running it — where the same file, left outside the sandbox, could not be
touched at all. `materialize` overwrites by default, so re-materializing at the start of
every run bounds tampering to a single turn. If that is not enough, keep the resource out
of the sandbox and feed the agent its contents another way.

← Back to the [README](../README.md)
