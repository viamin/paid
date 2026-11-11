# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-006
class CreateWorkItemLifecycleConflicts < ActiveRecord::Migration[8.1]
  def up
    create_table :work_item_lifecycle_conflicts,
      comment: "Simultaneous conflicting lifecycle changes (native vs. Paid) surfaced for human review." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :work_item, null: false, foreign_key: true
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.string :requested_native_state
      t.string :requested_paid_state
      t.string :observed_native_state
      t.string :observed_paid_state
      t.datetime :detected_at, null: false
      t.datetime :resolved_at
      t.string :resolution
      t.timestamps
    end

    add_index :work_item_lifecycle_conflicts, %i[account_id resolved_at], name: "index_lifecycle_conflicts_on_account_and_resolved"

    safety_assured do
      execute <<~SQL
        ALTER TABLE work_item_lifecycle_conflicts ENABLE ROW LEVEL SECURITY;
        ALTER TABLE work_item_lifecycle_conflicts FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON work_item_lifecycle_conflicts
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON work_item_lifecycle_conflicts"
      execute "ALTER TABLE work_item_lifecycle_conflicts NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE work_item_lifecycle_conflicts DISABLE ROW LEVEL SECURITY"
    end

    drop_table :work_item_lifecycle_conflicts
  end
end
