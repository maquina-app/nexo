# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module Nexo
  module Generators
    # Adds the +artifacts+ column to an already-installed +nexo_workflow_runs+
    # table (Spec 7):
    #
    #   rails g nexo:artifacts
    #
    # copies a timestamped, additive migration adding a +json+ +artifacts+ column
    # (default +[]+), after which +rails db:migrate+ lets {Nexo::Workflow} runs
    # record named artifacts. Fresh installs get the column from
    # +nexo:workflows+ directly; this generator is for apps installed before
    # Spec 7. Modeled on {WorkflowsGenerator}.
    class ArtifactsGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      # Required by Rails::Generators::Migration to produce the migration's
      # timestamp prefix.
      def self.next_migration_number(dirname)
        next_migration_number = current_migration_number(dirname) + 1
        ::ActiveRecord::Migration.next_migration_number(next_migration_number)
      end

      def create_migration_file
        migration_template "add_artifacts_to_nexo_workflow_runs.rb", "db/migrate/add_artifacts_to_nexo_workflow_runs.rb"
      end
    end
  end
end
