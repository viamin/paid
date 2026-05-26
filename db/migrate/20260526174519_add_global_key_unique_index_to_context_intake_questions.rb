# frozen_string_literal: true

class AddGlobalKeyUniqueIndexToContextIntakeQuestions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :context_intake_questions, :key,
      unique: true,
      where: "project_id IS NULL",
      name: "idx_context_intake_questions_global_key_unique",
      if_not_exists: true,
      algorithm: :concurrently
  end
end
