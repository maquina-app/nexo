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

# mxc confines Sandboxes::Local#shell (Seatbelt on macOS, Bubblewrap on Linux).
# A SOFT dependency like async: never a gemspec add_dependency, loaded only when
# present. Listed here so the suite can exercise the confined path.
gem "mxc", ">= 0.4.1", group: :development
