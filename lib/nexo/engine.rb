# frozen_string_literal: true

# Rails-optional: this file is required from lib/nexo.rb only when Rails is
# present, and is additionally guarded here so requiring it directly in plain
# Ruby never raises. The engine wires Nexo's generator and rake task into a host
# Rails app and loads the WorkflowRun model once ActiveRecord is available.
if defined?(::Rails::Engine)
  module Nexo
    class Engine < ::Rails::Engine
      isolate_namespace Nexo

      # Load the WorkflowRun model during boot so RunStore.default reliably
      # selects the ActiveRecord backend (it checks defined?(Nexo::WorkflowRun)).
      # A plain on_load(:active_record) hook is not enough: it only fires once
      # AR::Base is touched, which may not happen before a command runs — e.g.
      # `rake nexo:logs` would otherwise boot, never load AR, and fall back to
      # the Memory store. Requiring the file directly is safe: its body is
      # guarded, so in a Rails app with no ActiveRecord it defines nothing and
      # RunStore.default falls back to Memory.
      initializer "nexo.workflow_run_model" do
        require "nexo/workflow_run"
      end

      # The nexo:logs rake task ships in lib/tasks/nexo.rake, which Rails::Engine
      # loads into the host app automatically — no explicit rake_tasks wiring
      # (loading it a second time would run the task body twice).
    end
  end
end
