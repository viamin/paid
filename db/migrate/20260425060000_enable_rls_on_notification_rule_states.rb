# frozen_string_literal: true

class EnableRlsOnNotificationRuleStates < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        ALTER TABLE notification_rule_states ENABLE ROW LEVEL SECURITY;
        ALTER TABLE notification_rule_states FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON notification_rule_states
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (notification_rule_states.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (notification_rule_states.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON notification_rule_states"
      execute "ALTER TABLE notification_rule_states NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE notification_rule_states DISABLE ROW LEVEL SECURITY"
    end
  end
end
