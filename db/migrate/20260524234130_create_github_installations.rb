# frozen_string_literal: true

class CreateGithubInstallations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_installations, comment: "Per-account GitHub App installation records for paid-agents[bot]" do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint :github_installation_id, null: false, comment: "GitHub installation ID from App install event"
      t.string :account_login, comment: "GitHub org or user login that installed the App"
      t.string :target_type, comment: "Organization or User"
      t.string :repository_selection, comment: "all or selected"
      t.jsonb :accessible_repositories, default: [], null: false, comment: "Cached list of accessible repos from install metadata"
      t.datetime :suspended_at, comment: "When the installation was suspended by GitHub"
      t.datetime :revoked_at, comment: "When the installation was uninstalled/deleted"

      t.timestamps
    end
    add_index :github_installations, :github_installation_id
    add_index :github_installations, [ :account_id, :github_installation_id ], unique: true,
                                                                               name: "idx_github_installations_on_account_installation"

    safety_assured do
      execute <<-SQL.squish
        ALTER TABLE github_installations ENABLE ROW LEVEL SECURITY;

        CREATE POLICY github_installations_account_isolation ON github_installations
          USING (account_id = (current_setting('paid.current_account_id', TRUE))::bigint)
          WITH CHECK (account_id = (current_setting('paid.current_account_id', TRUE))::bigint);

        CREATE POLICY github_installations_bypass ON github_installations
          USING (current_setting('paid.bypass_tenant_rls', TRUE) = 'true')
          WITH CHECK (current_setting('paid.bypass_tenant_rls', TRUE) = 'true');
      SQL
    end
  end
end
