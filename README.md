# Nexo

> Agent = Model + Harness. Nexo is the connective tissue linking RubyLLM to tools,
> sandboxes, skills, and runs.

A model alone forgets everything the moment a response ends. The harness is everything
else. Nexo gives the RubyLLM ecosystem one cohesive front door with safe defaults —
build a working agent in five lines without wiring anything.

## Compose, don't reimplement

Nexo does not rebuild skill loading, the tool-call loop, MCP, or structured output — those
already live in the RubyLLM ecosystem (`ruby_llm` core, `ruby_llm-skills`, `ruby_llm-mcp`,
`ruby_llm-schema`). Nexo **composes** them behind one front door and adds only the two pieces
the ecosystem is missing:

- **Sandbox + Permissions seam** — pluggable execution environment (virtual / local /
  remote) with explicit authorization gating. Default: `:virtual` + `:read_only`.
- **WorkflowRun lifecycle** — a finite-job primitive (runId, status, payload, result,
  inspectable event log) that nothing else in the ecosystem provides cleanly.

## Installation

Add to your Gemfile:

```ruby
gem "nexo_ai"
```

Or install directly:

```sh
gem install nexo_ai
```

In a Rails app, run the install generator to create the conventional layout and an initializer:

```sh
rails g nexo:install
```

```
      create  app/agents/.keep
      create  app/workflows/.keep
      create  app/skills/.keep
      create  config/initializers/nexo.rb
```

## Configuration

Configure the harness in one place with `Nexo.configure`. Defaults are safe and
provider-neutral — there is intentionally no hardcoded model:

```ruby
Nexo.configure do |config|
  config.default_model       = ENV["NEXO_MODEL"] # provider-neutral: no default
  config.default_sandbox     = :virtual          # :virtual | :local
  config.default_permissions = :read_only        # :read_only | :auto | :ask
  config.skills_path         = "app/skills"
end

Nexo.config.default_sandbox      # => :virtual
Nexo.config.default_permissions  # => :read_only
Nexo.config.default_model        # => nil unless set
```

`require "nexo"` (and `require "nexo_ai"`) works in plain Ruby with no Rails loaded.

## Requirements

- Ruby 3.2+
- [ruby_llm](https://github.com/crmne/ruby_llm) >= 1.16

## Status

🚧 **Early development.** API is not stable. See [maquina.app](https://maquina.app)
for updates.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
