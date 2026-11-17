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

    enforce_project_references
    enable_rls
  end

  def down
    remove_project_reference_enforcement
    drop_table :layered_verification_review_approvals
    drop_table :layered_verification_review_packages
  end

  private

  # Package and approval RLS establishes tenant visibility, but the referenced
  # rows must also be constrained to that package's project account. These
  # triggers enforce the invariant for direct SQL writes as well as Rails.
  def enforce_project_references
    safety_assured do
      execute <<~SQL
        CREATE FUNCTION layered_verification_review_packages_validate_agent_run_project()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM agent_runs
            WHERE id = NEW.agent_run_id
              AND project_id = NEW.project_id
          ) THEN
            RAISE EXCEPTION 'agent run must belong to the package project';
          END IF;

          RETURN NEW;
        END;
        $$;
      SQL

      execute <<~SQL
        CREATE TRIGGER layered_verification_review_packages_validate_agent_run_project
        BEFORE INSERT OR UPDATE OF project_id, agent_run_id
        ON layered_verification_review_packages
        FOR EACH ROW
        EXECUTE FUNCTION layered_verification_review_packages_validate_agent_run_project();
      SQL

      execute <<~SQL
        CREATE FUNCTION layered_verification_review_approvals_validate_actor_account()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM layered_verification_review_packages
            INNER JOIN projects ON projects.id = layered_verification_review_packages.project_id
            INNER JOIN users ON users.account_id = projects.account_id
            WHERE layered_verification_review_packages.id = NEW.package_id
              AND users.id = NEW.approved_by_id
          ) THEN
            RAISE EXCEPTION 'approval actor must belong to the package project account';
          END IF;

          RETURN NEW;
        END;
        $$;
      SQL

      execute <<~SQL
        CREATE TRIGGER layered_verification_review_approvals_validate_actor_account
        BEFORE INSERT OR UPDATE OF package_id, approved_by_id
        ON layered_verification_review_approvals
        FOR EACH ROW
        EXECUTE FUNCTION layered_verification_review_approvals_validate_actor_account();
      SQL
    end
  end

  def remove_project_reference_enforcement
    safety_assured do
      execute "DROP TRIGGER IF EXISTS layered_verification_review_approvals_validate_actor_account ON layered_verification_review_approvals"
      execute "DROP TRIGGER IF EXISTS layered_verification_review_packages_validate_agent_run_project ON layered_verification_review_packages"
      execute "DROP FUNCTION IF EXISTS layered_verification_review_approvals_validate_actor_account()"
      execute "DROP FUNCTION IF EXISTS layered_verification_review_packages_validate_agent_run_project()"
    end
  end

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
