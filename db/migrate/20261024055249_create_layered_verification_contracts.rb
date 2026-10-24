# frozen_string_literal: true

# @spec LAYERED-VERIFY-004 @spec LAYERED-VERIFY-006
# @spec LAYERED-VERIFY-007 @spec LAYERED-VERIFY-008
class CreateLayeredVerificationContracts < ActiveRecord::Migration[8.1]
  def up
    create_table :layered_verification_obligations do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :framework, null: false
      t.string :external_identity, null: false
      t.string :external_revision
      t.text :scope_description, null: false
      t.string :approval_state, null: false, default: "unresolved"
      t.string :approved_revision_reference
      t.references :superseded_by, foreign_key: { to_table: :layered_verification_obligations, on_delete: :nullify }
      t.references :change_intent, foreign_key: true
      t.datetime :synced_at
      t.timestamps
    end

    add_index :layered_verification_obligations,
      [ :project_id, :framework, :external_identity ],
      unique: true,
      name: "index_layered_verification_obligations_identity"

    create_table :layered_verification_correspondence_claims do |t|
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.string :claim_type, null: false
      t.text :source_reference, null: false
      t.text :target_reference, null: false
      t.text :abstraction_boundaries, null: false
      t.text :assumptions, null: false
      t.timestamps
    end

    create_table :layered_verification_check_results do |t|
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :cascade }
      t.references :agent_run, foreign_key: true
      t.string :producer, null: false
      t.string :execution_state, null: false
      t.string :obligation_coverage, null: false
      t.jsonb :input_revision, null: false, default: {}
      t.string :evidence_ref
      t.jsonb :evidence_summary, null: false, default: {}
      t.jsonb :agent_reported, null: false, default: {}
      t.jsonb :recorder_verified, null: false, default: {}
      t.jsonb :cost, null: false, default: {}
      t.text :limitations, null: false
      t.timestamps
    end

    enable_rls
  end

  def down
    drop_table :layered_verification_check_results
    drop_table :layered_verification_correspondence_claims
    drop_table :layered_verification_obligations
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to this block. Tenancy is
  # keyed through the project (directly for obligations, or through the
  # owning obligation for claims and check results).
  def enable_rls
    safety_assured do
      %i[
        layered_verification_obligations
        layered_verification_correspondence_claims
        layered_verification_check_results
      ].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      end

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_obligations
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_obligations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_obligations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_correspondence_claims
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM layered_verification_obligations o
              INNER JOIN projects ON projects.id = o.project_id
              WHERE o.id = layered_verification_correspondence_claims.obligation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM layered_verification_obligations o
              INNER JOIN projects ON projects.id = o.project_id
              WHERE o.id = layered_verification_correspondence_claims.obligation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_check_results
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM layered_verification_obligations o
              INNER JOIN projects ON projects.id = o.project_id
              WHERE o.id = layered_verification_check_results.obligation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM layered_verification_obligations o
              INNER JOIN projects ON projects.id = o.project_id
              WHERE o.id = layered_verification_check_results.obligation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
