# frozen_string_literal: true

class AddLogidzeToProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :providers, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_providers, on: :providers
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_providers" on "providers";
        SQL
      end
    end
  end
end
