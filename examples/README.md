# Nexo examples

Each example is a small, runnable script. Two kinds:

- **Offline** — no model, no network, no API key. Run them as-is to see the
  primitive work.
- **Live** (`NEXO_LIVE=1`) — needs a real tool-calling model (`NEXO_MODEL` takes
  any ruby_llm-supported model id; nothing is provider-specific) and sometimes
  an external service (an MCP server, docker, an API key).

Run everything from the repo root with `ruby -Ilib examples/<name>.rb`.

## Offline (start here)

| Example | Shows |
|---|---|
| [`artifact_from_template.rb`](artifact_from_template.rb) | Staging input files into a run's sandbox + rendering a named artifact from a trusted ERB template (Spec 7) |
| [`approval_workflow.rb`](approval_workflow.rb) | Durable human-in-the-loop: `checkpoint` + `suspend!` + `resume` (Spec 13) |

## Live — agents

| Example | Shows | Extra requirements |
|---|---|---|
| [`code_reviewer.rb`](code_reviewer.rb) | The minimal agent against a local Ollama model, with a skill and token accounting | Ollama running locally |
| [`chat_session.rb`](chat_session.rb) | A continuing, addressable `Nexo::Session` that remembers prior turns (Spec 10) | — |
| [`container_review.rb`](container_review.rb) | Agent tools running inside a locked-down OCI container (Spec 12) | `docker` (or Apple `container`) |
| [`news_summary.rb`](news_summary.rb) | Read-only web fetch scoped by `fetch_allow` (Spec 9) | — |
| [`news_search.rb`](news_search.rb) | Host-injected `search_backend` + fetch (Spec 19) | a search backend you inject |

## Live — MCP

| Example | Shows | Extra requirements |
|---|---|---|
| [`mcp_filesystem.rb`](mcp_filesystem.rb) | The MCP seam + permission gate with the official filesystem server — no credentials needed; **start here for MCP** | `npx` |
| [`inbox_digest.rb`](inbox_digest.rb) | Gmail through a stdio MCP server + the `email_triage` skill, read tools only | a Gmail MCP server + OAuth |
| [`inbox_digest_http.rb`](inbox_digest_http.rb) | The same digest over a hosted HTTP MCP server with a host-supplied OAuth bearer token (Spec 18) | a hosted Gmail MCP server |
| [`inbox_digest_task.rb`](inbox_digest_task.rb) | The digest as a Workflow **Task**: `agent` macro + `run_agent` + a named artifact (Spec 8) | same as `inbox_digest.rb` |

## Live — workflows

| Example | Shows | Extra requirements |
|---|---|---|
| [`approval_agent.rb`](approval_agent.rb) | The `:approve` permission mode bridged to a durable suspend/resume (Spec 16) | — |

## Skills used by the examples

The `skills/` directory holds the SKILL.md packages the examples reference
(`email_triage`, `news_summary`, `ruby-code-review`). The examples point
`Nexo.config.skills_path` here; in a Rails host the default is `app/skills`.

See also [`rails_usage.md`](rails_usage.md) for the Rails host-app walkthrough.
