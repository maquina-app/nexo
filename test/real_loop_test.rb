# frozen_string_literal: true

require "test_helper"

# End-to-end through ruby_llm's REAL conversation loop, with only the model's
# replies scripted (`stub_replies` + `tool_call`). Everything Nexo composes is
# live: tool lookup and keyword dispatch, the permission gate inside each tool,
# the before/after tool callbacks, the round cap, and exception propagation.
#
# These are the facts the rest of the suite assumes about ruby_llm 2.2 — proven
# here rather than asserted against hand-built doubles.
class RealLoopTest < Minitest::Test
  READ = :read_file
  WRITE = :write_file
  LIST = :list_files

  class Reader < Nexo::Agent
    model "gpt-4o-mini"
    sandbox :virtual
  end

  class Writer < Nexo::Agent
    model "gpt-4o-mini"
    sandbox :virtual
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
  end

  class Approver < Nexo::Agent
    model "gpt-4o-mini"
    sandbox :virtual
    permissions Nexo::Permissions.new(mode: :approve)
  end

  def setup
    skip "scripts the model; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    Nexo::RunStore::Memory.reset!
  end

  def teardown = Nexo.reset_config!

  def test_a_scripted_tool_call_runs_the_real_tool_and_reports_both_events
    agent = Reader.new
    agent.sandbox.write("notes.md", "hello from the sandbox")
    stub_replies tool_call(READ, path: "notes.md"), "The note says hello."
    events = []

    response = agent.prompt("Read the note") { |type, payload| events << [type, payload] }

    assert_equal "The note says hello.", response.content
    assert_equal %i[tool_call tool_result done], events.map(&:first)

    call = events[0].last
    assert_kind_of RubyLLM::ToolCall, call
    assert_equal READ.to_s, call.name
    assert_equal({path: "notes.md"}, call.arguments)
    assert_match(/hello from the sandbox/, events[1].last, "the result event is the tool's raw return value")
    assert_kind_of RubyLLM::Message, events[2].last
  end

  # Safe by default, proven on the real loop: a default (:read_only) agent is not
  # even offered the write tool, so a model that asks for it gets an error result
  # and nothing is written.
  def test_a_read_only_agent_cannot_reach_the_write_tool
    agent = Reader.new
    stub_replies tool_call(WRITE, path: "pwned.txt", content: "x"), "I could not write."
    results = []

    agent.prompt("Write a file") { |type, payload| results << payload if type == :tool_result }

    refute_includes agent.chat.tools.keys, WRITE
    assert_match(/no tool named/i, results.first[:error])
    assert_raises(Errno::ENOENT) { agent.sandbox.read("pwned.txt") }
  end

  def test_a_granted_write_goes_through_the_real_tool
    agent = Writer.new
    stub_replies tool_call(WRITE, path: "out.txt", content: "written"), "Done."

    agent.prompt("Write it")

    assert_equal "written", agent.sandbox.read("out.txt")
  end

  def test_max_turns_is_a_hard_cap_on_tool_rounds
    agent = Reader.new
    stub_replies tool_call(LIST) # the last reply repeats: an endless tool loop
    events = []

    assert_raises(RubyLLM::ToolRoundLimitError) do
      agent.prompt("Loop forever", max_turns: 3) { |type, payload| events << [type, payload] }
    end

    assert_equal 3, events.count { |type, _| type == :tool_call }, "exactly max_turns rounds ran"
    exceeded = events.filter_map { |type, payload| payload if type == :turn_limit_exceeded }
    assert_equal [{turns: 3, max_turns: 3}], exceeded, "reported once"
    refute_includes events.map(&:first), :done
  end

  def test_max_turns_nil_runs_uncapped
    agent = Reader.new
    stub_replies(*Array.new(30) { tool_call(LIST) }, "finally")

    response = agent.prompt("Many rounds", max_turns: nil)

    assert_equal "finally", response.content
  end

  # The :approve bridge depends on this: an exception raised inside a tool's
  # #execute propagates out of chat.ask (ruby_llm re-raises when no rescue_from
  # handler matches), so Workflow#run_agent can turn it into a durable suspend.
  def test_approval_required_propagates_out_of_the_real_loop
    stub_replies tool_call(WRITE, path: "x.txt", content: "y"), "Done."

    error = assert_raises(Nexo::ApprovalRequired) { Approver.new.prompt("Write it") }

    assert_equal :write, error.capability
  end

  class ApprovalWorkflow < Nexo::Workflow
    agent Approver

    def call(_payload) = {content: run_agent("Write it").content}
  end

  def test_run_agent_suspends_on_the_real_loop_and_resumes_approved
    stub_replies tool_call(WRITE, path: "x.txt", content: "y"), "Done."

    run = ApprovalWorkflow.run
    assert_equal "suspended", run.status
    assert_equal "write", run.state["__approval__"]["capability"]

    resumed = ApprovalWorkflow.resume(run.id, approved: true)
    assert_equal "done", resumed.status
    assert_equal({"content" => "Done."}, resumed.result)
  end

  # 0.14: on the real loop, approving one write does not approve a different one.
  def test_two_different_writes_each_ask_on_the_real_loop
    stub_replies tool_call(WRITE, path: "a.txt", content: "A"), tool_call(WRITE, path: "b.txt", content: "B"), "Done."

    run = ApprovalWorkflow.run
    assert_equal "a.txt", run.state["__approval__"]["tool"]

    run = ApprovalWorkflow.resume(run.id, approved: true)
    assert_equal "suspended", run.status
    assert_equal "b.txt", run.state["__approval__"]["tool"]

    run = ApprovalWorkflow.resume(run.id, approved: true)
    assert_equal "done", run.status
  end

  class ReadingWorkflow < Nexo::Workflow
    agent Reader

    def call(_payload)
      sandbox.write("notes.md", "hi")
      {content: run_agent("Read it").content}
    end
  end

  # Events from the real loop are stored string-keyed, so the Memory and
  # ActiveRecord run stores agree on their shape.
  def test_run_agent_events_from_the_real_loop_are_string_keyed
    stub_replies tool_call(READ, path: "notes.md"), "It says hi."

    run = ReadingWorkflow.run

    assert_equal "done", run.status
    call = run.events.find { |event| (event["type"] || event[:type]).to_s == "agent_tool_call" }
    data = call["data"] || call[:data]
    assert_equal({"name" => READ.to_s, "args" => {"path" => "notes.md"}}, data)
  end

  # An MCP tool wrapped in the gate, attached the way Agent#apply_mcp attaches it,
  # is dispatched by the real loop with keywords and denied before it runs.
  class RecordingMcpTool < RubyLLM::Tool
    attr_reader :calls

    def initialize(name)
      super()
      @name = name
      @calls = []
    end

    attr_reader :name

    def description = "records calls"

    def parameters_schema = {"type" => "object", "properties" => {"q" => {"type" => "string"}}}

    def call(**arguments)
      @calls << arguments.except(:tool_call)
      "ran #{@name}"
    end
  end

  def test_the_mcp_gate_holds_on_the_real_loop
    allowed = RecordingMcpTool.new("search_threads")
    denied = RecordingMcpTool.new("send_email")
    perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
    chat = RubyLLM.chat(model: "gpt-4o-mini").with_tools(
      Nexo::MCP::GatedTool.new(tool: allowed, permissions: perms),
      Nexo::MCP::GatedTool.new(tool: denied, permissions: perms)
    )
    results = []
    chat.after_tool_result { |result| results << result }
    stub_replies tool_call(:search_threads, q: "invoice"), tool_call(:send_email, q: "x"), "Done."

    chat.ask("Triage")

    assert_equal [{q: "invoice"}], allowed.calls
    assert_empty denied.calls, "a denied MCP tool is never reached"
    assert_equal "ran search_threads", results[0]
    assert_match(/denied in read_only mode/, results[1][:error])
  end
end
