# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in nexo_ai.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", "~> 5.16"

# ruby_llm-mcp is a SOFT/optional runtime dependency (Spec 6): Nexo::MCP.load!
# requires it lazily behind a rescue that raises Nexo::MissingDependencyError, so
# it is intentionally NOT a gemspec add_dependency — `require "nexo"` with the gem
# absent must not raise. Kept unversioned (dev group) so the offline suite can
# exercise the real client shape without pinning the API surface.
gem "ruby_llm-mcp", group: :development
