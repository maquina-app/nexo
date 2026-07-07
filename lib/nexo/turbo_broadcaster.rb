# frozen_string_literal: true

# Opt-in Turbo mirror for Nexo's run notifications (Spec 11 R2). Mirrors the
# Rails-optional pattern of lib/nexo/workflow_run.rb: the whole body is guarded by
# defined?(::ActiveSupport::Notifications), it is ignored by the Zeitwerk loader in
# lib/nexo.rb, and it is required + subscribed from an engine initializer — only
# when Nexo.config.broadcast_events is truthy.
#
# It subscribes to the "nexo.workflow.event" notifications (which Workflow#emit
# fires) and re-broadcasts each event over Turbo Streams to a per-run stream. It is
# a NO-OP without turbo-rails (Turbo::StreamsChannel undefined) — hosts not using
# Turbo simply subscribe to the same notifications for their own purposes, and the
# core stays coupling-free (Nexo ships no cable backend).
if defined?(::ActiveSupport::Notifications)
  module Nexo
    # Opt-in Turbo mirror: subscribes to the +nexo.workflow.event+ notifications
    # and re-broadcasts each event to a per-run Turbo stream. A no-op without
    # turbo-rails, so the plain-Ruby core stays coupling-free.
    module TurboBroadcaster
      # Subscribes once (idempotent via @subscribed) to "nexo.workflow.event" and
      # appends each event to the run's Turbo stream, rendering the overridable
      # "nexo/event" partial. Returns early (no subscription) unless turbo-rails is
      # present, so calling it in a non-Turbo host is harmless.
      def self.subscribe!
        return unless defined?(::Turbo::StreamsChannel)
        return if @subscribed

        @subscribed = true

        ::ActiveSupport::Notifications.subscribe("nexo.workflow.event") do |*, payload|
          ::Turbo::StreamsChannel.broadcast_append_to(
            "nexo_run_#{payload[:run_id]}",
            target: "nexo_run_#{payload[:run_id]}_events",
            partial: "nexo/event",
            locals: {event: payload[:event]}
          )
        end
      end
    end
  end
end
