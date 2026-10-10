# frozen_string_literal: true

class EnableRlsOnPersonalAccessTokens < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:personal_access_tokens)

    safety_assured do
      execute <<~SQL
        ALTER TABLE personal_access_tokens ENABLE ROW LEVEL SECURITY;
        ALTER TABLE personal_access_tokens FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON personal_access_tokens
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR (
              personal_access_tokens.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              personal_access_tokens.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end

  def down
    return unless table_exists?(:personal_access_tokens)

    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON personal_access_tokens"
      execute "ALTER TABLE personal_access_tokens NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE personal_access_tokens DISABLE ROW LEVEL SECURITY"
    end
  end
end
