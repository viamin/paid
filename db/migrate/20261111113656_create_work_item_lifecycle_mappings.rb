# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-006
class CreateWorkItemLifecycleMappings < ActiveRecord::Migration[8.1]
  def up
    create_table :work_item_lifecycle_mappings,
      comment: "Bidirectional provider-native/Paid lifecycle state mapping, with account defaults and project overrides." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, foreign_key: true, comment: "Null means an account-wide default; present overrides for that project."
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :provider, null: false
      t.string :native_state, null: false
      t.string :paid_state, null: false
      t.timestamps
    end

    add_index :work_item_lifecycle_mappings, %i[account_id project_id provider native_state],
      unique: true, name: "index_lifecycle_mappings_on_native_state"
    add_index :work_item_lifecycle_mappings, %i[account_id provider native_state],
      unique: true, where: "project_id IS NULL", name: "index_lifecycle_mappings_on_account_native_state"
    add_index :work_item_lifecycle_mappings, %i[account_id project_id provider paid_state],
      unique: true, name: "index_lifecycle_mappings_on_paid_state"
    add_index :work_item_lifecycle_mappings, %i[account_id provider paid_state],
      unique: true, where: "project_id IS NULL", name: "index_lifecycle_mappings_on_account_paid_state"

    safety_assured do
      execute <<~SQL
        ALTER TABLE work_item_lifecycle_mappings ENABLE ROW LEVEL SECURITY;
        ALTER TABLE work_item_lifecycle_mappings FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON work_item_lifecycle_mappings
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON work_item_lifecycle_mappings"
      execute "ALTER TABLE work_item_lifecycle_mappings NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE work_item_lifecycle_mappings DISABLE ROW LEVEL SECURITY"
    end

    drop_table :work_item_lifecycle_mappings
  end
end
