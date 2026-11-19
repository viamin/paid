# frozen_string_literal: true

class AddLiveTargetIdentityToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :agent_runs, :closeout_environment, :string,
      comment: "Reviewed live environment class bound to a closeout verification run."
    add_column :agent_runs, :closeout_target_revision, :string,
      comment: "Confirmed environment signal revision bound to a live-target verification run."
    add_reference :agent_runs, :closeout_measurement_attempt,
      index: { algorithm: :concurrently },
      comment: "Trusted measurement attempt attached to a live-target closeout verification run."
    add_index :agent_runs,
      [ :project_id, :issue_id, :closeout_criterion_key, :closeout_recipe_version,
        :closeout_environment, :closeout_target_revision ],
      unique: true,
      where: "goal = 'closeout_verification' AND closeout_target_revision IS NOT NULL",
      name: "index_agent_runs_live_closeout_verification_identity",
      algorithm: :concurrently
  end
end
