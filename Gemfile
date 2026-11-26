# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in nexo_ai.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", "~> 5.16"

# webmock stubs external HTTP in the offline suite (Spec 9). Dev/test-only — the
# core suite never makes a live request; Tools::Fetch uses only stdlib net/http, so
# webmock is NOT a gemspec add_dependency.
gem "webmock", group: :development
