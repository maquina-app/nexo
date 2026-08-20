# frozen_string_literal: true

require "test_helper"

class AgentFetchTest < Minitest::Test
  def test_fetch_allow_macro_reads_and_writes
    klass = Class.new(Nexo::Agent) do
      model "test-model"
      fetch_allow %w[news.example.com blog.example.com]
    end
    assert_equal %w[news.example.com blog.example.com], klass.fetch_allow
  end

  def test_fetch_allow_flattens_and_stringifies
    klass = Class.new(Nexo::Agent) do
      model "test-model"
      fetch_allow :"news.example.com", %w[blog.example.com]
    end
    assert_equal %w[news.example.com blog.example.com], klass.fetch_allow
  end

  def test_default_agent_has_empty_fetch_allow
    klass = Class.new(Nexo::Agent) { model "test-model" }
    assert_empty klass.fetch_allow
  end

  # fetch_allow scopes HOSTS; :fetch is the capability grant. Both are required
  # for the tool to be advertised, so a gate that can never authorize :fetch gets
  # no Fetch tool rather than one that fails on every call.
  def test_fetch_allow_with_fetch_permitted_attaches_the_tool
    skip "agent wiring test uses the stubbed provider" if ENV["NEXO_LIVE"] == "1"
    RubyLLM::Test.reset
    klass = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      sandbox :virtual
      fetch_allow %w[news.example.com]
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob fetch])
    end
    assert_includes klass.new.chat.tools.values.map(&:class), Nexo::Tools::Fetch
  end

  def test_fetch_allow_under_read_only_does_not_attach_the_tool
    skip "agent wiring test uses the stubbed provider" if ENV["NEXO_LIVE"] == "1"
    RubyLLM::Test.reset
    klass = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      sandbox :virtual
      fetch_allow %w[news.example.com]
    end
    refute_includes klass.new.chat.tools.values.map(&:class), Nexo::Tools::Fetch
  end
end
