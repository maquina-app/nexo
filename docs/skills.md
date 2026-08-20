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

To make them reachable, copy them in through the sandbox's own `#write` — the only route
that works on every tier:

```ruby
skill = Nexo::Skills.find(:dashboard_designer)

skill.scripts.each do |host_path|
  agent.sandbox.write(File.join("scripts", File.basename(host_path)), File.binread(host_path))
end
```

They are then ordinary workspace files, reached through the permission-gated `read`,
`glob` and `shell` tools like anything else in the workspace.

Two things to get right:

- **Use relative paths** (`"scripts/render.rb"`), in the write and in any command you
  hand the agent. A host-absolute path is meaningless inside a container and on a remote
  sandbox.
- **A bundled script must not depend on ambient environment.** It runs wherever the
  sandbox is, which may have no locale (Ruby then defaults to `US-ASCII`, and reading a
  UTF-8 file raises `Encoding::InvalidByteSequenceError`), a different `PATH`, or no
  interpreter at all. Be explicit — `File.read(path, encoding: "UTF-8")` — and document
  which interpreter your skill needs.

Staged files land in **writable** space. If the agent also holds `:shell` it can rewrite
a script before running it, so re-stage on every run when that matters.

← Back to the [README](../README.md)
