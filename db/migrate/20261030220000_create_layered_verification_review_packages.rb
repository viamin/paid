# frozen_string_literal: true

# @spec LAYERED-VERIFY-023
class CreateLayeredVerificationReviewPackages < ActiveRecord::Migration[8.1]
  def up
    create_table :layered_verification_review_packages do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.integer :revision, null: false
      t.string :package_digest, null: false
      t.jsonb :bound_inputs, null: false, default: {}
      t.jsonb :approvals, null: false, default: []
      t.jsonb :inbox_decisions, null: false, default: []
      t.timestamps
    end

    add_index :layered_verification_review_packages, [ :project_id, :package_digest ], unique: true,
      name: "index_layered_verification_review_packages_digest"
    add_index :layered_verification_review_packages, [ :agent_run_id, :revision ], unique: true,
      name: "index_layered_verification_review_packages_revision"

    enable_rls
  end

  def down
    drop_table :layered_verification_review_packages
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent helper,
  # so the SQL stays minimal and isolated to this block. Tenancy is keyed
  # through the project, mirroring the other layered-verification tables.
  def enable_rls
    safety_assured do
      execute "ALTER TABLE layered_verification_review_packages ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_review_packages FORCE ROW LEVEL SECURITY"

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_review_packages
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_review_packages.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_review_packages.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
