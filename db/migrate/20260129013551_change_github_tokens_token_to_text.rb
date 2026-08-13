# frozen_string_literal: true

class ChangeGithubTokensTokenToText < ActiveRecord::Migration[8.1]
  def up
    change_column :github_tokens, :token, :text, null: false
  end

  def down
    change_column :github_tokens, :token, :string, null: false
  end
end
