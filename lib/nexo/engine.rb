# frozen_string_literal: true

# Rails-optional: this file is required from lib/nexo.rb only when Rails is
# present, and is additionally guarded here so requiring it directly in plain
# Ruby never raises.
if defined?(::Rails::Engine)
  module Nexo
    class Engine < ::Rails::Engine
      isolate_namespace Nexo
    end
  end
end
