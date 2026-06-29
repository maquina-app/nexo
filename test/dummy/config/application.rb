# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"

# Loading nexo_ai with Rails present pulls in Nexo::Engine, which wires the
# nexo:workflows generator + nexo:logs rake task and loads the WorkflowRun model.
require "nexo_ai"

module Dummy
  # Minimal host app: just enough to load the engine, run the generator,
  # migrate, and run a workflow against SQLite. No web surface.
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = false
  end
end
