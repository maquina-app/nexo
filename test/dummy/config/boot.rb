# frozen_string_literal: true

# The dummy app shares the gem's Gemfile (nexo_ai + the rails/sqlite3 dev deps)
# rather than carrying its own bundle.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)

require "bundler/setup"
