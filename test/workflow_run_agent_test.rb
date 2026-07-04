# frozen_string_literal: true

require "test_helper"

# Spec 8 — Workflow↔Agent glue. Asserts the `run_agent` outcomes with a REAL spy
# agent (a plain object, not Minitest::Mock) that records the prompt, records
# close, exposes the sandbox it was bound to, and yields canned (type, payload)
# events exactly like the real Loops::RubyLLM would. This keeps the core suite
# offline — no live model, Virtual sandbox — while still driving the whole glue:
# shared sandbox, event forwarding as agent_*, the json-safe reducer, and close.
class WorkflowRunAgentTest < Minitest::Test
  def setup = Nexo::RunStore::Memory.reset!

  # A spy agent bound to the workflow's sandbox. It reads the staged file from
  # THAT sandbox (proving the share) and yields the three loop events with real
  # ruby_llm-shaped payloads so the reducer is exercised, not bypassed.
  class SpyAgent
    attr_reader :seen_prompt, :closed, :sandbox, :read_back

    def initialize(sandbox: nil, **)
      @sandbox = sandbox
      @closed = false
    end

    def prompt(text, max_turns: 25)
      @seen_prompt = text
      # Reads from the SHARED sandbox — the file the workflow staged.
      @read_back = @sandbox.read("baseline.md")
      if block_given?
        yield(:tool_call, RubyLLM::ToolCall.new(id: "1", name: "read_file", arguments: {"path" => "baseline.md"}))
        yield(:tool_result, @read_back) # a bare String result, like a successful read
        yield(:done, Struct.new(:content).new("REVIEW OK"))
      end
      Struct.new(:content).new("REVIEW OK")
    end

    def close = (@closed = true)
  end

  class DrivenWorkflow < Nexo::Workflow
    agent SpyAgent

    def call(_payload)
      stage({"baseline.md" => "code here"})
      resp = run_agent("Review the baseline")
      artifact("review.md", content: resp.content)
      {content: resp.content}
    end
  end

  # A workflow with no `agent` declared must raise ConfigurationError from run_agent.
  class UndeclaredWorkflow < Nexo::Workflow
    def call(_payload) = run_agent("go")
  end

  def test_run_agent_shares_sandbox_forwards_events_and_returns_response
    run = DrivenWorkflow.run

    assert_equal "done", run.status
    assert_equal "REVIEW OK", run.result["content"]

    types = run.events.map { |e| e["type"] || e[:type] }
    assert_includes types, "agent_tool_call"
    assert_includes types, "agent_tool_result"
    assert_includes types, "agent_done"

    # The artifact captured from the agent response.
    assert(run.artifacts.any? { |a| (a["name"] || a[:name]) == "review.md" })
  end

  def test_reducer_keeps_json_safe_fields_per_event_type
    run = DrivenWorkflow.run
    by_type = run.events.each_with_object({}) { |e, h| h[e["type"]] = e["data"] }

    tc = by_type["agent_tool_call"]
    assert_equal "read_file", tc["name"] || tc[:name]
    assert_equal({"path" => "baseline.md"}, tc["args"] || tc[:args])

    tr = by_type["agent_tool_result"]
    assert_equal true, tr["ok"] || tr[:ok]
    assert_equal "code here", tr["content"] || tr[:content]

    assert_equal "REVIEW OK", (by_type["agent_done"]["content"] || by_type["agent_done"][:content])
  end

  def test_agent_reads_shared_sandbox_and_is_closed
    # Capture the spy instance the glue built so we can assert its recorded state.
    built = nil
    original = SpyAgent.method(:new)
    SpyAgent.define_singleton_method(:new) do |**kwargs|
      built = original.call(**kwargs)
    end

    DrivenWorkflow.run

    assert_equal "code here", built.read_back, "agent read the staged file from the shared sandbox"
    assert_equal "Review the baseline", built.seen_prompt
    assert built.closed, "agent#close was called in the ensure"
  ensure
    SpyAgent.singleton_class.send(:remove_method, :new)
  end

  def test_run_agent_without_declared_agent_raises_configuration_error
    error = assert_raises(Nexo::ConfigurationError) { UndeclaredWorkflow.run }
    assert_match(/has no `agent` declared/, error.message)
    assert_match(/add `agent MyAgent`/, error.message)
  end
end
