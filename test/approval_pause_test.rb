# frozen_string_literal: true

require "test_helper"

# 0.16 — an `:approve` gate pauses through ruby_llm's own approval mechanism
# (Nexo::Approvable): the model's call is held BEFORE the tool is entered, the
# loop raises Nexo::ApprovalRequired, and a recorded decision runs the call or
# has ruby_llm refuse it. Driven through ruby_llm's real loop.
class ApprovalPauseTest < Minitest::Test
  # A host tool with a catch-all handler: before 0.16 it swallowed the approval
  # signal, because the signal was an exception raised inside the tool.
  class Archive < RubyLLM::Tool
    description "Archive a run"
    parameter :run, type: :string, description: "The run id"
    rescue_from(StandardError) { |error| {error: "handled: #{error.message}"} }

    def self.calls = (@calls ||= [])

    def execute(run:)
      self.class.calls << run
      "archived #{run}"
    end
  end

  # A host tool that asks for approval the ruby_llm way, with no Nexo capability.
  class Wipe < RubyLLM::Tool
    description "Wipes a cache"
    parameter :name, type: :string, description: "The cache"
    requires_approval

    def self.calls = (@calls ||= [])

    def execute(name:)
      self.class.calls << name
      "wiped #{name}"
    end
  end

  ARCHIVE = :"approval_pause_test--archive"
  WIPE = :"approval_pause_test--wipe"

  class Careful < Nexo::Agent
    model "gpt-4o-mini"
    permissions :approve
    tools Archive, capability: :write
    tools Wipe
  end

  class Flow < Nexo::Workflow
    agent Careful

    def call(_payload) = {"said" => run_agent("Archive r1").content}
  end

  def setup
    skip "scripted replies; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo::RunStore::Memory.reset!
    Archive.calls.clear
    Wipe.calls.clear
  end

  def results_of(agent, prompt = "Go")
    results = []
    agent.prompt(prompt) { |type, payload| results << payload if type == :tool_result }
    results
  end

  def test_an_undecided_call_pauses_before_the_tool_is_entered
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."

    error = assert_raises(Nexo::ApprovalRequired) { Careful.new.prompt("Archive r1") }

    assert_equal :write, error.capability
    assert_empty Archive.calls
    assert_equal [error.key], error.pending.map { |call| call["key"] }
    assert_equal "write", error.pending.first["capability"]
  end

  def test_a_catch_all_handler_on_the_tool_no_longer_swallows_the_pause
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    events = []

    assert_raises(Nexo::ApprovalRequired) { Careful.new.prompt("Archive r1") { |type, _| events << type } }

    refute_includes events, :tool_result, "the tool's rescue_from handler never saw a call"
  end

  def test_an_approved_call_runs
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    key = begin
      Careful.new.prompt("Archive r1")
    rescue Nexo::ApprovalRequired => e
      e.key
    end
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."

    results = results_of(Careful.new(decisions: {key => true}))

    assert_equal ["archived r1"], results
    assert_equal ["r1"], Archive.calls
  end

  def test_a_declined_call_is_refused_by_ruby_llm_and_the_model_carries_on
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    key = Nexo::ApprovalRequired.new(*Careful.new.chat.tools[ARCHIVE].approval_subject({run: "r1"})).key
    events = []

    response = Careful.new(decisions: {key => false}).prompt("Archive r1") { |type, _| events << type }

    assert_empty Archive.calls
    refute_includes events, :tool_call, "ruby_llm answers a declined call itself: the tool is never entered"
    assert_equal "Done.", response.content
  end

  def test_a_decision_for_one_call_does_not_cover_another
    key = Nexo::ApprovalRequired.new(*Careful.new.chat.tools[ARCHIVE].approval_subject({run: "r1"})).key
    stub_replies tool_call(ARCHIVE, run: "r2"), "Done."

    assert_raises(Nexo::ApprovalRequired) { Careful.new(decisions: {key => true}).prompt("Archive r2") }
    assert_empty Archive.calls
  end

  def test_a_tool_declared_with_requires_approval_is_decided_the_same_way
    stub_replies tool_call(WIPE, name: "pages"), "Done."

    error = assert_raises(Nexo::ApprovalRequired) { Careful.new.prompt("Wipe pages") }

    assert_equal :tool, error.capability
    assert_empty Wipe.calls

    stub_replies tool_call(WIPE, name: "pages"), "Done."
    results = results_of(Careful.new(decisions: {error.key => true}))

    assert_equal ["wiped pages"], results
  end

  def test_a_workflow_suspends_lists_what_waits_and_resumes_by_key
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    run = Flow.run

    assert_equal "suspended", run.status
    pending = run.state["__approvals_pending__"]
    assert_equal ["write"], pending.map { |call| call["capability"] }
    assert_equal "write", run.state["__approval__"]["capability"]
    refute run.state["__approval__"].key?("key")

    stub_replies "Done." # the held call carries on; the model is asked only for what follows
    run = Nexo::Workflow.resume(run.id, approvals: {pending.first["key"] => true})

    assert_equal "done", run.status
    assert_equal ["r1"], Archive.calls
  end

  def test_a_key_that_was_not_pending_approves_nothing
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    run = Flow.run
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."

    run = Nexo::Workflow.resume(run.id, approvals: {"write:something else" => true})

    assert_equal "suspended", run.status
    assert_empty Archive.calls
  end

  def test_approved_true_still_answers_the_first_pending_call
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    run = Flow.run
    stub_replies "Done."

    run = Nexo::Workflow.resume(run.id, approved: true)

    assert_equal "done", run.status
    assert_equal ["r1"], Archive.calls
  end

  # --- 0.17 --------------------------------------------------------------------

  def test_a_declined_call_is_reported_once
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    key = Nexo::ApprovalRequired.new(*Careful.new.chat.tools[ARCHIVE].approval_subject({run: "r1"})).key
    events = []

    Careful.new(decisions: {key => false}).prompt("Archive r1") { |type, payload| events << [type, payload] }

    declined = events.select { |type, _| type == :tool_declined }
    assert_equal 1, declined.size
    assert_equal "archive", declined.first.last.name.to_s.split("--").last
    assert_empty Archive.calls
  end

  def test_a_workflow_logs_the_declined_call
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    run = Flow.run
    stub_replies "Done."

    run = Nexo::Workflow.resume(run.id, approved: false)

    declined = run.events.select { |event| event["type"] == "agent_tool_declined" }
    assert_equal 1, declined.size
    assert_equal({"run" => "r1"}, declined.first["data"]["args"])
  end

  # `detail:` says what identifies a call, so a free-text argument does not make
  # each attempt a new one.
  class Refund < RubyLLM::Tool
    description "Refunds an order"
    parameter :order, type: :string, description: "Order"
    parameter :reason, type: :string, description: "Why"

    def self.calls = (@calls ||= [])

    def execute(order:, reason:) = (self.class.calls << order) && "refunded #{order}"
  end

  class Cashier < Nexo::Agent
    model "gpt-4o-mini"
    permissions :approve
    tools Refund, capability: :write, detail: ->(arguments) { "refund #{arguments[:order]}" }
  end

  def test_detail_decides_what_identifies_a_call
    refund = :"approval_pause_test--refund"
    stub_replies tool_call(refund, order: "A-1", reason: "cracked on arrival"), "Done."
    error = assert_raises(Nexo::ApprovalRequired) { Cashier.new.prompt("refund") }

    assert_equal "write:refund A-1", error.key

    stub_replies tool_call(refund, order: "A-1", reason: "the panel was cracked"), "Done." # worded differently
    Cashier.new(decisions: {error.key => true}).prompt("refund")

    assert_equal ["A-1"], Refund.calls
  ensure
    Refund.calls.clear
  end

  def test_detail_needs_a_capability
    assert_raises(Nexo::ConfigurationError) { Class.new(Nexo::Agent) { tools Refund, detail: ->(_) { "x" } } }
  end

  def test_a_remembered_approval_covers_later_calls_of_that_kind
    stub_replies tool_call(ARCHIVE, run: "r1"), tool_call(ARCHIVE, run: "r2"), "Done."

    Careful.new(decisions: {"write:*" => true}).prompt("Archive both")

    assert_equal %w[r1 r2], Archive.calls
  end

  def test_an_exact_decision_wins_over_a_remembered_one
    gate = Nexo::Permissions.new(mode: :approve, decisions: {"write:*" => true, "write:secret.md" => false})

    assert_equal true, gate.decision_for(:write, "public.md")
    assert_equal false, gate.decision_for(:write, "secret.md")
    assert_equal "mcp:send_email:*", Nexo::Permissions.remembered_key(:mcp, "send_email")
  end

  def test_resume_with_remember_stops_asking_for_that_kind
    stub_replies tool_call(ARCHIVE, run: "r1"), tool_call(ARCHIVE, run: "r2"), "Done."
    run = Flow.run
    stub_replies tool_call(ARCHIVE, run: "r2"), "Done."

    run = Nexo::Workflow.resume(run.id, approved: true, remember: true)

    assert_equal "done", run.status, run.error.to_s
    assert_equal %w[r1 r2], Archive.calls
  end

  # Several calls can wait at once (one model response, several tool calls).
  # The scripted model cannot produce that, so the loop's step is driven directly.
  def test_every_undecided_call_of_a_response_is_reported
    call = Struct.new(:name, :qualified_name, :arguments)
    question = Struct.new(:tool_call) do
      def approval? = true
    end
    chat = Careful.new.chat
    questions = [question.new(call.new("archive", ARCHIVE.to_s, {run: "a"})),
      question.new(call.new("archive", ARCHIVE.to_s, {run: "b"}))]

    error = assert_raises(Nexo::ApprovalRequired) do
      Nexo::Loops::RubyLLM.new.send(:require_approvals, Careful.new, chat, questions)
    end

    assert_equal 2, error.pending.size
    assert_equal error.key, error.pending.first["key"]
    refute_equal error.pending[0]["key"], error.pending[1]["key"]
  end
end
