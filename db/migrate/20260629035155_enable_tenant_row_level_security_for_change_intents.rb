# frozen_string_literal: true

class EnableTenantRowLevelSecurityForChangeIntents < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        ALTER TABLE change_intents ENABLE ROW LEVEL SECURITY;
        ALTER TABLE change_intents FORCE ROW LEVEL SECURITY;

        CREATE POLICY tenant_isolation ON change_intents
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass()
          OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = change_intents.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass()
          OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = change_intents.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON change_intents"
      execute "ALTER TABLE change_intents NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE change_intents DISABLE ROW LEVEL SECURITY"
    end
  end
end
