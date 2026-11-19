# frozen_string_literal: true

# @spec STAGED-CLOSEOUT-ADOPTION-015
class AddCloseoutVerificationGenerationToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :agent_runs, :closeout_verification_generation, :integer, default: 0, null: false,
      comment: "Zero-based reviewed retry generation; terminal verification runs are never restarted."
    add_index :agent_runs,
      %i[project_id issue_id source_pull_request_number base_commit_sha closeout_mapping_id closeout_verification_generation],
      unique: true, where: "goal = 'closeout_verification'",
      name: "index_agent_runs_closeout_verification_attempt_identity", algorithm: :concurrently
    add_index :agent_runs,
      %i[project_id issue_id closeout_criterion_key closeout_recipe_version closeout_environment closeout_target_revision closeout_verification_generation],
      unique: true, where: "goal = 'closeout_verification' AND closeout_target_revision IS NOT NULL",
      name: "index_agent_runs_live_closeout_verification_attempt_identity", algorithm: :concurrently
    remove_index :agent_runs, name: "index_agent_runs_closeout_verification_identity", algorithm: :concurrently
    remove_index :agent_runs, name: "index_agent_runs_live_closeout_verification_identity", algorithm: :concurrently
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retry history must be preserved; old uniqueness cannot represent multiple generations."
  end
end
