# frozen_string_literal: true

class CreateCodeScanningRemediationAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :code_scanning_remediation_attempts, comment: "Durable scanner-verification evidence for merged code-scanning remediation PRs." do |t|
      t.references :issue, null: false, foreign_key: true, comment: "Synthetic code-scanning issue for the finding."
      t.references :agent_run, foreign_key: true, comment: "Run that produced the remediation PR."
      t.integer :pull_request_number, null: false
      t.string :merge_commit_sha, null: false, comment: "Merge commit that scanner evidence must contain."
      t.datetime :merged_at, null: false
      t.string :status, null: false, default: "awaiting_verification", comment: "awaiting_verification, verified_fixed, verification_failed, or verification_blocked."
      t.string :tool_name
      t.string :category
      t.string :verification_analysis_id
      t.string :verification_commit_sha
      t.string :verification_ref
      t.datetime :verified_at
      t.text :blocked_reason
      t.jsonb :evidence, null: false, default: {}, comment: "Alert, PR, and analysis evidence retained for operator review."
      t.timestamps
    end

    add_index :code_scanning_remediation_attempts, [ :issue_id, :pull_request_number ], unique: true, name: "idx_code_scanning_remediation_attempts_unique_pr"
    add_index :code_scanning_remediation_attempts, [ :issue_id, :status ]
  end
end
