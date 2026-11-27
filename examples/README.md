# Nexo examples

Each example is one runnable script. Run them from the repo root:

```sh
ruby -Ilib examples/<name>.rb
```

- **Offline** examples need no model, no network and no key.
- **Live** examples need `NEXO_LIVE=1` and a tool-calling model. `NEXO_MODEL` takes
  any model id `ruby_llm` knows. For a model its registry does not list — a local
  Ollama tag, a self-hosted build — also set `NEXO_PROVIDER`:

  ```sh
  NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/chat_session.rb
  ```

  `OLLAMA_API_BASE` and `API_KEY` point the `ollama` provider at any local
  OpenAI-compatible server (default `http://127.0.0.1:11434/v1`, no key).

## Offline — start here

| Example | Shows |
|---|---|
| [`approval_workflow.rb`](approval_workflow.rb) | A run that pauses for a person: `checkpoint`, `suspend!`, `resume` |
| [`retry_and_cancel.rb`](retry_and_cancel.rb) | `Workflow.retry` finishing a failed run without repeating its checkpoints; `Workflow.cancel` |
| [`artifact_from_template.rb`](artifact_from_template.rb) | Staging files into a run's sandbox and rendering a named artifact from an ERB template |
| [`confined_shell.rb`](confined_shell.rb) | The local shell in an OS sandbox: what it can write, read and reach, next to the unconfined one (needs `mxc`) |

## Live — one agent

| Example | Shows | Also needs |
|---|---|---|
| [`code_reviewer.rb`](code_reviewer.rb) | The smallest agent: a model, a skill, a read-only sandbox | — |
| [`chat_session.rb`](chat_session.rb) | `Nexo::Session`: a conversation that remembers earlier turns | — |
| [`llm_options.rb`](llm_options.rb) | The `llm` block: a fallback model, a temperature, a context budget, and the `:fallback` event | — |
| [`deferred_tools.rb`](deferred_tools.rb) | `tools …, defer: true`: a catalogue the model searches instead of carrying | — |
| [`usage_report.rb`](usage_report.rb) | Tokens and cost per prompt (`:usage`) and per run (`Workflow.usage`) | — |
| [`news_summary.rb`](news_summary.rb) | Web fetch limited to an allow-list of hosts | network |
| [`news_search.rb`](news_search.rb) | A search backend you inject, plus fetch (ships with a stand-in backend) | network |
| [`container_review.rb`](container_review.rb) | An agent whose tools run in a locked-down container | `docker` or Apple `container` |

## Live — a person in the loop

| Example | Shows |
|---|---|
| [`approval_agent.rb`](approval_agent.rb) | `permissions :approve`: a write suspends the run until someone decides |
| [`multiple_approvals.rb`](multiple_approvals.rb) | Several calls waiting at once, approved and declined by key |
| [`tool_question.rb`](tool_question.rb) | A tool that asks the person a question; the run resumes with the answer |
| [`data_analyst.rb`](data_analyst.rb) | `:ask`: SQL reads run freely, a statement that changes data is put to a hook (needs `sqlite3`) |

## Live — MCP

| Example | Shows | Also needs |
|---|---|---|
| [`mcp_filesystem.rb`](mcp_filesystem.rb) | An MCP server behind the allow-list: reads allowed, writes not offered. **Start here for MCP.** | `npx` |
| [`company_brain.rb`](company_brain.rb) | MCP resources (`resources: true`) and a session: answers from documents, with the source | — (ships its own small server) |
| [`mcp_oauth.rb`](mcp_oauth.rb) | Signing in to an OAuth MCP server from a terminal, with stored credentials | an OAuth MCP server (`NEXO_MCP_URL`) |

## Live — several agents in a workflow

| Example | Shows |
|---|---|
| [`inbox_digest_task.rb`](inbox_digest_task.rb) | A Task: `agent` + `run_agent` over staged files, with the result kept as an artifact |
| [`support_agent.rb`](support_agent.rb) | A policy in a skill, a lookup tool, and two tools that act and wait for approval — and why such tools must be idempotent |
| [`software_factory.rb`](software_factory.rb) | A coder and a read-only reviewer with the tests run as plain code between them; `emit_agent_event` |
| [`marketing_team.rb`](marketing_team.rb) | Three specialists working one brief concurrently with `checkpoint_all`, then an editor |

`support_agent`, `data_analyst`, `software_factory`, `marketing_team` and
`company_brain` are Nexo versions of the templates [Eve](https://vercel.com/eve)
ships. Eve's channels (Slack, Discord), schedules and subagents have no
counterpart in Nexo: a channel and a schedule belong to your application, and
routing between agents is plain Ruby in a workflow.

## Support files

- `skills/` — the `SKILL.md` packages the examples use (`email-triage`, `news-summary`,
  `refunds`, `ruby-code-review`). The examples point `Nexo.config.skills_path` here;
  in a Rails app the default is `app/skills`.
- `support/model.rb` — reads `NEXO_MODEL` and `NEXO_PROVIDER` for the live examples.
- `support/handbook_server.rb`, `support/handbook/` — the small MCP server and the
  pages `company_brain.rb` reads.

See also [`rails_usage.md`](rails_usage.md) for the Rails host-app walkthrough.
