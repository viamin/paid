# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-004
class CreateProviderIdentityMappings < ActiveRecord::Migration[8.1]
  def up
    create_table :provider_identity_mappings,
      comment: "Explicit Paid-to-provider (Linear, GitHub) identity mapping used for trust admission and comment authorship." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :provider, null: false
      t.string :external_id, null: false
      t.string :external_name
      t.timestamps
    end

    add_index :provider_identity_mappings, %i[account_id user_id provider], unique: true,
      name: "index_provider_identity_mappings_on_user_and_provider"
    add_index :provider_identity_mappings, %i[account_id provider external_id], unique: true,
      name: "index_provider_identity_mappings_on_provider_identity"

    safety_assured do
      execute <<~SQL
        ALTER TABLE provider_identity_mappings ENABLE ROW LEVEL SECURITY;
        ALTER TABLE provider_identity_mappings FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON provider_identity_mappings
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON provider_identity_mappings"
      execute "ALTER TABLE provider_identity_mappings NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE provider_identity_mappings DISABLE ROW LEVEL SECURITY"
    end

    drop_table :provider_identity_mappings
  end
end
