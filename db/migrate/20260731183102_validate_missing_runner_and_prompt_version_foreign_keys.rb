# frozen_string_literal: true

class ValidateMissingRunnerAndPromptVersionForeignKeys < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :configuration_bundles, :prompt_versions if foreign_key_exists?(:configuration_bundles, :prompt_versions, column: :prompt_version_id)
    validate_foreign_key :agent_runs, :runners if foreign_key_exists?(:agent_runs, :runners, column: :runner_id)
    validate_foreign_key :chat_sessions, :runners if foreign_key_exists?(:chat_sessions, :runners, column: :runner_id)
  end
end
