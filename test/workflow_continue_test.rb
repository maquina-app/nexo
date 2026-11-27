# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# 0.17 — a resume carries the paused conversation on instead of asking the
# prompt again: the held call runs, a tool that already ran does not run twice,
# and the model is asked only for what comes next. Through ruby_llm's real loop.
class WorkflowContinueTest < Minitest::Test
  # A tool with a side effect and no gate: it must run exactly once.
  class Charge < RubyLLM::Tool
    description "Charges a card"
    parameter :cents, type: :integer, description: "Amount"

    def self.calls = (@calls ||= [])

    def execute(cents:)
      self.class.calls << cents
      "charged #{cents}"
    end
  end

  class Ship < RubyLLM::Tool
    description "Ships an order"
    parameter :order, type: :string, description: "Order"

    def self.calls = (@calls ||= [])

    def execute(order:)
      self.class.calls << order
      "shipped #{order}"
    end
  end

  class Gift < RubyLLM::Tool
    description "Adds a gift note after asking what it should say"

    def execute = "note: #{ask("What should the note say?")}"
  end

  CHARGE = :"workflow_continue_test--charge"
  SHIP = :"workflow_continue_test--ship"
  GIFT = :"workflow_continue_test--gift"

  class Clerk < Nexo::Agent
    model "gpt-4o-mini"
    permissions :approve
    tools Charge, Gift
    tools Ship, capability: :write
  end

  class Fulfil < Nexo::Workflow
    agent Clerk

    def call(_payload) = {"said" => run_agent("Charge and ship order 7").content}
  end

  def setup
    skip "scripted replies; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    Nexo::RunStore::Memory.reset!
    Charge.calls.clear
    Ship.calls.clear
  end

  def teardown = Nexo.reset_config!

  def test_a_tool_that_ran_before_the_pause_does_not_run_again
    stub_replies tool_call(CHARGE, cents: 500), tool_call(SHIP, order: "7"), "All done."
    run = Fulfil.run

    assert_equal "suspended", run.status
    assert_equal [500], Charge.calls
    assert_kind_of Array, run.state["__chat__"]["messages"], "the conversation is saved with the run"

    stub_replies "All done." # only what comes after the held call is asked for
    run = Nexo::Workflow.resume(run.id, approved: true)

    assert_equal "done", run.status, run.error.to_s
    assert_equal [500], Charge.calls, "charged once across the suspend and the resume"
    assert_equal ["7"], Ship.calls
    assert_equal "All done.", run.result["said"]
    refute run.state.key?("__chat__"), "dropped once the prompt finished"
  end

  def test_a_declined_call_is_refused_and_the_model_carries_on
    stub_replies tool_call(CHARGE, cents: 500), tool_call(SHIP, order: "7"), "Not shipped."
    run = Fulfil.run
    stub_replies "Not shipped."

    run = Nexo::Workflow.resume(run.id, approved: false)

    assert_equal "done", run.status
    assert_equal [500], Charge.calls
    assert_empty Ship.calls
  end

  def test_a_question_is_answered_without_asking_the_model_again
    stub_replies tool_call(CHARGE, cents: 500), tool_call(GIFT), "Wrapped."
    run = Fulfil.run

    assert_equal "suspended", run.status
    key = run.state["__input__"].first["key"]
    stub_replies "Wrapped."
    run = Nexo::Workflow.resume(run.id, answers: {key => "Happy birthday"})

    assert_equal "done", run.status, run.error.to_s
    assert_equal [500], Charge.calls
    assert_equal "Wrapped.", run.result["said"]
  end

  def test_it_survives_a_run_store_on_disk
    Dir.mktmpdir do |dir|
      Nexo.configure { |c| c.run_store = Nexo::RunStore::Disk.new(dir: dir) }
      stub_replies tool_call(CHARGE, cents: 500), tool_call(SHIP, order: "7"), "All done."
      run = Fulfil.run
      stub_replies "All done."

      run = Nexo::Workflow.resume(run.id, approved: true)

      assert_equal "done", run.status, run.error.to_s
      assert_equal [500], Charge.calls
      assert_equal ["7"], Ship.calls
    end
  end

  # A run suspended by 0.16 has no saved conversation: the prompt is asked again.
  def test_without_a_saved_conversation_the_prompt_is_asked_again
    stub_replies tool_call(SHIP, order: "7"), "All done."
    run = Fulfil.run
    run.update!(state: run.state.except("__chat__"))
    stub_replies tool_call(SHIP, order: "7"), "All done."

    run = Nexo::Workflow.resume(run.id, approved: true)

    assert_equal "done", run.status
    assert_equal ["7"], Ship.calls
  end

  def test_a_direct_caller_continues_with_the_transcript
    stub_replies tool_call(CHARGE, cents: 500), tool_call(SHIP, order: "7"), "All done."
    error = assert_raises(Nexo::ApprovalRequired) { Clerk.new.prompt("go") }
    stub_replies "All done."

    response = Clerk.new(decisions: {error.key => true}).prompt("go", continue: error.transcript)

    assert_equal "All done.", response.content
    assert_equal [500], Charge.calls
    assert_equal ["7"], Ship.calls
  end
end
