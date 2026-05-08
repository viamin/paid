# frozen_string_literal: true

class AddLogidzeToTenantSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_settings, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_tenant_settings, on: :tenant_settings
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_tenant_settings" on "tenant_settings";
        SQL
      end
    end
  end
end
