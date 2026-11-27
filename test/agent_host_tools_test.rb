# frozen_string_literal: true

require "test_helper"

# 0.14: host-written tools get the same gate as Nexo's own, and a tool the host
# attaches outside the `tools` macro is caught by the backstop. All through
# ruby_llm's real loop, with only the model's replies scripted.
class AgentHostToolsTest < Minitest::Test
  class Today < RubyLLM::Tool
    description "Today's date"

    def execute = "2026-11-26"
  end

  class Archive < RubyLLM::Tool
    description "Archive a run"
    parameter :run, type: :string, description: "The run id"

    def self.calls = (@calls ||= [])

    def execute(run:)
      self.class.calls << run
      "archived #{run}"
    end
  end

  class Rooted < RubyLLM::Tool
    description "Reports the agent's cwd"

    def initialize(root:)
      @root = root
      super()
    end

    def execute = @root
  end

  TODAY = :"agent_host_tools_test--today"
  ARCHIVE = :"agent_host_tools_test--archive"

  class ReadOnly < Nexo::Agent
    model "gpt-4o-mini"
    tools Today
    tools Archive, capability: :write
  end

  class CanWrite < ReadOnly
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
  end

  class Asking < ReadOnly
    permissions Nexo::Permissions.new(mode: :ask, on_ask: ->(_cap, detail) { detail.include?("keep") })
  end

  class Approving < ReadOnly
    permissions Nexo::Permissions.new(mode: :approve)
  end

  class WithLambda < Nexo::Agent
    model "gpt-4o-mini"
    tools ->(agent) { Rooted.new(root: agent.cwd) }
  end

  # The pattern 0.14 replaces: a tool attached in a `chat` override.
  class Undeclared < Nexo::Agent
    model "gpt-4o-mini"

    def chat(base: nil)
      super.with_tools(Archive.new)
    end
  end

  def setup
    skip "scripts the model; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    Archive.calls.clear
  end

  def teardown = Nexo.reset_config!

  def test_declarations_accumulate_and_inherit_without_leaking_to_the_parent
    assert_equal [Today, Archive], ReadOnly.tools.map { |entry| entry[:tool] }
    assert_equal [nil, :write], CanWrite.tools.map { |entry| entry[:capability] }
    assert_empty Nexo::Agent.tools
  end

  def test_a_gated_tool_the_mode_can_never_allow_is_not_advertised
    names = ReadOnly.new.chat.tools.keys

    assert_includes names, TODAY
    refute_includes names, ARCHIVE
  end

  def test_an_ungated_tool_runs
    stub_replies tool_call(TODAY), "It is the 26th."
    results = []

    ReadOnly.new.prompt("What day is it?") { |type, payload| results << payload if type == :tool_result }

    assert_equal ["2026-11-26"], results
  end

  def test_a_gated_tool_runs_when_the_capability_is_granted
    stub_replies tool_call(ARCHIVE, run: "r1"), "Archived."

    CanWrite.new.prompt("Archive r1")

    assert_equal ["r1"], Archive.calls
  end

  def test_a_gated_tool_is_decided_per_call_under_ask
    stub_replies tool_call(ARCHIVE, run: "keep-1"), tool_call(ARCHIVE, run: "drop-2"), "Done."
    results = []

    Asking.new.prompt("Archive both") { |type, payload| results << payload if type == :tool_result }

    assert_equal ["keep-1"], Archive.calls
    assert_equal "archived keep-1", results[0]
    assert_match(/denied by user/, results[1][:error])
  end

  def test_a_gated_tool_raises_approval_required_under_approve
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."

    error = assert_raises(Nexo::ApprovalRequired) { Approving.new.prompt("Archive r1") }

    assert_equal :write, error.capability
    assert_match(/archive.*r1/, error.detail)
    assert_empty Archive.calls
  end

  def test_a_lambda_builds_the_tool_from_the_agent
    stub_replies tool_call(:"agent_host_tools_test--rooted"), "ok"
    results = []

    WithLambda.new(cwd: "/tmp/somewhere").prompt("Where?") { |type, payload| results << payload if type == :tool_result }

    assert_equal ["/tmp/somewhere"], results
  end

  def test_an_undeclared_tool_runs_with_one_warning_by_default
    stub_replies tool_call(ARCHIVE, run: "r1"), tool_call(ARCHIVE, run: "r2"), "Done."
    Nexo.instance_variable_get(:@undeclared_tools).clear

    _out, err = capture_io { Undeclared.new.prompt("Archive") }

    assert_equal %w[r1 r2], Archive.calls
    assert_equal 1, err.scan("outside the `tools` macro").size
  end

  def test_an_undeclared_tool_is_refused_under_strict_tools
    Nexo.config.strict_tools = true
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."
    results = []

    _out, err = capture_io do
      Undeclared.new.prompt("Archive") { |type, payload| results << payload if type == :tool_result }
    end

    assert_empty Archive.calls
    assert_match(/did not run/, results.first[:error])
    refute_match(/tools. macro/, err, "refusing is the signal; no warning on top")
  end

  def test_strict_tools_lets_every_tool_nexo_attached_through
    Nexo.config.strict_tools = true
    agent = CanWrite.new
    agent.sandbox.write("a.txt", "A")
    stub_replies tool_call(:"nexo--tools--read_file", path: "a.txt"), tool_call(TODAY), tool_call(ARCHIVE, run: "r1"), "Done."
    results = []

    agent.prompt("Go") { |type, payload| results << payload if type == :tool_result }

    assert_equal ["A", "2026-11-26", "archived r1"], results
  end

  def test_the_backstop_is_registered_once_on_a_reused_chat
    agent = CanWrite.new
    chat = agent.chat
    agent.chat(base: chat)
    stub_replies tool_call(ARCHIVE, run: "r1"), "Done."

    chat.ask("Archive")

    assert_equal ["r1"], Archive.calls
  end
end
