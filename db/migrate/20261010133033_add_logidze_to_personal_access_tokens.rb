# frozen_string_literal: true

class AddLogidzeToPersonalAccessTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :personal_access_tokens, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_personal_access_tokens, on: :personal_access_tokens
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_personal_access_tokens" on "personal_access_tokens";
        SQL
      end
    end
  end
end
