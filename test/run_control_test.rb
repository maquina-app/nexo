# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# 0.16 — observing and controlling a run: what it used, stopping it, a tool's
# progress, a tool that ends the turn, and deferred tools of your own.
class RunControlTest < Minitest::Test
  class Slow < RubyLLM::Tool
    description "Works in two steps"

    def execute
      progress "half way", value: 1, total: 2
      "finished"
    end
  end

  class File < RubyLLM::Tool
    description "Files a ticket and ends the turn"
    parameter :category, type: :string

    def execute(category:) = halt("Filed as #{category}")
  end

  class Worker < Nexo::Agent
    model "gpt-4o-mini"
    tools Slow
    tools File, capability: :write
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
  end

  SLOW = :"run_control_test--slow"
  FILE = :"run_control_test--file"

  class Flow < Nexo::Workflow
    agent Worker

    class << self
      attr_accessor :between
    end

    def call(_payload)
      first = run_agent("one").content
      self.class.between&.call(@run)
      checkpoint("after") { "checkpointed" }
      {first: first, second: run_agent("two").content}
    end
  end

  def setup
    skip "scripts the model; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    Nexo::RunStore::Memory.reset!
    Flow.between = nil
  end

  def teardown = Nexo.reset_config!

  # --- usage -------------------------------------------------------------------

  def test_a_prompt_reports_the_tokens_it_used_once_even_when_it_raises
    stub_replies tool_call(SLOW), "done"
    events = []
    Worker.new.prompt("go") { |type, payload| events << [type, payload] }

    usage = events.filter_map { |type, payload| payload if type == :usage }
    assert_equal 1, usage.size
    assert_operator usage.first[:tokens][:input_tokens], :>, 0
    assert_equal :usage, events.last.first, "after :done"

    stub_replies tool_call(SLOW) # repeats for ever
    failed = []
    assert_raises(RubyLLM::ToolRoundLimitError) { Worker.new.prompt("loop", max_turns: 2) { |type, _| failed << type } }
    assert_equal 1, failed.count(:usage)
  end

  def test_a_run_totals_what_its_agents_used
    stub_replies "first", "second"

    run = Flow.run
    usage = Nexo::Workflow.usage(run)

    assert_equal 2, usage["prompts"]
    assert_operator usage["tokens"]["input_tokens"], :>, 0
    assert_equal 2, run.events.count { |event| event["type"] == "agent_usage" }
    assert_equal({"tokens" => {}, "cost" => nil, "prompts" => 0}, Nexo::Workflow.usage(Struct.new(:events).new([])))
  end

  # 0.16.1: a workflow that prompts its agents itself logs their events the
  # way run_agent does, and may tag them.
  class SelfDriven < Nexo::Workflow
    def call(_payload)
      agent = Worker.new(sandbox: sandbox)
      agent.prompt("go", cancel: -> { cancel_requested? }) { |type, payload| emit_agent_event(type, payload, source: "worker") }
      {}
    ensure
      agent&.close
    end
  end

  def test_a_self_driven_agent_logs_events_usage_can_total
    stub_replies tool_call(SLOW), "done"

    run = SelfDriven.run

    assert_equal "done", run.status, run.error.to_s
    assert_equal 1, Nexo::Workflow.usage(run)["prompts"]
    assert_operator Nexo::Workflow.usage(run)["tokens"]["input_tokens"], :>, 0
    call = run.events.find { |event| event["type"] == "agent_tool_call" }
    assert_equal "worker", call["data"]["source"]
    assert call["data"]["name"], "reduced to plain data"
  end

  def test_cost_is_nil_when_any_prompt_had_no_price
    run = Struct.new(:events).new([
      {"type" => "agent_usage", "data" => {"tokens" => {"input_tokens" => 10}, "cost" => 0.5}},
      {"type" => "agent_usage", "data" => {"tokens" => {"input_tokens" => 5}, "cost" => nil}}
    ])

    assert_equal({"tokens" => {"input_tokens" => 15}, "cost" => nil, "prompts" => 2}, Nexo::Workflow.usage(run))
    run.events.pop
    assert_in_delta 0.5, Nexo::Workflow.usage(run)["cost"]
  end

  # --- progress, halt, fallback ------------------------------------------------

  def test_a_tools_progress_reaches_the_event_block_and_the_run_log
    stub_replies tool_call(SLOW), "done", "second"

    run = Flow.run
    progress = run.events.find { |event| event["type"] == "agent_tool_progress" }

    assert_equal({"name" => SLOW.to_s, "message" => "half way", "value" => 1, "total" => 2}, progress["data"])
  end

  def test_a_gated_tool_can_end_the_turn
    agent = Worker.new
    stub_replies tool_call(FILE, category: "billing"), "never reached"
    events = []

    response = agent.prompt("File it") { |type, payload| events << [type, payload] }

    assert_equal "Filed as billing", response.content
    assert_equal :tool, response.role
    assert_equal "Filed as billing", events.find { |type, _| type == :tool_result }.last
  end

  def test_a_fallback_is_reduced_to_plain_data
    fallback = Struct.new(:from, :to, :error, :fallback_error).new(
      Struct.new(:id).new("big"), Struct.new(:id).new("small"), RuntimeError.new("overloaded"), nil
    )

    reduced = Flow.new(Nexo::RunStore::Memory.new.create(workflow_class: "X", payload: {})).send(:serializable, :fallback, fallback)

    assert_equal({"from" => "big", "to" => "small", "error" => "overloaded", "failed" => false}, reduced)
  end

  # --- deferred tools of your own ----------------------------------------------

  def test_declared_tools_can_be_deferred_and_stay_gated
    klass = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      tools Slow, defer: true
      tools File, capability: :write, defer: true
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
    end
    chat = klass.new.chat

    assert_equal [FILE, SLOW], chat.deferred_tools.keys.sort
    assert_kind_of Nexo::GatedTool, chat.tools[FILE]
    refute_includes chat.deferred_tools.keys, :read_file
  end

  # --- cancel ------------------------------------------------------------------

  def test_a_run_cancelled_between_steps_stops_at_the_next_checkpoint
    stub_replies "first", "second"
    Flow.between = ->(run) { Nexo::Workflow.cancel(run.id) }

    run = Flow.run

    assert_equal "cancelled", run.status
    assert_nil run.result
    refute run.state.key?("after"), "the checkpoint after the request did not run"
    assert_equal 1, run.events.count { |event| event["type"] == "agent_done" }
    refute Nexo::RunStore.default.cancel_requested?(run), "the request is forgotten once the run stopped"
  end

  def test_a_cancel_during_an_agents_tool_loop_stops_the_agent
    stub_replies tool_call(SLOW) # the model would ask for ever
    cancelled = false
    workflow = Class.new(Nexo::Workflow) do
      agent Worker
      define_method(:call) { |_payload| {content: run_agent("loop", max_turns: 50).content} }
      define_method(:emit) do |type, data = {}|
        if type == :agent_tool_result && !cancelled
          cancelled = true
          Nexo::Workflow.cancel(@run.id)
        end
        super(type, data)
      end
    end
    Object.const_set(:CancelLoopFlow, workflow)

    run = CancelLoopFlow.run

    assert_equal "cancelled", run.status
    assert_operator run.events.count { |event| event["type"] == "agent_tool_call" }, :<=, 2
    assert_equal 1, run.events.count { |event| event["type"] == "agent_usage" }, "what it used is still recorded"
  ensure
    Object.send(:remove_const, :CancelLoopFlow) if Object.const_defined?(:CancelLoopFlow)
  end

  def test_a_run_that_is_not_executing_is_cancelled_at_once_and_never_started
    store = Nexo::RunStore.default
    queued = store.create(workflow_class: Flow.name, payload: {})
    queued.update!(status: "queued")

    assert_equal "cancelled", Nexo::Workflow.cancel(queued.id).status
    assert_equal "cancelled", Flow.execute(queued, payload: {}).status
    assert_empty queued.events
  end

  def test_a_finished_or_cancelled_run_cannot_be_cancelled_resumed_or_retried
    stub_replies "first", "second"
    done = Flow.run
    Flow.between = ->(run) { Nexo::Workflow.cancel(run.id) }
    stub_replies "first", "second"
    cancelled = Flow.run

    assert_raises(Nexo::Error) { Nexo::Workflow.cancel(done.id) }
    assert_raises(Nexo::Error) { Nexo::Workflow.cancel(cancelled.id) }
    assert_raises(Nexo::Error) { Flow.resume(cancelled.id) }
    assert_raises(Nexo::Error) { Flow.retry(cancelled.id) }
  end

  def test_the_disk_store_carries_a_cancel_request_between_processes
    Dir.mktmpdir do |dir|
      Nexo.config.run_store = Nexo::RunStore::Disk.new(dir: dir)
      run = Nexo::RunStore.default.create(workflow_class: Flow.name, payload: {})
      run.update!(status: "running")

      Nexo::Workflow.cancel(run.id)
      other_process = Nexo::RunStore::Disk.new(dir: dir)

      assert other_process.cancel_requested?(other_process.find(run.id))
      assert_equal "running", other_process.find(run.id).status, "the worker's document is not touched"
      other_process.clear_cancel!(run)
      refute Nexo::RunStore.default.cancel_requested?(run)
    end
  end
end
