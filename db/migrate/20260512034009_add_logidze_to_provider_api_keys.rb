# frozen_string_literal: true

class AddLogidzeToProviderApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :provider_api_keys, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_provider_api_keys, on: :provider_api_keys
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_provider_api_keys" on "provider_api_keys";
        SQL
      end
    end
  end
end
