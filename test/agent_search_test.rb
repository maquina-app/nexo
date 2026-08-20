# frozen_string_literal: true

require "test_helper"

class AgentSearchTest < Minitest::Test
  # A resolvable model id so RubyLLM.chat can build a chat under the fake provider.
  TEST_MODEL = "gpt-4o-mini"

  class Backend
    def search(_q, **) = []
  end

  def teardown
    Nexo.reset_config!
  end

  def test_search_backend_macro_reads_and_writes
    b = Backend.new
    klass = Class.new(Nexo::Agent) {
      model "test-model"
      search_backend b
    }
    assert_same b, klass.search_backend
  end

  def test_default_agent_has_no_search_backend
    klass = Class.new(Nexo::Agent) { model "test-model" }
    assert_nil klass.search_backend
  end

  def test_auto_permissions_allow_search
    p = Nexo::Permissions.new(mode: :auto, allow: %i[read glob write shell fetch search])
    assert p.authorize!(:search, "q")
  end

  def test_search_backend_set_attaches_web_search_tool
    skip "agent wiring test uses the stubbed provider" if ENV["NEXO_LIVE"] == "1"
    RubyLLM::Test.reset
    klass = Class.new(Nexo::Agent) {
      model TEST_MODEL
      sandbox :virtual
      search_backend Backend.new
      # Declaring a backend is not the capability grant — :search must also be
      # permitted, or the tool is left out of the schema rather than attached to
      # fail at call time.
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob search])
    }
    tool_classes = klass.new.chat.tools.values.map(&:class)
    assert_includes tool_classes, Nexo::Tools::WebSearch
  end

  # A backend declared without the :search grant can never be used, so the tool
  # is not advertised.
  def test_search_backend_without_search_permission_does_not_attach
    skip "agent wiring test uses the stubbed provider" if ENV["NEXO_LIVE"] == "1"
    RubyLLM::Test.reset
    klass = Class.new(Nexo::Agent) {
      model TEST_MODEL
      sandbox :virtual
      search_backend Backend.new
    }
    tool_classes = klass.new.chat.tools.values.map(&:class)
    refute_includes tool_classes, Nexo::Tools::WebSearch
  end

  def test_no_search_backend_does_not_attach_web_search_tool
    skip "agent wiring test uses the stubbed provider" if ENV["NEXO_LIVE"] == "1"
    RubyLLM::Test.reset
    klass = Class.new(Nexo::Agent) {
      model TEST_MODEL
      sandbox :virtual
    }
    tool_classes = klass.new.chat.tools.values.map(&:class)
    refute_includes tool_classes, Nexo::Tools::WebSearch
  end
end
