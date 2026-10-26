# frozen_string_literal: true

# @spec PARTIAL-CLOSEOUT-030
class CreatePartialCloseoutEvidenceSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :partial_closeout_evidence_submissions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :criterion, null: false
      t.string :evidence_type, null: false
      t.string :evidence_reference, null: false
      t.string :source_revision, null: false
      t.text :explanation, null: false
      t.string :status, null: false, default: "submitted"
      t.text :reasoning, null: false, default: ""
      t.jsonb :provenance, null: false, default: {}
      t.datetime :assessed_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :partial_closeout_evidence_submissions,
      %i[issue_id criterion evidence_type evidence_reference source_revision],
      unique: true, name: "idx_closeout_evidence_submissions_idempotency"

    enable_rls
  end

  private

  def enable_rls
    safety_assured do
      execute "ALTER TABLE partial_closeout_evidence_submissions ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE partial_closeout_evidence_submissions FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON partial_closeout_evidence_submissions
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
        WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
      SQL
    end
  end
end
