# frozen_string_literal: true

# @spec LAYERED-VERIFY-023
class CreateLayeredVerificationReviewPackages < ActiveRecord::Migration[8.1]
  def up
    create_table :layered_verification_review_packages do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.string :package_digest, null: false
      t.integer :revision_number, null: false, default: 1
      t.jsonb :bound_inputs, null: false, default: {}
      t.timestamps
    end

    # One reproducible identity per (project, digest): replayed captures of the
    # same bound inputs reuse the existing immutable row.
    add_index :layered_verification_review_packages,
      [ :project_id, :package_digest ],
      unique: true,
      name: "index_layered_verification_review_packages_identity"
    add_index :layered_verification_review_packages,
      [ :agent_run_id, :revision_number ],
      unique: true,
      name: "index_layered_verification_review_packages_revision"

    create_table :layered_verification_review_approvals do |t|
      t.references :package, null: false, foreign_key: { to_table: :layered_verification_review_packages, on_delete: :cascade }
      # Recorded actors are database-bound: an approval keeps a real user row,
      # and deleting a user who recorded one is rejected rather than nullified.
      t.references :approved_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :approved_at, null: false
      t.jsonb :provenance, null: false, default: {}
      t.timestamps
    end

    enable_rls
  end

  def down
    drop_table :layered_verification_review_approvals
    drop_table :layered_verification_review_packages
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # row-level security has no migration helper. Tenancy is keyed through the
  # project (directly for packages, or through the owning package for
  # approvals), matching the layered-verification sibling tables.
  def enable_rls
    safety_assured do
      %i[
        layered_verification_review_packages
        layered_verification_review_approvals
      ].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      end

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

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_review_approvals
          AS PERMISSIVE
          FOR ALL
          USING (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM layered_verification_review_packages p
                INNER JOIN projects ON projects.id = p.project_id
                WHERE p.id = layered_verification_review_approvals.package_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM layered_verification_review_packages p
                INNER JOIN projects ON projects.id = p.project_id
                WHERE p.id = layered_verification_review_approvals.package_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          )
      SQL
    end
  end
end
