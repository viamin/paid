# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-004
class CreateWorkItemProjectMappings < ActiveRecord::Migration[8.1]
  def up
    create_table :work_item_project_mappings,
      comment: "Maps one provider-native project (e.g. a Linear project) to one or more repository-backed Paid projects." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :tracker_configuration, foreign_key: true
      t.string :provider, null: false
      t.string :native_project_id, null: false
      t.string :native_project_name
      t.string :assignment_mode, null: false, default: "current_and_future",
        comment: "current_and_future, future_only, or none."
      t.references :default_execution_project, foreign_key: { to_table: :projects }
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :work_item_project_mappings, %i[account_id provider native_project_id], unique: true,
      name: "index_work_item_project_mappings_on_native_identity"

    create_table :work_item_project_mapping_targets,
      comment: "The repository-backed Paid projects a Linear project mapping assigns tickets to." do |t|
      t.references :work_item_project_mapping, null: false, foreign_key: true, index: { name: "index_mapping_targets_on_mapping" }
      t.references :project, null: false, foreign_key: true
      t.timestamps
    end

    add_index :work_item_project_mapping_targets, %i[work_item_project_mapping_id project_id], unique: true,
      name: "index_mapping_targets_on_mapping_and_project"

    safety_assured do
      execute <<~SQL
        ALTER TABLE work_item_project_mappings ENABLE ROW LEVEL SECURITY;
        ALTER TABLE work_item_project_mappings FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON work_item_project_mappings
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON work_item_project_mappings"
      execute "ALTER TABLE work_item_project_mappings NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE work_item_project_mappings DISABLE ROW LEVEL SECURITY"
    end

    drop_table :work_item_project_mapping_targets
    drop_table :work_item_project_mappings
  end
end
