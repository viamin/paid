# frozen_string_literal: true

# Adds the run-scoped TDD phase and test-review-reset tracking used by the
# RDR-056 write guards. tdd_phase is nil for runs that are not governed by a
# TDD phase (the default for every existing/new run, preserving current
# behavior); it is set to test_writing/test_fixing/refactor for runs created
# under a project's strict/non-strict TDD mode. tdd_returned_to_test_review
# tracks whether a test_fixing run has legitimately reset the PR back to test
# review (removed paid-tests-approved, added paid-tests-ready-for-review)
# before it may touch test files.
class AddTddPhaseToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:agent_runs, :tdd_phase)
      add_column :agent_runs, :tdd_phase, :string,
        comment: "RDR-056 TDD phase governing this run's write guard: test_writing | test_fixing | refactor | null (not TDD-governed)"
    end

    return if column_exists?(:agent_runs, :tdd_returned_to_test_review)

    add_column :agent_runs, :tdd_returned_to_test_review, :boolean,
      default: false, null: false,
      comment: "RDR-056: true once this test_fixing run has reset the PR to test review, permitting it to alter tests"
  end

  def down
    remove_column :agent_runs, :tdd_returned_to_test_review if column_exists?(:agent_runs, :tdd_returned_to_test_review)
    remove_column :agent_runs, :tdd_phase if column_exists?(:agent_runs, :tdd_phase)
  end
end
