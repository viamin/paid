class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  def up
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :agent_run, foreign_key: true
      t.string :obligation_external_identity, null: false
      t.string :correspondence_claim_type, null: false, default: "none"
      t.string :cause_signature, null: false
      t.string :state, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: []
      t.text :observed_behavior, null: false
      t.text :check_limitations, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :consequences, null: false, default: []
      t.jsonb :owner_actions, null: false, default: []
      t.jsonb :links, null: false, default: {}
      t.datetime :deferred_at
      t.text :deferral_reason
      t.timestamps
    end
    add_index :layered_verification_findings,
      [ :project_id, :obligation_external_identity, :correspondence_claim_type, :cause_signature ],
      unique: true, where: "state != 'resolved'", name: "index_layered_verification_open_finding_identity"
    enable_rls
  end

  def down
    drop_table :layered_verification_findings
  end

  private

  def enable_rls
    safety_assured do
      execute "ALTER TABLE layered_verification_findings ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_findings FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_findings AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (SELECT 1 FROM projects WHERE projects.id = layered_verification_findings.project_id AND projects.account_id = paid_current_account_id()))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (SELECT 1 FROM projects WHERE projects.id = layered_verification_findings.project_id AND projects.account_id = paid_current_account_id()))
      SQL
    end
  end
end
