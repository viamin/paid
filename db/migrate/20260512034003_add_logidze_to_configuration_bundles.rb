# frozen_string_literal: true

class AddLogidzeToConfigurationBundles < ActiveRecord::Migration[8.1]
  def change
    add_column :configuration_bundles, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_configuration_bundles, on: :configuration_bundles
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_configuration_bundles" on "configuration_bundles";
        SQL
      end
    end
  end
end
