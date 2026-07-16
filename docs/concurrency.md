# Concurrency (opt-in async)
Async is entirely optional — Nexo runs synchronously by default and only needs the `async` gem when you use a fan-out feature.

Async is **entirely optional**. Nexo installs and runs synchronously with no
`async` gem present, and only complains if you actually use a concurrency
feature. The `async` gem is a soft dependency — add it yourself when you want
fan-out:

```ruby
gem "async", "~> 2.0"
```

Two facts make this cheap:

- **LLM calls are already async-compatible.** `ruby_llm` speaks HTTP over
  Faraday's `net/http` adapter, which yields on socket I/O under Ruby's fiber
  scheduler. `Loops::RubyLLM` therefore runs unchanged inside a reactor — no API
  change, no rewrite. Wrapping a *single* `agent.prompt` in `Async {}` gains
  nothing; async only pays off under fan-out.
- **The value Nexo adds is rate-bounded fan-out.** `Nexo.concurrent` bounds
  in-flight work so you don't trip provider rate limits, and propagates the first
  error instead of swallowing it.

## `Nexo.concurrent` — bounded fan-out

```ruby
# 100 docs, but never more than 8 provider calls in flight; results in doc order.
results = Nexo.concurrent(max_in_flight: 8) do |c|
  Document.find_each { |d| c.add { SummarizeDocument.run(doc_id: d.id, text: d.body).result } }
end
```

Every block added with `c.add { … }` runs inside **one** `async` reactor,
capped at `max_in_flight` in flight (an `Async::Semaphore`) and coordinated by an
`Async::Barrier`. Results come back as an Array in **submission order** (not
completion order). On the first task that raises, that error is **re-raised** and
the remaining in-flight tasks are stopped — errors are never swallowed.
`max_in_flight` defaults to `Nexo.config.max_in_flight` (`8`) and is the single
most important knob for staying under provider rate limits.

Using `Nexo.concurrent` with `async` not installed raises
`Nexo::MissingDependencyError` with install guidance.

Inside a durable workflow, `Workflow#checkpoint_all` is the workflow-durability
flavored sibling of `Nexo.concurrent`: it drives this same bounded fan-out but
persists each step to the run's `state` as it lands, so a resume only re-runs what
never completed. See [Parallel checkpoints](durable-workflows.md#parallel-checkpoints--checkpoint_all)
in the durable-workflows guide.

## `Sandboxes::Local` offload

Under a reactor, blocking file/subprocess I/O would stall every other fiber. Flip
the switch and `Sandboxes::Local` offloads its `read`/`write`/`glob`/`shell` to a
worker thread:

```ruby
Nexo.configure { |c| c.concurrency = :async }   # default is :threaded
```

The decision is driven by config, not by scheduler detection: under `:async` the
blocking block runs on a worker thread so the reactor keeps serving other fibers;
under `:threaded` (the default) it runs inline with zero overhead — byte-for-byte
the synchronous behavior. Offloading changes neither return values nor the
security properties: the path-escape guard, narrowed ENV, and `Timeout`-wrapped
subprocess are all preserved. (`Sandboxes::Virtual` is pure memory and
`Sandboxes::Remote` is already HTTP/fiber-friendly — neither needs offload.)

## `Workflow` buffered emit

Each `emit` normally persists immediately. Under a reactor that per-event DB write
blocks the whole loop, so `Workflow.run` takes a `buffer_events:` flag (default
`Nexo.config.buffer_workflow_events`, `false`):

```ruby
run = SummarizeDocument.run({doc_id: 1, text: body}, buffer_events: true)
# events buffer in memory and flush to the store exactly once, on completion
```

With buffering on, events accumulate in memory and flush in a single
`save_events!` at the end of the run (on both success and failure). The default
(unbuffered) behavior is unchanged.

## Running under Rails / a fiber server

Async DB work is the sharp edge. Under a fiber server such as
[Falcon](https://github.com/socketry/falcon), many concurrent queries can exhaust
the ActiveRecord connection pool, so:

- **Raise `DB_POOL`** (the connection-pool size) to cover your in-flight
  concurrency.
- On **Rails 7.1+**, consider
  `config.active_record.async_query_executor`.
- Prefer `buffer_events: true` for workflows so each run writes its event log
  once instead of per event.

Note that DB work under a reactor is *offloaded/pooled*, not truly fiber-async —
Nexo does not ship a fiber-native DB driver. For server setup (Falcon, the fiber
scheduler), see the [`async` guide](https://socketry.github.io/async/).

← Back to the [README](../README.md)
