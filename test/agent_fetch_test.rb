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
end
