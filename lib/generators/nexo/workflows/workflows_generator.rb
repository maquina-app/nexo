# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module Nexo
  module Generators
    # Installs the WorkflowRun persistence schema into a host Rails app:
    #
    #   rails g nexo:workflows
    #
    # copies a timestamped migration that creates the +nexo_workflow_runs+
    # table, after which +rails db:migrate+ makes {Nexo::Workflow} runs persist
    # to ActiveRecord instead of the in-memory store.
    class WorkflowsGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      # Required by Rails::Generators::Migration to produce the migration's
      # timestamp prefix.
      def self.next_migration_number(dirname)
        next_migration_number = current_migration_number(dirname) + 1
        ::ActiveRecord::Migration.next_migration_number(next_migration_number)
      end

      def create_migration_file
        migration_template "create_nexo_workflow_runs.rb", "db/migrate/create_nexo_workflow_runs.rb"
      end
    end
  end
end
