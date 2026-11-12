# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-004
class CreateWorkItemAssignments < ActiveRecord::Migration[8.1]
  def up
    create_table :work_item_assignments,
      comment: "Join between a work item and the repository-backed Paid project(s) it is assigned to." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :work_item, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :work_item_project_mapping, foreign_key: true
      t.references :assigned_by, foreign_key: { to_table: :users }
      t.string :provenance, null: false, default: "manual", comment: "mapping or manual."
      t.boolean :locked, null: false, default: false,
        comment: "Set once a human customizes or replaces this item's assignment; future mapping changes must not silently alter it."
      t.boolean :default_execution, null: false, default: false,
        comment: "Issue-level default execution project among this item's assigned projects."
      t.timestamps
    end

    add_index :work_item_assignments, %i[work_item_id project_id], unique: true,
      name: "index_work_item_assignments_on_work_item_and_project"
    add_index :work_item_assignments, %i[project_id work_item_id],
      name: "index_work_item_assignments_on_project_and_work_item"

    create_table :work_item_assignment_overrides,
      comment: "Append-only audit trail of explicit human customize/replace decisions on a work item's assignment." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :work_item, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :mode, null: false, comment: "customized or replaced."
      t.text :note
      t.timestamps
    end

    [ :work_item_assignments, :work_item_assignment_overrides ].each do |table|
      safety_assured do
        execute <<~SQL
          ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
          ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
          CREATE POLICY tenant_isolation ON #{table}
            AS PERMISSIVE FOR ALL
            USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
            WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
        SQL
      end
    end
  end

  def down
    [ :work_item_assignments, :work_item_assignment_overrides ].each do |table|
      safety_assured do
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      end
    end

    drop_table :work_item_assignment_overrides
    drop_table :work_item_assignments
  end
end
