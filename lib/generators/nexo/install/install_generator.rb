# frozen_string_literal: true

require "rails/generators"

module Nexo
  module Generators
    # Sets up the conventional Nexo layout in a host Rails app:
    #
    #   rails g nexo:install
    #
    # creates the app/agents, app/workflows and app/skills directories (each
    # with a committable .keep) and a provider-neutral config/initializers/nexo.rb.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_directories
        %w[app/agents app/workflows app/skills].each do |dir|
          empty_directory dir
          create_file "#{dir}/.keep" unless File.exist?("#{dir}/.keep")
        end
      end

      def copy_initializer
        copy_file "nexo.rb", "config/initializers/nexo.rb"
      end
    end
  end
end
