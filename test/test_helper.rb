# frozen_string_literal: true

# ruby_llm reads its bundled models.json (UTF-8) during model resolution. Some
# CI environments start with Encoding.default_external == US-ASCII, under which
# that File.read raises Encoding::InvalidByteSequenceError. Force UTF-8 for the
# suite so the offline, deterministic core tests are environment-independent.
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "nexo_ai"

require "minitest/autorun"

# Stub the model with ruby_llm-test so the core suite is offline and
# deterministic — no API keys, no network, no flaky tool-calling. The optional
# live smoke (NEXO_LIVE=1) talks to a real provider, so the fake provider is NOT
# installed in that mode.
unless ENV["NEXO_LIVE"] == "1"
  # ruby_llm-test 0.2.0 references SimpleDelegator without requiring stdlib delegate.
  require "delegate"
  require "ruby_llm/test"
  RubyLLM::Models.singleton_class.prepend(RubyLLM::Test::ResolveWithTestProvider)

  # Building a chat resolves a model + provider; give the default provider a dummy
  # key so resolution never reaches out for credentials. The fake provider above
  # intercepts the actual request.
  RubyLLM.configure { |config| config.openai_api_key = "test" }
end
