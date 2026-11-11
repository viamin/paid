# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-004
class CreateTrustedProviderIdentities < ActiveRecord::Migration[8.1]
  def up
    create_table :trusted_provider_identities,
      comment: "Account trusted-team/user defaults with project-level additions/overrides, an additional admission path for non-GitHub providers." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, foreign_key: true, comment: "Null means an account-wide default; present overrides/adds for that project."
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :provider, null: false
      t.string :identity_type, null: false, comment: "team or user."
      t.string :external_id, null: false
      t.string :external_name
      t.timestamps
    end

    add_index :trusted_provider_identities, %i[account_id project_id provider identity_type external_id],
      unique: true, name: "index_trusted_identities_on_scope"
    add_index :trusted_provider_identities, %i[account_id provider identity_type external_id],
      unique: true, where: "project_id IS NULL", name: "index_trusted_identities_on_account_default"

    safety_assured do
      execute <<~SQL
        ALTER TABLE trusted_provider_identities ENABLE ROW LEVEL SECURITY;
        ALTER TABLE trusted_provider_identities FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON trusted_provider_identities
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON trusted_provider_identities"
      execute "ALTER TABLE trusted_provider_identities NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE trusted_provider_identities DISABLE ROW LEVEL SECURITY"
    end

    drop_table :trusted_provider_identities
  end
end
