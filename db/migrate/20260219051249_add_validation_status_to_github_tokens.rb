# frozen_string_literal: true

class AddValidationStatusToGithubTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :github_tokens, :validation_status, :string, limit: 50, default: "pending", null: false
    add_column :github_tokens, :validation_error, :text
    add_index :github_tokens, :validation_status

    reversible do |dir|
      dir.up do
        # Backfill existing tokens as already validated since they were validated synchronously
        execute <<~SQL
          UPDATE github_tokens SET validation_status = 'validated'
        SQL
      end
    end
  end
end
