# frozen_string_literal: true

require "test_helper"
require "async"

# Spec 5 regression: Loops::RubyLLM needs NO async-specific code. Driving an
# agent prompt from inside an Async {} reactor must return the stubbed response
# unchanged — proving chat.ask already yields correctly under the fiber scheduler
# and the loop was not (and must not be) wrapped in its own reactor.
class LoopsAsyncRegressionTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  class VirtualAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :virtual
  end

  def setup
    skip "loop wiring tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    RubyLLM::Test.reset
  end

  def teardown
    Nexo.reset_config!
  end

  def test_agent_prompt_inside_a_reactor_returns_the_stubbed_response
    RubyLLM::Test.stub_response("done inside reactor")
    response = nil

    Async do
      response = VirtualAgent.new.prompt("Go")
    end.wait

    assert_equal "done inside reactor", response.content
  end

  def test_fanning_out_several_prompts_via_concurrent_returns_all_responses
    # The fake provider serves one queued response per request; stub three for
    # the three fanned-out prompts.
    RubyLLM::Test.stub_responses("ok", "ok", "ok")

    results = Nexo.concurrent(max_in_flight: 2) do |c|
      3.times { c.add { VirtualAgent.new.prompt("Go").content } }
    end

    assert_equal %w[ok ok ok], results
  end
end
