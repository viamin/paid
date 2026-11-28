# frozen_string_literal: true

class RemoveRedundantPromptVersionsPromptIdIndex < ActiveRecord::Migration[8.1]
  # @spec POSTGRESQL-PERSISTENCE-014
  disable_ddl_transaction!

  INDEX_NAME = "index_prompt_versions_on_prompt_id"

  def up
    return unless index_exists?(:prompt_versions, name: INDEX_NAME)

    remove_index :prompt_versions, name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    return if index_exists?(:prompt_versions, name: INDEX_NAME)

    add_index :prompt_versions, :prompt_id, name: INDEX_NAME, algorithm: :concurrently
  end
end
