# frozen_string_literal: true

# @spec AUTO-MERGE-004
class CreateAutoMergeAttempts < ActiveRecord::Migration[8.1]
  def up
    create_table :auto_merge_attempts,
      comment: "Sanitized history of auto-merge decisions and blockers for pull requests." do |t|
      t.references :project, null: false, foreign_key: true,
        comment: "Project that owned the auto-merge evaluation."
      t.references :issue, null: false, foreign_key: true,
        comment: "Local pull-request issue row the auto-merge evaluation targeted."
      t.datetime :attempted_at, null: false,
        comment: "When the merge, skip, or blocker decision was recorded."
      t.string :actor_path, null: false,
        comment: "Automation path that evaluated the PR, such as review_auto_merge or dependabot_auto_merge."
      t.string :status, null: false,
        comment: "Outcome category for the attempt, such as merged, skipped, blocked, or failed."
      t.string :reason_code,
        comment: "Sanitized machine-readable explanation for the outcome."
      t.text :sanitized_message
      t.string :credential_mode,
        comment: "Credential path used for the decisive attempt, such as github_app, pat, or pat_fallback."

      t.timestamps
    end

    add_index :auto_merge_attempts, [ :issue_id, :attempted_at ],
      name: "index_auto_merge_attempts_on_issue_id_and_attempted_at"
    add_index :auto_merge_attempts, [ :project_id, :attempted_at ],
      name: "index_auto_merge_attempts_on_project_id_and_attempted_at"

    safety_assured do
      execute <<~SQL
        ALTER TABLE auto_merge_attempts ENABLE ROW LEVEL SECURITY;
        ALTER TABLE auto_merge_attempts FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON auto_merge_attempts
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = auto_merge_attempts.project_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = auto_merge_attempts.project_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          );
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON auto_merge_attempts" }
    safety_assured { execute "ALTER TABLE auto_merge_attempts NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE auto_merge_attempts DISABLE ROW LEVEL SECURITY" }

    drop_table :auto_merge_attempts
  end
end
