# frozen_string_literal: true

# @spec INTENT-AMENDMENT-003 @spec INTENT-AMENDMENT-004 @spec INTENT-AMENDMENT-006
# @spec INTENT-AMENDMENT-007 @spec INTENT-AMENDMENT-008
class CreateDesignAmendmentsAndImpactRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :design_amendments, comment: "RDR-067 design amendment: product-level drift routed through amended RDR/LID PRs, human approval, and merge." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :feature_intent, null: false, foreign_key: true
      t.string :status, null: false, default: "open", comment: "Amendment status: open, approved, merged, abandoned."
      t.text :reason, null: false, comment: "Why the approved design is being amended."
      t.jsonb :drift_evidence, null: false, default: {}, comment: "Cited design claims, diff references, and reviewer evidence motivating the amendment."
      t.string :design_pr_url, comment: "Amended RDR/LID pull request under review."
      t.string :superseded_revision, null: false, comment: "Approved design revision this amendment supersedes."
      t.string :approved_pr_head_sha, comment: "Amended design PR head the human approved."
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at
      t.string :amended_revision, comment: "Merged repository revision that becomes the new approved baseline."
      t.datetime :merged_at
      t.jsonb :impact, null: false, default: {}, comment: "Recorded revision-impact mapping per branch with actions taken."
      t.datetime :evaluated_at, comment: "When revision impact was last evaluated."
      t.timestamps
    end

    add_index :design_amendments, :status
    add_index :design_amendments, %i[project_id status]
    add_index :design_amendments, %i[feature_intent_id status]

    create_table :design_amendment_pauses, comment: "Per-branch holds applied while a design amendment's impact is resolved." do |t|
      t.references :design_amendment, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.string :reason_code, null: false, comment: "Why the branch is held: affected, dependent, or uncertain."
      t.string :status, null: false, default: "held", comment: "Hold status: held or released."
      t.jsonb :evidence, null: false, default: {}, comment: "Cited design claims and reviewer explanation for the hold."
      t.datetime :released_at
      t.references :released_by, foreign_key: { to_table: :users }
      t.text :release_reason
      t.timestamps
    end

    add_index :design_amendment_pauses, :status
    add_index :design_amendment_pauses, %i[design_amendment_id issue_id], unique: true, name: "index_design_amendment_pauses_unique_branch"

    create_table :design_amendment_follow_ups, comment: "Follow-up human decisions for already-merged work affected by a design revision; never auto-rolled back." do |t|
      t.references :design_amendment, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.string :status, null: false, default: "open", comment: "Follow-up status: open or resolved."
      t.jsonb :evidence, null: false, default: {}, comment: "Cited design claims and reviewer explanation for the follow-up."
      t.text :decision, comment: "Human's follow-up decision."
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.timestamps
    end

    add_index :design_amendment_follow_ups, :status
    add_index :design_amendment_follow_ups, %i[design_amendment_id issue_id], unique: true, name: "index_design_amendment_follow_ups_unique_branch"

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block.
    safety_assured do
      execute <<~SQL
        ALTER TABLE design_amendments ENABLE ROW LEVEL SECURITY;
        ALTER TABLE design_amendments FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON design_amendments
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = design_amendments.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = design_amendments.project_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL

      execute <<~SQL
        ALTER TABLE design_amendment_pauses ENABLE ROW LEVEL SECURITY;
        ALTER TABLE design_amendment_pauses FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON design_amendment_pauses
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM design_amendments
              INNER JOIN projects ON projects.id = design_amendments.project_id
              WHERE design_amendments.id = design_amendment_pauses.design_amendment_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM design_amendments
              INNER JOIN projects ON projects.id = design_amendments.project_id
              WHERE design_amendments.id = design_amendment_pauses.design_amendment_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL

      execute <<~SQL
        ALTER TABLE design_amendment_follow_ups ENABLE ROW LEVEL SECURITY;
        ALTER TABLE design_amendment_follow_ups FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON design_amendment_follow_ups
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM design_amendments
              INNER JOIN projects ON projects.id = design_amendments.project_id
              WHERE design_amendments.id = design_amendment_follow_ups.design_amendment_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM design_amendments
              INNER JOIN projects ON projects.id = design_amendments.project_id
              WHERE design_amendments.id = design_amendment_follow_ups.design_amendment_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON design_amendment_follow_ups"
      execute "ALTER TABLE design_amendment_follow_ups NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE design_amendment_follow_ups DISABLE ROW LEVEL SECURITY"

      execute "DROP POLICY IF EXISTS tenant_isolation ON design_amendment_pauses"
      execute "ALTER TABLE design_amendment_pauses NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE design_amendment_pauses DISABLE ROW LEVEL SECURITY"

      execute "DROP POLICY IF EXISTS tenant_isolation ON design_amendments"
      execute "ALTER TABLE design_amendments NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE design_amendments DISABLE ROW LEVEL SECURITY"
    end

    drop_table :design_amendment_follow_ups
    drop_table :design_amendment_pauses
    drop_table :design_amendments
  end
end
