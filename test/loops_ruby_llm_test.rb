# frozen_string_literal: true

require "test_helper"

# The default, provider-neutral loop. Wiring is asserted against the
# ruby_llm-test fake provider (no network, deterministic), plus a hand-built
# fake chat for the tool-callback observability which the fake provider does not
# itself drive.
class LoopsRubyLLMTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  class VirtualAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :virtual
    # :write is granted so WriteFile is actually attached. Under the default
    # :read_only gate it is statically denied and therefore correctly left out
    # of the schema — this test is about the LOOP's wiring, not about gating.
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
  end

  # A minimal chat double that records the observability callbacks and lets a
  # test fire them, standing in for ruby_llm's before_tool_call/after_tool_result.
  class FakeChat
    attr_reader :asked

    def before_tool_call(&block)
      @before = block
    end

    def after_tool_result(&block)
      @after = block
    end

    def ask(prompt)
      @asked = prompt
      "final response"
    end

    def fire_tool_call(tc) = @before&.call(tc)

    def fire_tool_result(r) = @after&.call(r)
  end

  # An agent stand-in exposing only what the loop touches: #chat.
  FakeAgent = Struct.new(:chat)

  def setup
    skip "loop wiring tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    RubyLLM::Test.reset
  end

  def teardown
    Nexo.reset_config!
  end

  # Regression: a default-loop agent still attaches its sandbox-backed tools and
  # #prompt returns the response. The :virtual sandbox has no shell, so Shell is
  # gated out (Spec 14 R2); the other three attach because the fixture grants
  # :write on top of the read/glob default.
  def test_default_loop_agent_attaches_tools_and_prompt_returns
    RubyLLM::Test.stub_response("review complete")
    agent = VirtualAgent.new

    assert_instance_of Nexo::Loops::RubyLLM, agent.loop

    tool_classes = agent.chat.tools.values.map(&:class)
    assert_includes tool_classes, Nexo::Tools::ReadFile
    assert_includes tool_classes, Nexo::Tools::WriteFile
    assert_includes tool_classes, Nexo::Tools::Glob
    refute_includes tool_classes, Nexo::Tools::Shell

    response = agent.prompt("Review it")
    assert_equal "review complete", response.content
  end

  def test_on_event_receives_done_with_the_response
    RubyLLM::Test.stub_response("all done")
    events = []

    response = VirtualAgent.new.prompt("Go") { |type, payload| events << [type, payload] }

    assert_includes events, [:done, response]
  end

  # before_tool_call/after_tool_result are observability-only (confirmed present
  # on ruby_llm 1.16.0). Drive them through a fake chat to assert the loop
  # forwards :tool_call/:tool_result.
  def test_on_event_forwards_tool_call_and_tool_result_when_tools_fire
    chat = FakeChat.new
    events = []

    response = Nexo::Loops::RubyLLM.new.run(agent: FakeAgent.new(chat), prompt: "Do it") do |type, payload|
      events << [type, payload]
    end
    chat.fire_tool_call(:a_tool_call)
    chat.fire_tool_result(:a_tool_result)

    assert_equal "final response", response
    assert_equal "Do it", chat.asked
    assert_includes events, [:tool_call, :a_tool_call]
    assert_includes events, [:tool_result, :a_tool_result]
    assert_includes events, [:done, "final response"]
  end

  # A chat lacking the callbacks (older/newer ruby_llm) degrades to no
  # observability rather than crashing.
  def test_loop_degrades_without_tool_callbacks
    bare = Class.new {
      def ask(_prompt) = "ok"
    }.new
    events = []

    response = Nexo::Loops::RubyLLM.new.run(agent: FakeAgent.new(bare), prompt: "x") do |type, payload|
      events << [type, payload]
    end

    assert_equal "ok", response
    assert_equal [[:done, "ok"]], events
  end

  # max_turns cannot HALT this loop — ruby_llm runs the whole tool loop inside #ask
  # and its callbacks are observation-only. It was previously accepted and never read,
  # which read as a safety bound it has never been. It is now counted and reported.
  def test_exceeding_max_turns_emits_a_single_event
    chat = FakeChat.new
    events = []
    Nexo::Loops::RubyLLM.new.run(agent: FakeAgent.new(chat), prompt: "go", max_turns: 2) do |type, payload|
      events << [type, payload]
    end
    4.times { |i| chat.fire_tool_call("call-#{i}") }

    exceeded = events.filter_map { |event| event.last if event.first == :turn_limit_exceeded }

    assert_equal 1, exceeded.size
    assert_equal({turns: 3, max_turns: 2}, exceeded.first)
  end

  def test_staying_within_max_turns_emits_nothing
    chat = FakeChat.new
    events = []
    Nexo::Loops::RubyLLM.new.run(agent: FakeAgent.new(chat), prompt: "go", max_turns: 5) do |type, payload|
      events << [type, payload]
    end
    3.times { |i| chat.fire_tool_call("call-#{i}") }

    refute_includes events.map(&:first), :turn_limit_exceeded
  end

  # A continuing Session runs the loop repeatedly over ONE chat; each prompt gets its
  # own budget rather than inheriting the previous prompt's count.
  def test_the_turn_count_resets_per_prompt
    chat = FakeChat.new
    loop_runner = Nexo::Loops::RubyLLM.new
    events = []
    collect = ->(type, payload) { events << [type, payload] }

    loop_runner.run(agent: FakeAgent.new(chat), prompt: "one", max_turns: 2, &collect)
    2.times { |i| chat.fire_tool_call("a-#{i}") }
    loop_runner.run(agent: FakeAgent.new(chat), prompt: "two", max_turns: 2, chat: chat, &collect)
    2.times { |i| chat.fire_tool_call("b-#{i}") }

    refute_includes events.map(&:first), :turn_limit_exceeded
  end

  def test_tool_call_observability_still_fires
    chat = FakeChat.new
    events = []
    Nexo::Loops::RubyLLM.new.run(agent: FakeAgent.new(chat), prompt: "go", max_turns: 1) do |type, payload|
      events << [type, payload]
    end
    chat.fire_tool_call("tc")

    assert_includes events, [:tool_call, "tc"]
  end
end
