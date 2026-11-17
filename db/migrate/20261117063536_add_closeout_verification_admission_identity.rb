# frozen_string_literal: true

class AddCloseoutVerificationAdmissionIdentity < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :issues, :merged_commit_sha, :string, limit: 40,
      comment: "Authoritatively observed source PR merge revision for closeout verification admission."
    add_column :agent_runs, :closeout_mapping_id, :bigint,
      comment: "Reviewed staged-closeout mapping revision admitted for this synthetic verification run."
    add_column :agent_runs, :closeout_criterion_key, :string,
      comment: "Reviewed criterion bound to this synthetic closeout verification run."
    add_column :agent_runs, :closeout_recipe_version, :string,
      comment: "Reviewed recipe version bound to this synthetic closeout verification run."
    add_column :agent_runs, :closeout_recipe_digest, :string,
      comment: "Reviewed recipe digest bound to this synthetic closeout verification run."

    add_index :agent_runs,
      [ :project_id, :issue_id, :source_pull_request_number, :base_commit_sha, :closeout_mapping_id ],
      unique: true,
      where: "goal = 'closeout_verification'",
      name: "index_agent_runs_closeout_verification_identity",
      algorithm: :concurrently
  end
end
