# frozen_string_literal: true

class AddLogidzeToIntegrationCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :integration_credentials, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_integration_credentials, on: :integration_credentials
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_integration_credentials" on "integration_credentials";
        SQL
      end
    end
  end
end
