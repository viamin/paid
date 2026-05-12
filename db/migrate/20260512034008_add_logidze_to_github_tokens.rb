# frozen_string_literal: true

class AddLogidzeToGithubTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :github_tokens, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_github_tokens, on: :github_tokens
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_github_tokens" on "github_tokens";
        SQL
      end
    end
  end
end
