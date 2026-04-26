class AddWorkerSettingsAndSelfRepoFullNameToTenantSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_settings, :worker_settings, :jsonb, null: false, default: {}
    add_column :tenant_settings, :self_repo_full_name, :string
  end
end
