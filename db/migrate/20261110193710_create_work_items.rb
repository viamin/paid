# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-003
class CreateWorkItems < ActiveRecord::Migration[8.1]
  def up
    create_table :work_items, comment: "Account-scoped provider tickets retained for reconciliation and workflow assignment." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :tracker_configuration, foreign_key: true
      t.string :provider, null: false
      t.string :resource_type, null: false, default: "issue"
      t.string :external_id, null: false
      t.string :title, null: false
      t.text :body
      t.string :native_state
      t.integer :priority
      t.string :url
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :provider_created_at
      t.datetime :provider_updated_at
      t.datetime :archived_at
      t.datetime :last_synced_at, null: false
      t.timestamps
    end

    add_index :work_items, %i[account_id provider resource_type external_id], unique: true,
      name: "index_work_items_on_provider_identity"

    add_column :tracker_configurations, :sync_interval_seconds, :integer, null: false, default: 900
    add_column :tracker_configurations, :last_synced_at, :datetime
    add_column :tracker_configurations, :last_sync_error, :string
    add_column :tracker_configurations, :connection_health, :string, null: false, default: "unknown"

    safety_assured do
      execute <<~SQL
        ALTER TABLE work_items ENABLE ROW LEVEL SECURITY;
        ALTER TABLE work_items FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON work_items
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON work_items"
      execute "ALTER TABLE work_items NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE work_items DISABLE ROW LEVEL SECURITY"
    end

    remove_column :tracker_configurations, :connection_health
    remove_column :tracker_configurations, :last_sync_error
    remove_column :tracker_configurations, :last_synced_at
    remove_column :tracker_configurations, :sync_interval_seconds
    drop_table :work_items
  end
end
