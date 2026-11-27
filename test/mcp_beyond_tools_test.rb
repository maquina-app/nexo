# frozen_string_literal: true

require "test_helper"
require "net/http"
require "tmpdir"
require_relative "support/oauth_mcp_server"

# 0.16 — what an MCP server does besides answering a tool call, through
# ruby_llm's real client against the real local server (OauthMcpServer):
# resources the model may read, a tool that asks the person a question, and a
# call refused for want of a scope. Only the model's replies are scripted.
class McpBeyondToolsTest < Minitest::Test
  CALLBACK = "http://127.0.0.1:9/callback"

  def setup
    skip "scripts the model; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    WebMock.disable_net_connect!(allow_localhost: true) if defined?(WebMock)
    Nexo.reset_config!
    Nexo::RunStore::Memory.reset!
    @previous_store = RubyLLM.config.mcp_credential_store
    RubyLLM.config.mcp_credential_store = RubyLLM::MCP::OAuth::MemoryStore.new
    @server = OauthMcpServer.new
  end

  def teardown
    @server&.stop
    return unless defined?(@previous_store)

    RubyLLM.config.mcp_credential_store = @previous_store
    WebMock.disable_net_connect! if defined?(WebMock)
    Nexo.reset_config!
  end

  def agent_class(*allowed, **mcp_options)
    url = @server.url
    Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      mcp :local, transport: :http, url: url, oauth: true, **mcp_options
      mcp_allow(*allowed)
    end
  end

  def signed_in(klass, **options)
    agent = klass.new(mcp_owner: "alice", **options)
    server = agent.mcp_server(:local)
    unless server.authorized?
      response = Net::HTTP.get_response(URI(server.authorization_url(redirect_uri: CALLBACK)))
      server.authorize(URI.decode_www_form(URI(response["Location"]).query).to_h)
    end
    agent
  end

  def results_of(agent, prompt = "go")
    results = []
    agent.prompt(prompt) { |type, payload| results << payload if type == :tool_result }
    results
  end

  # --- resources ---------------------------------------------------------------

  def test_resource_tools_are_attached_only_when_asked_for_and_allowed
    plain = signed_in(agent_class("whoami"))
    asked = signed_in(agent_class("whoami", resources: true))
    allowed = signed_in(agent_class("whoami", "list_mcp_resources", "read_mcp_resource", resources: true))

    refute_includes plain.chat.tools.keys, :read_mcp_resource
    refute_includes asked.chat.tools.keys, :read_mcp_resource, ":read_only can never allow an unlisted MCP tool"
    assert_kind_of Nexo::MCP::GatedTool, allowed.chat.tools[:read_mcp_resource]
    assert_kind_of Nexo::MCP::GatedTool, allowed.chat.tools[:list_mcp_resources]
  ensure
    [plain, asked, allowed].each { |agent| agent&.close }
  end

  def test_the_model_lists_and_reads_a_resource_through_the_gate
    agent = signed_in(agent_class("list_mcp_resources", "read_mcp_resource", resources: true))
    stub_replies tool_call(:list_mcp_resources), tool_call(:read_mcp_resource, server: "local", uri: "note://welcome"), "done"

    listed, read = results_of(agent)

    assert_equal "local\tnote://welcome\twelcome\ttext/plain", listed
    assert_equal "contents of note://welcome", read
    assert_includes @server.calls, "resources/read"
  ensure
    agent&.close
  end

  def test_reading_from_an_unknown_server_is_an_error_result
    agent = signed_in(agent_class("read_mcp_resource", resources: true))
    stub_replies tool_call(:read_mcp_resource, server: "elsewhere", uri: "note://x"), "done"

    assert_match(/no MCP server named elsewhere/, results_of(agent).first[:error])
  ensure
    agent&.close
  end

  # --- a tool that asks the person ---------------------------------------------

  def test_an_unanswered_question_raises_input_required_with_what_to_ask
    agent = signed_in(agent_class("book"))
    stub_replies tool_call(:book), "done"

    error = assert_raises(Nexo::InputRequired) { agent.prompt("Book a seat") }
    question = error.questions.first

    assert_equal "book:seat", question.key
    assert_equal "Window or aisle?", question.message
    assert_equal [{"name" => "seat", "type" => "string", "required" => true}], question.fields
    assert_empty @server.answers
  ensure
    agent&.close
  end

  def test_an_answer_given_up_front_is_sent_and_the_turn_carries_on
    agent = signed_in(agent_class("book"), answers: {"book:seat" => "window"})
    stub_replies tool_call(:book), "Booked."

    response = agent.prompt("Book a seat")

    assert_equal "Booked.", response.content
    assert_equal 1, @server.answers.size
    assert_match(/window/, @server.answers.first.to_json)
  ensure
    agent&.close
  end

  def test_a_workflow_suspends_on_the_question_and_resumes_with_the_answer
    klass = agent_class("book")
    signed_in(klass).close
    workflow = Class.new(Nexo::Workflow) do
      agent klass

      def call(payload) = {content: run_agent("Book a seat", mcp_owner: payload[:owner]).content}
    end
    Object.const_set(:McpBookingFlow, workflow)
    stub_replies tool_call(:book), "Booked."

    run = McpBookingFlow.run(owner: "alice")

    assert_equal "suspended", run.status
    assert_equal "Window or aisle?", run.state["__input__"].first["message"]
    assert_equal "book:seat", run.state["__input__"].first["key"]

    stub_replies tool_call(:book), "Booked." # resume re-runs the prompt, so the model asks again
    resumed = McpBookingFlow.resume(run.id, answers: {"book:seat" => "aisle", "other:thing" => "ignored"})

    assert_equal "done", resumed.status
    assert_equal({"content" => "Booked."}, resumed.result)
    assert_match(/aisle/, @server.answers.last.to_json)
  ensure
    Object.send(:remove_const, :McpBookingFlow) if Object.const_defined?(:McpBookingFlow)
  end

  # --- a call refused for want of a scope --------------------------------------

  def test_a_missing_scope_is_authorization_required_naming_the_server_and_scopes
    agent = signed_in(agent_class("publish"))
    stub_replies tool_call(:publish), "done"

    error = assert_raises(Nexo::AuthorizationRequired) { agent.prompt("Publish it") }

    assert_equal :local, error.server
    assert_equal %w[write], error.scopes
    assert_match(/needs more access \(write\)/, error.message)
  ensure
    agent&.close
  end

  # --- deferred tools ------------------------------------------------------------

  def test_a_deferred_server_keeps_its_tools_gated_and_out_of_the_context
    agent = signed_in(agent_class("whoami", defer: true))
    chat = agent.chat

    assert_equal %i[whoami], chat.deferred_tools.keys
    assert_kind_of Nexo::MCP::GatedTool, chat.tools[:whoami]
    stub_replies tool_call(:whoami), "done"
    assert_match(/you are client-/, results_of(agent).first.text)
  ensure
    agent&.close
  end

  # --- prompts -----------------------------------------------------------------

  def test_a_servers_prompts_are_listed_with_their_arguments
    agent = signed_in(agent_class)

    prompt = agent.mcp_prompts(:local).first

    assert_equal "review", prompt.name
    assert_equal [:code], prompt.arguments.map(&:name)
  end

  def test_a_servers_prompt_is_sent_in_place_of_a_text
    agent = signed_in(agent_class)
    stub_replies "Looks fine."

    response = agent.prompt(agent.mcp_prompt(:local, :review, code: "+ puts 1"))

    assert_equal "Looks fine.", response.content
    assert_includes @server.calls, "prompts/get"
  end

  def test_a_workflow_builds_the_prompt_from_its_agent
    klass = agent_class
    owner_agent = signed_in(klass)
    owner_agent.close
    flow = Class.new(Nexo::Workflow) do
      agent klass
      define_method(:call) do |_payload|
        {"said" => run_agent(->(agent) { agent.mcp_prompt(:local, :review, code: "x") }, mcp_owner: "alice").content}
      end
    end
    stub_replies "Reviewed."

    run = flow.run

    assert_equal "done", run.status, run.error.to_s
    assert_equal({"said" => "Reviewed."}, run.result)
  end

  # --- tasks -------------------------------------------------------------------

  def test_a_call_answered_with_a_task_is_waited_for
    agent = signed_in(agent_class("slow", tasks: true))
    stub_replies tool_call(:slow), "All done."
    events = []

    response = agent.prompt("go") { |type, payload| events << [type, payload] }

    assert_equal "All done.", response.content
    result = events.find { |type, _| type == :tool_result }.last
    assert_includes result.text, "slow work finished"
    assert_includes events.map(&:first), :tool_progress, "the server's status messages arrive as progress"
    assert_operator @server.calls.count("tasks/get"), :>=, 2
  end

  def test_a_task_that_outlives_the_timeout_is_cancelled_and_the_prompt_fails
    Nexo.config.mcp_task_timeout = 0.05
    agent = signed_in(agent_class("stuck", tasks: true))
    stub_replies tool_call(:stuck), "never reached"

    error = assert_raises(Nexo::Error) { agent.prompt("go") }

    assert_match(/did not finish in 0.05 seconds/, error.message)
    assert_equal 1, @server.cancelled_tasks.size
  end

  def test_tasks_is_a_nexo_option_turned_into_the_extension
    settings = Nexo::MCP.send(:settings, name: :x, transport: :http, token: nil,
      config: {url: "http://127.0.0.1:1/mcp", tasks: true, allow_http: true})

    assert_equal [:tasks], settings[:extensions]
    refute settings.key?(:tasks)
  end
end
