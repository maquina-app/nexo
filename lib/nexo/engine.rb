# frozen_string_literal: true

# Rails-optional: this file is required from lib/nexo.rb only when Rails is
# present, and is additionally guarded here so requiring it directly in plain
# Ruby never raises. The engine wires Nexo's generator and rake task into a host
# Rails app and loads the WorkflowRun model once ActiveRecord is available.
if defined?(::Rails::Engine)
  module Nexo
    # The Rails engine that wires Nexo into a host app: it loads the WorkflowRun
    # model and WorkflowJob during boot, opt-in-subscribes the Turbo broadcaster,
    # and (via Rails::Engine) exposes Nexo's generators and rake tasks. Defined
    # only when +::Rails::Engine+ is present, so the plain-Ruby core stays
    # Rails-free.
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

      # Load the WorkflowJob once ActiveJob is available (Spec 11 R1), mirroring the
      # workflow_run model initializer above. The require is safe with no ActiveJob:
      # the file body is guarded, so it defines nothing and Workflow.run_later raises
      # a MissingDependencyError instead.
      initializer "nexo.workflow_job" do
        require "nexo/workflow_job"
      end

      # Wire the opt-in Turbo mirror (Spec 11 R2). The require is always safe (the
      # broadcaster's body is guarded on ActiveSupport::Notifications); subscribe! is
      # a no-op without turbo-rails. Only subscribe when the host opted in via
      # config.broadcast_events — safe-by-default (broadcast_events defaults false).
      initializer "nexo.turbo_broadcaster" do
        require "nexo/turbo_broadcaster"
        Nexo::TurboBroadcaster.subscribe! if Nexo.config.broadcast_events
      end

      # The nexo:logs rake task ships in lib/tasks/nexo.rake, which Rails::Engine
      # loads into the host app automatically — no explicit rake_tasks wiring
      # (loading it a second time would run the task body twice).
    end
  end
end
