# frozen_string_literal: true

require "test_helper"

# The artifacts generator needs Rails::Generators. The core suite runs with no
# Rails present, so the whole file is guarded: when Rails generators can't be
# loaded, we register a single skipped test rather than failing the suite.
rails_generators_available =
  begin
    require "rails/generators"
    require "rails/generators/test_case"
    # The migration generator computes its timestamp via
    # ActiveRecord::Migration.next_migration_number, so AR must be loadable.
    # Loading it here does NOT flip RunStore.default: that also requires
    # Nexo::WorkflowRun, which stays Zeitwerk-ignored and undefined offline.
    require "active_record"
    require "generators/nexo/artifacts/artifacts_generator"
    true
  rescue LoadError
    false
  end

if rails_generators_available
  class ArtifactsGeneratorTest < Rails::Generators::TestCase
    tests Nexo::Generators::ArtifactsGenerator
    destination File.expand_path("../tmp/artifacts_generator", __dir__)
    setup :prepare_destination

    def test_creates_the_additive_artifacts_migration
      run_generator

      assert_migration "db/migrate/add_artifacts_to_nexo_workflow_runs.rb" do |content|
        assert_match(/class AddArtifactsToNexoWorkflowRuns < ActiveRecord::Migration/, content)
        assert_match(/add_column :nexo_workflow_runs, :artifacts, :json, null: false, default: \[\]/, content)
      end
    end
  end
else
  class ArtifactsGeneratorSkippedTest < Minitest::Test
    def test_skipped_without_rails_generators
      skip "Rails generators are not loadable; artifacts generator test skipped"
    end
  end
end
