# frozen_string_literal: true

require "test_helper"

# Optional, manual, env-gated live smoke. Skipped unless NEXO_LIVE=1, so it is
# never part of the offline core suite. It exercises a real provider (Ollama by
# default) end to end — small local models have weak tool-calling, so this may be
# flaky; that is expected and is why it is not a gating test. Point NEXO_MODEL at
# a stronger model if Gemma's tool-calling proves too weak.
#
#   ollama serve &
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b bundle exec rake test TEST=test/live_smoke_test.rb
class LiveSmokeTest < Minitest::Test
  def test_live_code_review_smoke
    skip "set NEXO_LIVE=1 to run live model smoke tests" unless ENV["NEXO_LIVE"] == "1"

    require "tmpdir"

    RubyLLM.configure do |config|
      config.ollama_api_base = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
    end

    model = ENV.fetch("NEXO_MODEL")

    # provider/assume_model_exists are needed for an unregistered local tag.
    agent_class = Class.new(Nexo::Agent) do
      provider :ollama
      assume_model_exists true
      sandbox :local
      permissions :read_only
      instructions "You are a careful code reviewer. Read files and report issues."
    end

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "hello.rb"), "def hello = 'hi'\n")

      agent = agent_class.new(cwd: dir, model: model)
      response = agent.prompt("List the Ruby files and summarize the project.")

      refute_empty response.content.to_s
    end
  end

  # Live MCP smoke: connect the real filesystem MCP server over stdio and assert the
  # gate lets an allowed read tool through while a denied write tool returns { error: }.
  # No live model needed — it exercises Nexo::MCP.build + MCP::GatedTool against the
  # real ruby_llm MCP client. Requires npx (the server is an npm package).
  #
  #   NEXO_LIVE=1 bundle exec rake test TEST=test/live_smoke_test.rb
  def test_live_mcp_filesystem_gate_smoke
    skip "set NEXO_LIVE=1 to run live MCP smoke tests" unless ENV["NEXO_LIVE"] == "1"
    skip "npx not found — install Node to run the MCP filesystem server" unless system("which", "npx", out: File::NULL, err: File::NULL)

    require "tmpdir"

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "note.txt"), "hello from mcp\n")

      client = Nexo::MCP.build(
        name: "fs",
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", dir]
      )

      tools = client.tools
      read_tool = tools.find { |t| t.name.match?(/read/i) }
      write_tool = tools.find { |t| t.name.match?(/write/i) }
      skip "filesystem server exposed no read/write tools" unless read_tool && write_tool

      # read_tool is allowed; write_tool is not → fails closed under :read_only.
      perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: [read_tool.name])

      allowed = Nexo::MCP::GatedTool.new(tool: read_tool, permissions: perms)
      result = allowed.call({path: File.join(dir, "note.txt")})
      refute(result.is_a?(Hash) && result[:error], "allowed read should not be gated: #{result.inspect}")

      denied = Nexo::MCP::GatedTool.new(tool: write_tool, permissions: perms)
      denied_result = denied.call({path: File.join(dir, "new.txt"), content: "nope"})
      assert denied_result[:error], "denied write should return { error: }"
      refute_path_exists File.join(dir, "new.txt")
    ensure
      client&.close
    end
  end

  # Live fetch smoke (Spec 9): hit a real allow-listed URL and assert a body came
  # back, then assert an off-list host is refused with { error: } and no request.
  # No live model needed — it exercises Nexo::Tools::Fetch against the real network.
  #
  #   NEXO_LIVE=1 bundle exec rake test TEST=test/live_smoke_test.rb
  def test_live_fetch_smoke
    skip "set NEXO_LIVE=1 to run live fetch smoke tests" unless ENV["NEXO_LIVE"] == "1"

    perms = Nexo::Permissions.new(mode: :read_only, allow: %i[read glob fetch])
    tool = Nexo::Tools::Fetch.new(sandbox: Nexo::Sandboxes::Virtual.new,
      permissions: perms, allow_hosts: %w[example.com])

    allowed = tool.execute(url: "https://example.com/")
    refute allowed[:error], "allow-listed fetch should not be denied: #{allowed.inspect}"
    refute_empty allowed[:body].to_s

    denied = tool.execute(url: "https://icanhazip.com/")
    assert denied[:error], "off-list host should return { error: }"
  end

  # --- 0.16: what was only ever run against a scripted model -------------------
  #
  #   NEXO_LIVE=1 NEXO_MODEL=<an Ollama model that calls tools> \
  #     bundle exec ruby -Itest test/live_smoke_test.rb

  class Stock < RubyLLM::Tool
    description "Returns how many units of a SKU are in the warehouse"
    parameter :sku, type: :string, description: "The SKU, such as A-17"

    def execute(sku:) = "#{sku}: 42 units"
  end

  class Weather < RubyLLM::Tool
    description "Returns the weather in a city"
    parameter :city, type: :string, description: "The city"

    def execute(city:) = "#{city}: sunny"
  end

  class Clock < RubyLLM::Tool
    description "Returns the current time in a time zone"
    parameter :zone, type: :string, description: "The time zone"

    def execute(zone:) = "#{zone}: 12:00"
  end

  def live_model
    skip "set NEXO_LIVE=1 and NEXO_MODEL to run live model smoke tests" unless ENV["NEXO_LIVE"] == "1" && ENV["NEXO_MODEL"]

    RubyLLM.configure { |config| config.ollama_api_base = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1") }
    ENV.fetch("NEXO_MODEL")
  end

  def ollama_agent(&declarations)
    Class.new(Nexo::Agent) do
      provider :ollama
      assume_model_exists true
      class_eval(&declarations) if declarations
    end
  end

  # A request that cannot reach its provider moves to the fallback model, and
  # the loop reports it.
  def test_live_fallback_to_another_model
    model = live_model
    previous = [RubyLLM.config.openai_api_base, RubyLLM.config.openai_api_key]
    RubyLLM.configure do |config|
      config.openai_api_base = "http://127.0.0.1:9/v1" # nothing listens here
      config.openai_api_key = "unused"
    end
    fallback, = RubyLLM.models.resolve(model, provider: :ollama)
    klass = Class.new(Nexo::Agent) do
      provider :openai
      assume_model_exists true
      llm { fallbacks fallback }
    end
    events = []

    response = klass.new(model: "gpt-4o-mini").prompt("Reply with the single word: pong") { |type, payload| events << [type, payload] }

    refute_empty response.content.to_s
    moved = events.find { |type, _| type == :fallback }&.last
    assert moved, "expected a :fallback event, got #{events.map(&:first).inspect}"
    assert_equal model, moved.to.id
  ensure
    RubyLLM.configure { |config| config.openai_api_base, config.openai_api_key = previous } if previous
  end

  # Deferred tools stay out of the request until the model looks for one through
  # ruby_llm's `tool_search` (Ollama has no tool search of its own).
  def test_live_deferred_tools_are_found_through_tool_search
    model = live_model
    klass = ollama_agent { tools Stock, Weather, Clock, defer: true }
    calls = []

    response = klass.new(model: model).prompt("How many units of SKU A-17 are in the warehouse? Use your tools.") do |type, payload|
      calls << payload.name.to_s if type == :tool_call
    end

    assert_includes calls, "tool_search", "the model searched for a tool: #{calls.inspect}"
    assert(calls.any? { |name| name.end_with?("stock") }, "the model called the tool it found: #{calls.inspect}")
    assert_includes response.content.to_s, "42"
  end

  # Manual compaction, which Ollama serves through its Responses protocol: one
  # message is appended and nothing earlier is removed.
  def test_live_manual_compaction_keeps_the_transcript
    model = live_model
    agent = ollama_agent.new(model: model)
    chat = agent.chat.with_model(model, provider: :ollama, protocol: :responses, assume_model_exists: true)
    agent.loop.run(agent: agent, prompt: "Remember the number 7341. Reply OK.", chat: chat)
    before = chat.messages.size

    summary = chat.compact

    assert_equal before + 1, chat.messages.size
    assert_equal :assistant, summary.role
    assert_includes chat.messages.map(&:role), :user
  end

  # An `:approve` agent on a real model: the write pauses, the run suspends, and
  # the approved resume writes the file.
  def test_live_approval_suspends_and_resumes
    model = live_model
    require "tmpdir"
    Nexo::RunStore::Memory.reset!
    klass = ollama_agent do
      permissions :approve
      instructions "You write files with the write_file tool when asked. Do not ask for confirmation."
    end
    klass.model model

    Dir.mktmpdir do |dir|
      flow = Class.new(Nexo::Workflow) do
        agent klass
        sandbox :local
        cwd dir

        def call(_payload) = {"said" => run_agent("Create the file note.txt containing exactly: hello").content}
      end
      Object.const_set(:LiveApprovalFlow, flow)

      run = LiveApprovalFlow.run
      assert_equal "suspended", run.status, run.error.to_s
      assert_equal "write", run.state["__approval__"]["capability"]
      refute File.exist?(File.join(dir, "note.txt")), "nothing is written before the approval"

      # The model may phrase the second attempt differently; approve what it asks.
      3.times do
        break unless run.status == "suspended"

        run = Nexo::Workflow.resume(run.id, approved: true)
      end

      assert_equal "done", run.status, run.error.to_s
      assert_includes File.read(File.join(dir, "note.txt")), "hello"
    end
  ensure
    Object.send(:remove_const, :LiveApprovalFlow) if Object.const_defined?(:LiveApprovalFlow)
  end

  # --- 0.17: against Anthropic, for what a local model cannot show ---------------
  #
  #   NEXO_LIVE=1 ANTHROPIC_API_KEY=... bundle exec ruby -Itest test/live_smoke_test.rb -n /anthropic/

  def anthropic_agent(&declarations)
    skip "set NEXO_LIVE=1 and ANTHROPIC_API_KEY to run the Anthropic checks" unless ENV["NEXO_LIVE"] == "1" && ENV["ANTHROPIC_API_KEY"]

    RubyLLM.configure { |config| config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] }
    Class.new(Nexo::Agent) do
      model ENV.fetch("NEXO_ANTHROPIC_MODEL", "claude-haiku-5-5")
      provider :anthropic
      assume_model_exists true
      class_eval(&declarations) if declarations
    end
  end

  # Anthropic searches deferred tools itself: no `tool_search` call of ruby_llm's
  # appears, and the tool the model found still runs behind the gate.
  def test_live_anthropic_native_tool_search
    klass = anthropic_agent do
      file_tools :none
      tools Stock, Weather, Clock, defer: true
    end
    calls = []

    response = klass.new.prompt("How many units of SKU A-17 are in the warehouse? Use your tools.") do |type, payload|
      calls << payload.name.to_s if type == :tool_call
    end

    assert(calls.any? { |name| name.end_with?("stock") }, "the model called the deferred tool: #{calls.inspect}")
    refute_includes calls, "tool_search", "the provider searched; ruby_llm's own search tool was not needed"
    assert_includes response.content.to_s, "42"
  end

  # Automatic compaction is a provider feature switched on in the `llm` block.
  # This proves the request is accepted with it on and a session keeps working;
  # the conversation is far too short to make the provider compact anything.
  def test_live_anthropic_accepts_automatic_compaction
    klass = anthropic_agent do
      file_tools :none
      llm { compaction true }
      instructions "Answer in one short sentence."
    end
    session = Nexo::Session.resume(klass, "live-compaction-#{Process.pid}")

    first = session.prompt("Remember the number 7341.")
    second = session.prompt("Which number did I ask you to remember?")

    refute_empty first.content.to_s
    assert_includes second.content.to_s, "7341"
  ensure
    session&.close
  end

  # 0.17: after an approval the paused call carries on. The write happens once
  # and the model is not asked to plan the task a second time.
  def test_live_anthropic_resume_continues_after_approval
    require "tmpdir"
    Nexo::RunStore::Memory.reset!
    klass = anthropic_agent do
      permissions :approve
      instructions "You write files with the write_file tool when asked. Do not ask for confirmation."
    end

    Dir.mktmpdir do |dir|
      flow = Class.new(Nexo::Workflow) do
        agent klass
        sandbox :local
        cwd dir

        def call(_payload) = {"said" => run_agent("Create the file note.txt containing exactly: hello").content}
      end
      Object.const_set(:LiveContinueFlow, flow)

      run = LiveContinueFlow.run
      assert_equal "suspended", run.status, run.error.to_s
      assert run.state["__chat__"], "the conversation was saved with the run"

      run = Nexo::Workflow.resume(run.id, approved: true)

      assert_equal "done", run.status, run.error.to_s
      assert_includes File.read(File.join(dir, "note.txt")), "hello"
      writes = run.events.count { |event| event["type"] == "agent_tool_call" && event["data"]["name"] == "write_file" }
      assert_equal 1, writes, "one write across the suspend and the resume"
    end
  ensure
    Object.send(:remove_const, :LiveContinueFlow) if Object.const_defined?(:LiveContinueFlow)
  end
end
