# frozen_string_literal: true

# ruby_llm reads its bundled models.json (UTF-8) during model resolution. Some
# CI environments start with Encoding.default_external == US-ASCII, under which
# that File.read raises Encoding::InvalidByteSequenceError. Force UTF-8 for the
# suite so the offline, deterministic core tests are environment-independent.
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "nexo_ai"

require "minitest/autorun"

# ruby_llm's own test helper scripts what the model replies, with no provider and
# no API key, while the real conversation loop (tools, callbacks, round limits)
# still runs. `stub_replies` is available in every test; the script is cleared
# after each one. Gated off for live smoke so test/live_smoke_test.rb reaches a
# real provider. A dummy key lets chat resolution proceed before a stub is set.
unless ENV["NEXO_LIVE"] == "1"
  require "ruby_llm/test_helper"
  Minitest::Test.include(RubyLLM::TestHelper)
  RubyLLM.configure { |config| config.openai_api_key = "test" }
end
