# frozen_string_literal: true

class AddMissingRunnerAndPromptVersionForeignKeys < ActiveRecord::Migration[8.1]
  def up
    add_foreign_key :configuration_bundles, :prompt_versions,
      column: :prompt_version_id,
      on_delete: :nullify,
      validate: false unless foreign_key_exists?(:configuration_bundles, :prompt_versions)

    add_foreign_key :agent_runs, :runners,
      column: :runner_id,
      on_delete: :nullify,
      validate: false unless foreign_key_exists?(:agent_runs, :runners, column: :runner_id)

    add_foreign_key :chat_sessions, :runners,
      column: :runner_id,
      validate: false unless foreign_key_exists?(:chat_sessions, :runners, column: :runner_id)
  end

  def down
    remove_foreign_key :chat_sessions, column: :runner_id if foreign_key_exists?(:chat_sessions, :runners, column: :runner_id)
    remove_foreign_key :agent_runs, column: :runner_id if foreign_key_exists?(:agent_runs, :runners, column: :runner_id)
    remove_foreign_key :configuration_bundles, column: :prompt_version_id if foreign_key_exists?(:configuration_bundles, :prompt_versions, column: :prompt_version_id)
  end
end
