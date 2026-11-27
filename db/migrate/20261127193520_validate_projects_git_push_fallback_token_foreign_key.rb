# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-016
class ValidateProjectsGitPushFallbackTokenForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :projects, :github_tokens, column: :git_push_fallback_token_id
  end
end
