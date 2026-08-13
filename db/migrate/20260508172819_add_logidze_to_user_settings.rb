# frozen_string_literal: true

class AddLogidzeToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_user_settings, on: :user_settings
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_user_settings" on "user_settings";
        SQL
      end
    end
  end
end
